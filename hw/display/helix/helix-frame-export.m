/*
 * Helix Frame Export for QEMU/UTM
 *
 * Zero-copy video encoding: virtio-gpu resource -> Metal texture ->
 * IOSurface -> VideoToolbox H.264 -> vsock back to guest
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "helix-frame-export.h"

/* Helix scanout helpers - implemented in virtio-gpu-base.c
 * because we can't include hw/virtio/virtio-gpu.h in Objective-C */
int helix_enable_scanout(void *virtio_gpu, uint32_t scanout_id,
                         uint32_t width, uint32_t height);
int helix_disable_scanout(void *virtio_gpu, uint32_t scanout_id);
void helix_gl_block(void *virtio_gpu, bool block);
void *helix_create_gl_unblock_bh(void *virtio_gpu);
void helix_schedule_gl_unblock(void *bh);

/* BQL (Big QEMU Lock) — must be held when calling QEMU device model
 * functions from non-main threads. Can't include qemu/main-loop.h
 * from Objective-C due to header conflicts, so declare directly. */
void bql_lock_impl(const char *file, int line);
void bql_unlock(void);

#ifdef __APPLE__

#include <dispatch/dispatch.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <Metal/Metal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <poll.h>

/* virglrenderer includes */
#include "virglrenderer.h"

/* OpenGL/EGL includes via epoxy (for GPU blit path) */
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <OpenGL/OpenGL.h>  /* CGLContextObj for CGL detection */

/* ANGLE IOSurface extension constants not in epoxy's generated headers */
#ifndef EGL_IOSURFACE_READ_HINT_ANGLE
#define EGL_IOSURFACE_READ_HINT_ANGLE 0x0001
#endif
#ifndef EGL_IOSURFACE_WRITE_HINT_ANGLE
#define EGL_IOSURFACE_WRITE_HINT_ANGLE 0x0002
#endif

/* QEMU EGL globals (defined in ui/egl-helpers.c) */
extern EGLDisplay *qemu_egl_display;
extern EGLConfig qemu_egl_config;
extern EGLContext qemu_egl_rn_ctx;
extern void *qemu_egl_angle_native_device;

/* QEMU EGL helper functions (defined in ui/egl-helpers.c) */
extern EGLSurface qemu_egl_init_buffer_surface(EGLContext ectx, EGLenum buftype,
                                                EGLClientBuffer buffer,
                                                const EGLint *attrib_list);
extern bool qemu_egl_destroy_surface(EGLSurface surface);

/* Forward declarations for QEMU types */
#include <pixman.h>

typedef struct DisplaySurface {
    pixman_image_t *image;
    uint8_t flags;
    void *share_handle;
    uint32_t share_handle_offset;
} DisplaySurface;

typedef struct VirtIOGPU VirtIOGPU;
typedef struct virtio_gpu_scanout virtio_gpu_scanout;

/* DisplaySurface helpers (from ui/surface.h) */
static inline uint32_t surface_width(DisplaySurface *s) {
    return pixman_image_get_width(s->image);
}

static inline uint32_t surface_height(DisplaySurface *s) {
    return pixman_image_get_height(s->image);
}

static inline uint32_t surface_stride(DisplaySurface *s) {
    return pixman_image_get_stride(s->image);
}

static inline void *surface_data(DisplaySurface *s) {
    return pixman_image_get_data(s->image);
}

/* virtio-gpu scanout structure (minimal definition) */
struct virtio_gpu_scanout {
    void *con;              /* QemuConsole */
    DisplaySurface *ds;
    uint32_t width, height;
    /* ... other fields not needed here ... */
};

/* virtio-gpu base structure (minimal definition) */
#define VIRTIO_GPU_MAX_SCANOUTS 16
typedef struct VirtIOGPUBase {
    void *parent;
    struct virtio_gpu_scanout scanout[VIRTIO_GPU_MAX_SCANOUTS];
    /* ... other fields not needed here ... */
} VirtIOGPUBase;

/* virtio-gpu structure (minimal definition) */
struct VirtIOGPU {
    VirtIOGPUBase parent_obj;
    /* ... other fields not needed here ... */
};

/* Forward declarations */
extern uint32_t virtio_gpu_get_scanout_resource_id(void *virtio_gpu, uint32_t scanout_idx);

/* virglrenderer functions that may not be in header (unstable API) */
extern enum virgl_renderer_native_handle_type
virgl_renderer_create_handle_for_scanout(uint32_t res_id,
                                         uint32_t width,
                                         uint32_t height,
                                         uint32_t virgl_format,
                                         uint32_t padding,
                                         uint32_t stride,
                                         uint32_t offset,
                                         virgl_renderer_native_handle *handle);

extern void virgl_renderer_force_ctx_0(void);

/* virgl_renderer_resource_map/unmap are in virglrenderer.h */

/* Placeholder for QEMU error reporting - also log to file */
static void helix_log(const char *fmt, ...) {
    FILE *f = fopen("/Users/luke/Library/Group Containers/WDNLXAD4W8.com.utmapp.UTM/helix-debug.log", "a");
    if (f) {
        va_list args;
        va_start(args, fmt);
        vfprintf(f, fmt, args);
        fprintf(f, "\n");
        va_end(args);
        fclose(f);
    }
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "helix: ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}
#define error_report(...) helix_log(__VA_ARGS__)

/* MSG_NOSIGNAL doesn't exist on macOS — use SO_NOSIGPIPE on socket instead */
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

/* Portable atomic helpers — can't use <stdatomic.h> because it conflicts
 * with QEMU's own atomic primitives. __atomic builtins work on all
 * compilers we target (clang/gcc on aarch64). */
#define helix_atomic_load(ptr)        __atomic_load_n(ptr, __ATOMIC_ACQUIRE)
#define helix_atomic_store(ptr, val)  __atomic_store_n(ptr, val, __ATOMIC_RELEASE)
#define helix_atomic_xchg(ptr, val)   __atomic_exchange_n(ptr, val, __ATOMIC_ACQ_REL)

/* ========================================================================
 * Multi-client / Multi-scanout support
 * ======================================================================== */

/* Forward declaration */
static void helix_destroy_scanout_blit(HelixFrameExport *fe, uint32_t scanout_id);

/*
 * Read exactly n bytes from a non-blocking socket.
 * Uses poll() to wait for data, since the socket is O_NONBLOCK
 * (required for reliable non-blocking send on macOS — MSG_DONTWAIT
 * is unreliable and can block in __sendto on closing sockets).
 */
static bool read_exact_bytes(int fd, void *buf, size_t n)
{
    size_t total = 0;
    while (total < n) {
        ssize_t r = recv(fd, (uint8_t *)buf + total, n - total, 0);
        if (r > 0) {
            total += r;
            continue;
        }
        if (r == 0) {
            return false;  /* EOF — peer closed */
        }
        /* r < 0 */
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            /* Socket is O_NONBLOCK — wait for data with poll().
             * 60s timeout: if client is silent for this long, the
             * connection is dead. Frees the client slot promptly. */
            struct pollfd pfd = { .fd = fd, .events = POLLIN };
            int ret = poll(&pfd, 1, 60 * 1000);
            if (ret <= 0) {
                return false;  /* Timeout or error */
            }
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                return false;  /* Socket error */
            }
            continue;  /* Data available, retry recv */
        }
        return false;  /* Other error */
    }
    return true;
}

/*
 * Send exactly n bytes on a non-blocking socket, using poll() to wait.
 * Used for control-plane messages (SUBSCRIBE_RESP, SCANOUT_RESP, PONG)
 * that MUST be delivered for the protocol to work.
 * Returns true on success, false on error/timeout.
 */
static bool send_exact_bytes(int fd, const void *buf, size_t n)
{
    size_t total = 0;
    while (total < n) {
        ssize_t sent = send(fd, (const uint8_t *)buf + total, n - total, 0);
        if (sent > 0) {
            total += sent;
            continue;
        }
        if (sent == 0) {
            return false;
        }
        /* sent < 0 */
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            /* Wait up to 10 seconds for socket to become writable */
            struct pollfd pfd = { .fd = fd, .events = POLLOUT };
            int ret = poll(&pfd, 1, 10 * 1000);
            if (ret <= 0) {
                return false;  /* Timeout or error */
            }
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                return false;
            }
            continue;  /* Socket writable, retry send */
        }
        return false;  /* Other error (EPIPE, ECONNRESET, etc.) */
    }
    return true;
}

/* Global singleton */
static HelixFrameExport *g_helix_export = NULL;

HelixFrameExport *helix_get_frame_export(void)
{
    return g_helix_export;
}

/*
 * Send H.264 data to all clients subscribed to a specific scanout.
 * Called from encoder callback with encoded frame data.
 */
static void helix_send_to_subscribed_clients(HelixFrameExport *fe,
                                               uint32_t scanout_id,
                                               const uint8_t *response_data,
                                               size_t response_size)
{
    pthread_mutex_lock(&fe->clients_lock);
    for (int i = 0; i < HELIX_MAX_CLIENTS; i++) {
        HelixClient *c = &fe->clients[i];
        if (!c->active || !c->subscribed) continue;
        if (c->subscribed_scanout != scanout_id) continue;

        pthread_mutex_lock(&c->send_lock);
        /* Non-blocking send — if TCP buffer is full, drop the entire
         * frame for this client rather than blocking the VT callback
         * thread. Partial sends permanently desync the TCP stream
         * (client reads garbage until next magic match), so we close
         * the connection to force a clean reconnect. */
        ssize_t sent = send(c->fd, response_data, response_size,
                            MSG_DONTWAIT);
        bool should_disconnect = false;
        if (sent < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                helix_log("[HELIX] Send error client %d (scanout %u): %s",
                          i, scanout_id, strerror(errno));
                should_disconnect = true;
            }
        } else if ((size_t)sent != response_size) {
            helix_log("[HELIX] Partial send to client %d: %zd/%zu bytes — "
                      "closing to prevent stream corruption", i, sent,
                      response_size);
            should_disconnect = true;
        }
        pthread_mutex_unlock(&c->send_lock);

        if (should_disconnect) {
            /* Shutdown the socket — client handler thread will detect
             * the error on its next recv() and clean up properly. */
            shutdown(c->fd, SHUT_RDWR);
        }
    }
    pthread_mutex_unlock(&fe->clients_lock);
}

/*
 * Encoder output callback for per-scanout auto-encoding.
 * The outputCallbackRefCon is a packed uint64: high32=scanout_id, low32=0.
 * The sourceFrameRefCon is the pts.
 */
typedef struct ScanoutEncoderCtx {
    HelixFrameExport *fe;
    uint32_t scanout_id;
} ScanoutEncoderCtx;

static void scanout_encoder_callback(void *outputCallbackRefCon,
                                       void *sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer)
{
    ScanoutEncoderCtx *ctx = (ScanoutEncoderCtx *)outputCallbackRefCon;
    if (!ctx || !ctx->fe || !ctx->fe->valid) return;

    HelixFrameExport *fe = ctx->fe;
    uint32_t scanout_id = ctx->scanout_id;
    /* Unpack slot index from sourceFrameRefCon (low 8 bits) */
    uintptr_t ref = (uintptr_t)sourceFrameRefCon;
    uint32_t slot = ref & 0xFF;

    /* Mark ring slot as free — VT is done with this IOSurface.
     * Clear slot_busy BEFORE vt_busy so the main thread never sees
     * vt_busy=false while slot_busy is still true. */
    if (slot < HELIX_BLIT_RING_SIZE && scanout_id < HELIX_MAX_SCANOUTS) {
        helix_atomic_store(&fe->scanout_encoders[scanout_id].blit_slot_busy[slot], false);
    }

    if (status != noErr || !sampleBuffer) {
        fe->encode_errors++;
        /* Clear vt_busy even on error — otherwise the encoder is stuck forever */
        if (scanout_id < HELIX_MAX_SCANOUTS) {
            helix_atomic_store(&fe->scanout_encoders[scanout_id].vt_busy, false);
        }
        return;
    }

    /* Check if this is a keyframe */
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    bool is_keyframe = true;
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        if (notSync && CFBooleanGetValue(notSync)) {
            is_keyframe = false;
        }
    }

    /* Extract SPS/PPS for keyframes */
    uint8_t *sps_pps_data = NULL;
    size_t sps_pps_size = 0;

    if (is_keyframe) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmt) {
            size_t paramCount = 0;
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, 0, NULL, NULL, &paramCount, NULL);

            if (paramCount > 0) {
                size_t total_param_size = 0;
                for (size_t i = 0; i < paramCount; i++) {
                    const uint8_t *paramData = NULL;
                    size_t paramSize = 0;
                    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            fmt, i, &paramData, &paramSize, NULL, NULL) == noErr) {
                        total_param_size += 4 + paramSize;
                    }
                }

                sps_pps_data = malloc(total_param_size);
                if (sps_pps_data) {
                    size_t offset = 0;
                    for (size_t i = 0; i < paramCount; i++) {
                        const uint8_t *paramData = NULL;
                        size_t paramSize = 0;
                        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                                fmt, i, &paramData, &paramSize, NULL, NULL) == noErr && paramData) {
                            sps_pps_data[offset++] = 0x00;
                            sps_pps_data[offset++] = 0x00;
                            sps_pps_data[offset++] = 0x00;
                            sps_pps_data[offset++] = 0x01;
                            memcpy(sps_pps_data + offset, paramData, paramSize);
                            offset += paramSize;
                        }
                    }
                    sps_pps_size = offset;
                }
            }
        }
    }

    /* Get data buffer */
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) {
        free(sps_pps_data);
        helix_atomic_store(&fe->scanout_encoders[scanout_id].vt_busy, false);
        return;
    }

    size_t totalLength = 0;
    char *dataPtr = NULL;
    if (CMBlockBufferGetDataPointer(dataBuffer, 0, NULL, &totalLength, &dataPtr) != noErr) {
        free(sps_pps_data);
        helix_atomic_store(&fe->scanout_encoders[scanout_id].vt_busy, false);
        return;
    }

    /* Convert avcc to Annex B */
    size_t annexb_size = sps_pps_size + totalLength;
    uint8_t *annexb_data = malloc(annexb_size);
    if (!annexb_data) {
        free(sps_pps_data);
        helix_atomic_store(&fe->scanout_encoders[scanout_id].vt_busy, false);
        return;
    }

    size_t src_offset = 0, dst_offset = 0;

    if (sps_pps_data) {
        if (sps_pps_size > 0) {
            memcpy(annexb_data, sps_pps_data, sps_pps_size);
            dst_offset = sps_pps_size;
        }
        free(sps_pps_data);
        sps_pps_data = NULL;
    }

    while (src_offset + 4 <= totalLength) {
        uint32_t nal_len = ((uint8_t)dataPtr[src_offset] << 24) |
                           ((uint8_t)dataPtr[src_offset + 1] << 16) |
                           ((uint8_t)dataPtr[src_offset + 2] << 8) |
                           ((uint8_t)dataPtr[src_offset + 3]);
        src_offset += 4;
        if (src_offset + nal_len > totalLength) break;

        annexb_data[dst_offset++] = 0x00;
        annexb_data[dst_offset++] = 0x00;
        annexb_data[dst_offset++] = 0x00;
        annexb_data[dst_offset++] = 0x01;
        memcpy(annexb_data + dst_offset, dataPtr + src_offset, nal_len);
        dst_offset += nal_len;
        src_offset += nal_len;
    }

    /* Build response with scanout_id as session_id */
    size_t response_size = sizeof(HelixFrameResponse) + sizeof(uint32_t) + dst_offset;
    uint8_t *response = malloc(response_size);
    if (!response) {
        free(annexb_data);
        helix_atomic_store(&fe->scanout_encoders[scanout_id].vt_busy, false);
        return;
    }

    HelixFrameResponse *resp = (HelixFrameResponse *)response;
    resp->header.magic = HELIX_MSG_MAGIC;
    resp->header.msg_type = HELIX_MSG_FRAME_RESPONSE;
    resp->header.flags = 0;
    resp->header.session_id = (uint16_t)scanout_id;
    resp->header.payload_size = response_size - sizeof(HelixMsgHeader);

    CMTime pts_time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime decode_time = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
    resp->pts = (int64_t)(CMTimeGetSeconds(pts_time) * 1000000000.0);
    resp->dts = (int64_t)(CMTimeGetSeconds(decode_time) * 1000000000.0);
    resp->is_keyframe = is_keyframe ? 1 : 0;
    resp->nal_count = 1;

    uint32_t nal_size = (uint32_t)dst_offset;
    memcpy(response + sizeof(HelixFrameResponse), &nal_size, sizeof(nal_size));
    memcpy(response + sizeof(HelixFrameResponse) + sizeof(uint32_t),
           annexb_data, dst_offset);
    free(annexb_data);

    /* Send to all subscribed clients */
    helix_send_to_subscribed_clients(fe, scanout_id, response, response_size);

    fe->frames_encoded++;
    free(response);

    /* Clear vt_busy AFTER sending — main thread won't submit next frame
     * until we're fully done with this one. */
    helix_atomic_store(&fe->scanout_encoders[scanout_id].vt_busy, false);
}

/* Per-scanout encoder context storage (leaked intentionally - lives for process lifetime) */
static ScanoutEncoderCtx g_scanout_ctx[HELIX_MAX_SCANOUTS];

/*
 * SPICE GL context — shared with virglrenderer's contexts.
 * All virglrenderer EGL contexts are created sharing with spice_gl_ctx
 * (via qemu_egl_create_context which uses eglGetCurrentContext() as
 * share context while spice_gl_ctx is current). Our helix_egl_ctx
 * must share with spice_gl_ctx to access virglrenderer textures.
 */
extern void *spice_gl_ctx;  /* QEMUGLContext from spice-display.c */

/*
 * Initialize Helix EGL context for GL blit operations.
 * Creates a context in spice_gl_ctx's share group so we can
 * access virglrenderer textures.
 */
static int helix_init_egl_context(HelixFrameExport *fe)
{
    if (fe->helix_egl_ctx) {
        return 0;
    }

    if (!spice_gl_ctx) {
        helix_log("[GL_BLIT] ERROR: spice_gl_ctx not initialized yet");
        return -1;
    }

    static const EGLint ctx_att_gles[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };

    EGLContext ctx = eglCreateContext(qemu_egl_display, qemu_egl_config,
                                     (EGLContext)spice_gl_ctx, ctx_att_gles);
    if (ctx == EGL_NO_CONTEXT) {
        helix_log("[GL_BLIT] ERROR: eglCreateContext failed (err=0x%x)",
                  eglGetError());
        return -1;
    }

    fe->helix_egl_ctx = ctx;
    helix_log("[GL_BLIT] Created Helix EGL context %p sharing with spice_gl_ctx %p",
              ctx, spice_gl_ctx);
    return 0;
}

/* Helper: create CFNumber from int for IOSurface properties */
static void AddIntegerValue_helix(CFMutableDictionaryRef dict, CFStringRef key, int value)
{
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    CFDictionarySetValue(dict, key, num);
    CFRelease(num);
}

/*
 * Create one IOSurface + EGL surface + GL texture + FBO for a ring slot.
 * Returns 0 on success, -1 on failure.
 */
static int helix_create_blit_slot(HelixFrameExport *fe, HelixScanoutEncoder *enc,
                                   int slot, int32_t width, int32_t height)
{
    /* 1. Create destination IOSurface (BGRA, same as SPICE) */
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    AddIntegerValue_helix(dict, kIOSurfaceWidth, width);
    AddIntegerValue_helix(dict, kIOSurfaceHeight, height);
    AddIntegerValue_helix(dict, kIOSurfacePixelFormat, 'BGRA');
    AddIntegerValue_helix(dict, kIOSurfaceBytesPerElement, 4);

    IOSurfaceRef surface = IOSurfaceCreate(dict);
    CFRelease(dict);

    if (!surface) {
        return -1;
    }

    /* 2. Create ANGLE EGL surface wrapping the IOSurface */
    EGLint attribs[] = {
        EGL_WIDTH,                         width,
        EGL_HEIGHT,                        height,
        EGL_IOSURFACE_PLANE_ANGLE,         0,
        EGL_TEXTURE_TARGET,                EGL_TEXTURE_2D,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT,                EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE,            GL_UNSIGNED_BYTE,
        EGL_IOSURFACE_USAGE_HINT_ANGLE,    EGL_IOSURFACE_WRITE_HINT_ANGLE,
        EGL_NONE,                          EGL_NONE,
    };

    EGLSurface esurface = qemu_egl_init_buffer_surface(
        (EGLContext)fe->helix_egl_ctx,
        EGL_IOSURFACE_ANGLE, surface, attribs);

    if (!esurface) {
        CFRelease(surface);
        return -1;
    }

    /* 3. Create GL texture and bind the EGL surface to it */
    GLuint dst_tex;
    glGenTextures(1, &dst_tex);
    glBindTexture(GL_TEXTURE_2D, dst_tex);
    eglBindTexImage(qemu_egl_display, esurface, EGL_BACK_BUFFER);

    /* 4. Create FBO and attach the IOSurface-backed texture */
    GLuint dst_fbo;
    glGenFramebuffers(1, &dst_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, dst_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, dst_tex, 0);

    GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fbo_status != GL_FRAMEBUFFER_COMPLETE) {
        glDeleteFramebuffers(1, &dst_fbo);
        glDeleteTextures(1, &dst_tex);
        eglReleaseTexImage(qemu_egl_display, esurface, EGL_BACK_BUFFER);
        qemu_egl_destroy_surface(esurface);
        CFRelease(surface);
        return -1;
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    enc->blit_surfaces[slot] = surface;
    enc->blit_egl_surfaces[slot] = esurface;
    enc->blit_textures[slot] = dst_tex;
    enc->blit_fbos[slot] = dst_fbo;

    return 0;
}

/*
 * Set up triple-buffered GL blit ring for a scanout.
 * Creates HELIX_BLIT_RING_SIZE IOSurface+FBO pairs.
 */
static int helix_setup_scanout_blit(HelixFrameExport *fe, uint32_t scanout_id,
                                     int32_t width, int32_t height)
{
    HelixScanoutEncoder *enc = &fe->scanout_encoders[scanout_id];

    /* Already set up at correct size? */
    if (enc->blit_surfaces[0] && enc->blit_width == width && enc->blit_height == height) {
        return 0;
    }

    /* Tear down previous blit state */
    helix_destroy_scanout_blit(fe, scanout_id);

    /* Ensure EGL context exists */
    if (helix_init_egl_context(fe) != 0) {
        return -1;
    }

    /* Make our EGL context current for all slot creation */
    if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                        (EGLContext)fe->helix_egl_ctx)) {
        helix_log("[GL_BLIT] ERROR: eglMakeCurrent failed (err=0x%x)", eglGetError());
        return -1;
    }

    /* Create all ring slots */
    for (int i = 0; i < HELIX_BLIT_RING_SIZE; i++) {
        if (helix_create_blit_slot(fe, enc, i, width, height) != 0) {
            helix_log("[GL_BLIT] ERROR: failed to create ring slot %d for scanout %u",
                      i, scanout_id);
            helix_destroy_scanout_blit(fe, scanout_id);
            return -1;
        }
    }

    /* Create shared source FBO (virgl texture attached per-frame) */
    glGenFramebuffers(1, &enc->blit_src_fbo);

    enc->blit_ring_idx = 0;
    for (int i = 0; i < HELIX_BLIT_RING_SIZE; i++) {
        helix_atomic_store(&enc->blit_slot_busy[i], false);
    }
    enc->blit_width = width;
    enc->blit_height = height;

    helix_log("[GL_BLIT] Setup scanout %u: %dx%d ring=%d slots",
              scanout_id, width, height, HELIX_BLIT_RING_SIZE);
    return 0;
}

/*
 * Tear down GL blit ring buffer for a scanout.
 */
static void helix_destroy_scanout_blit(HelixFrameExport *fe, uint32_t scanout_id)
{
    HelixScanoutEncoder *enc = &fe->scanout_encoders[scanout_id];

    bool has_any = false;
    for (int i = 0; i < HELIX_BLIT_RING_SIZE; i++) {
        if (enc->blit_surfaces[i]) { has_any = true; break; }
    }
    if (!has_any && !enc->blit_src_fbo) {
        return;
    }

    if (fe->helix_egl_ctx) {
        eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                        (EGLContext)fe->helix_egl_ctx);
    }

    if (enc->blit_src_fbo) {
        glDeleteFramebuffers(1, &enc->blit_src_fbo);
        enc->blit_src_fbo = 0;
    }

    for (int i = 0; i < HELIX_BLIT_RING_SIZE; i++) {
        if (enc->blit_fbos[i]) {
            glDeleteFramebuffers(1, &enc->blit_fbos[i]);
            enc->blit_fbos[i] = 0;
        }
        if (enc->blit_textures[i]) {
            glDeleteTextures(1, &enc->blit_textures[i]);
            enc->blit_textures[i] = 0;
        }
        if (enc->blit_egl_surfaces[i]) {
            eglReleaseTexImage(qemu_egl_display,
                                (EGLSurface)enc->blit_egl_surfaces[i], EGL_BACK_BUFFER);
            qemu_egl_destroy_surface((EGLSurface)enc->blit_egl_surfaces[i]);
            enc->blit_egl_surfaces[i] = NULL;
        }
        if (enc->blit_surfaces[i]) {
            CFRelease(enc->blit_surfaces[i]);
            enc->blit_surfaces[i] = NULL;
        }
    }

    enc->blit_ring_idx = 0;
    helix_atomic_store(&enc->vt_busy, false);
    for (int i = 0; i < HELIX_BLIT_RING_SIZE; i++) {
        helix_atomic_store(&enc->blit_slot_busy[i], false);
    }
    enc->blit_width = 0;
    enc->blit_height = 0;

    helix_log("[GL_BLIT] Destroyed blit ring for scanout %u", scanout_id);
}

/*
 * GL blit from virglrenderer texture to the next IOSurface in the ring.
 * Returns the IOSurface containing the captured frame, or NULL on error.
 *
 * Zero-copy: the returned IOSurface is passed directly to VideoToolbox
 * via CVPixelBufferCreateWithIOSurface — no CPU memcpy.
 *
 * Triple-buffered: while VT asynchronously encodes slots N-1 and N-2,
 * we write to slot N. At 60fps with ~5ms hardware encode, 3 slots
 * provides ample margin.
 */
static IOSurfaceRef helix_gl_blit_frame(HelixFrameExport *fe, uint32_t scanout_id,
                                         uint32_t slot,
                                         GLuint tex_id, int32_t width, int32_t height)
{
    HelixScanoutEncoder *enc = &fe->scanout_encoders[scanout_id];

    /* Save current EGL context so we can restore it after the blit.
     * We're called from inside virgl_cmd_set_scanout — virglrenderer
     * has its own context current. If we don't restore it, subsequent
     * virglrenderer GL calls go to the wrong context → corruption. */
    EGLContext saved_ctx = eglGetCurrentContext();
    EGLSurface saved_read = eglGetCurrentSurface(EGL_READ);
    EGLSurface saved_draw = eglGetCurrentSurface(EGL_DRAW);

    /* glFlush on virglrenderer's context (currently active) to submit
     * pending rendering commands. We use glFlush not glFinish because
     * glFinish stalls the QEMU main loop. The per-slot busy flags
     * provide backpressure instead of gl_block (which is global and
     * would cause one slow scanout to block all others). */
    glFlush();

    /* Ensure blit ring is set up (this may call eglMakeCurrent) */
    if (helix_setup_scanout_blit(fe, scanout_id, width, height) != 0) {
        eglMakeCurrent(qemu_egl_display, saved_draw, saved_read, saved_ctx);
        return NULL;
    }

    /* Make our EGL context current */
    if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                        (EGLContext)fe->helix_egl_ctx)) {
        eglMakeCurrent(qemu_egl_display, saved_draw, saved_read, saved_ctx);
        return NULL;
    }

    /* Attach source virgl texture to read FBO */
    glBindFramebuffer(GL_READ_FRAMEBUFFER, enc->blit_src_fbo);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, tex_id, 0);

    /* Bind this slot's IOSurface FBO for writing */
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, enc->blit_fbos[slot]);

    /* Blit: virgl texture → IOSurface[slot] */
    glBlitFramebuffer(0, 0, width, height,
                      0, 0, width, height,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    /* glFlush: submit GL commands but don't block.
     * glFinish() hangs the main thread (stalls process_cmdq → guest GPU deadlock).
     * SPICE uses glFlush() for the same reason. The triple-buffered ring provides
     * enough latency for the blit to complete before VT reads the IOSurface. */
    glFlush();

    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);

    /* Restore previous EGL context */
    eglMakeCurrent(qemu_egl_display, saved_draw, saved_read, saved_ctx);

    return enc->blit_surfaces[slot];
}

/*
 * Stub: helix_set_scanout_metal_texture is no longer used.
 * Venus/KosmicKrisp never provides Metal handles (native_type=0).
 * Frame capture now uses GL blit (like SPICE) instead.
 */
void helix_set_scanout_metal_texture(uint32_t scanout_id, uintptr_t metal_handle)
{
    (void)scanout_id;
    (void)metal_handle;
}

/*
 * Create per-scanout encoder session
 */
static int create_scanout_encoder(HelixFrameExport *fe, uint32_t scanout_id,
                                    int32_t width, int32_t height,
                                    int32_t bitrate)
{
    if (scanout_id >= HELIX_MAX_SCANOUTS) return -1;

    /* Serialize encoder creation — called from both the main loop
     * (resolution change) and client handler threads (CONFIG_REQ).
     * Without this, concurrent calls could double-free the VT session. */
    pthread_mutex_lock(&fe->mutex);

    HelixScanoutEncoder *enc = &fe->scanout_encoders[scanout_id];

    /* Clean up existing session */
    if (enc->session) {
        VTCompressionSessionCompleteFrames(enc->session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(enc->session);
        CFRelease(enc->session);
        enc->session = NULL;
    }

    /* Source image attributes */
    CFMutableDictionaryRef sourceAttrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef ioSurfaceProps = CFDictionaryCreate(
        kCFAllocatorDefault, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(sourceAttrs, kCVPixelBufferIOSurfacePropertiesKey,
                         ioSurfaceProps);
    CFRelease(ioSurfaceProps);

    /* Set up callback context */
    g_scanout_ctx[scanout_id].fe = fe;
    g_scanout_ctx[scanout_id].scanout_id = scanout_id;

    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault, width, height,
        kCMVideoCodecType_H264,
        NULL, sourceAttrs, NULL,
        scanout_encoder_callback,
        &g_scanout_ctx[scanout_id],
        &enc->session);

    CFRelease(sourceAttrs);

    if (status != noErr) {
        helix_log("[HELIX] VTCompressionSessionCreate failed for scanout %u: %d",
                  scanout_id, (int)status);
        pthread_mutex_unlock(&fe->mutex);
        return -1;
    }

    /* Configure for low-latency streaming */
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

    /* Force one-in-one-out encoding */
    int maxFrameDelay = 0;
    CFNumberRef maxFrameDelayRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxFrameDelay);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_MaxFrameDelayCount, maxFrameDelayRef);
    CFRelease(maxFrameDelayRef);

    /* Target frame rate for rate control */
    int expectedFPS = 60;
    CFNumberRef expectedFPSRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &expectedFPS);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_ExpectedFrameRate, expectedFPSRef);
    CFRelease(expectedFPSRef);

    int maxKeyFrame = 60;
    CFNumberRef maxKeyFrameRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxKeyFrame);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, maxKeyFrameRef);
    CFRelease(maxKeyFrameRef);

    /* Use provided bitrate, or auto-scale from resolution (~4 bits/pixel) */
    int effective_bitrate = bitrate;
    if (effective_bitrate <= 0) {
        int64_t pixels = (int64_t)width * (int64_t)height;
        effective_bitrate = (int32_t)(pixels * 4);
        if (effective_bitrate < 5000000) effective_bitrate = 5000000;  /* 5 Mbps minimum */
    }
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &effective_bitrate);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    /* H.264 Constrained Baseline — matches what the SPS rewriter and
     * browser decoder expect (avc1.42d028, constraint_set3_flag=1). */
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel);

    status = VTCompressionSessionPrepareToEncodeFrames(enc->session);
    if (status != noErr) {
        helix_log("[HELIX] PrepareToEncodeFrames failed for scanout %u: %d",
                  scanout_id, (int)status);
        CFRelease(enc->session);
        enc->session = NULL;
        pthread_mutex_unlock(&fe->mutex);
        return -1;
    }

    enc->width = width;
    enc->height = height;
    enc->bitrate = effective_bitrate;
    enc->configured = true;

    helix_log("[HELIX] Created encoder for scanout %u: %dx%d bitrate=%d",
              scanout_id, width, height, effective_bitrate);
    pthread_mutex_unlock(&fe->mutex);
    return 0;
}

/* GL blit subsystem is implemented above (helix_init_egl_context through
 * helix_gl_blit_frame). See ring buffer design comments in helix-frame-export.h. */




/*
 * Auto-encode a scanout frame on page flip.
 * Called from helix_update_scanout_displaysurface() in virtio-gpu-virgl.c
 * whenever a scanout's DisplaySurface is updated.
 *
 * Zero-copy pipeline:
 * 1. Checks if any clients are subscribed to this scanout
 * 2. Creates/updates the per-scanout encoder if needed
 * 3. GL blit from virgl tex_id → IOSurface (via ANGLE, same as SPICE)
 * 4. CVPixelBufferCreateWithIOSurface wraps IOSurface (no CPU copy)
 * 5. VTCompressionSessionEncodeFrame → H.264 → subscribed clients
 */
void helix_scanout_frame_ready(void *virtio_gpu, uint32_t scanout_id,
                                uint32_t resource_id)
{
    static uint64_t entry_count = 0;
    entry_count++;
    HelixFrameExport *fe = g_helix_export;
    if (!fe || !fe->valid || scanout_id >= HELIX_MAX_SCANOUTS) {
        if (entry_count <= 5 || (entry_count % 1000) == 0) {
            helix_log("[FRAME_READY_ENTRY] #%llu scanout=%u fe=%p valid=%d EARLY_RETURN",
                      entry_count, scanout_id, (void *)fe, fe ? fe->valid : -1);
        }
        return;
    }

    /* Check if anyone is subscribed to this scanout */
    bool has_subscriber = false;
    int active_clients = 0;
    pthread_mutex_lock(&fe->clients_lock);
    for (int i = 0; i < HELIX_MAX_CLIENTS; i++) {
        if (fe->clients[i].active) {
            active_clients++;
            if (fe->clients[i].subscribed &&
                fe->clients[i].subscribed_scanout == scanout_id) {
                has_subscriber = true;
            }
        }
    }
    pthread_mutex_unlock(&fe->clients_lock);

    if (!has_subscriber) {
        if (entry_count <= 5 || (entry_count % 1000) == 0) {
            helix_log("[FRAME_READY_ENTRY] #%llu scanout=%u active_clients=%d NO_SUBSCRIBER",
                      entry_count, scanout_id, active_clients);
        }
        return;
    }

    static uint64_t ready_count = 0;
    ready_count++;
    if (ready_count <= 5 || (ready_count % 100) == 0) {
        helix_log("[FRAME_READY] #%llu scanout=%u resource=%u has_subscriber=YES",
                  ready_count, scanout_id, resource_id);
    }

    /*
     * Zero-copy GL blit path (same approach as SPICE's qemu_spice_gl_update):
     *   virgl tex_id → [glBlitFramebuffer] → IOSurface[ring_slot]
     *   → [CVPixelBufferCreateWithIOSurface] → CVPixelBuffer
     *   → [VTCompressionSessionEncodeFrame] → H.264
     *
     * No CPU memcpy at any step. Triple-buffered ring prevents VT async
     * reads from conflicting with GL writes.
     */
    uint32_t res_id = virtio_gpu_get_scanout_resource_id(virtio_gpu, scanout_id);
    if (res_id == 0) {
        return;
    }

    struct virgl_renderer_resource_info_ext info_ext = {0};
    int ret = virgl_renderer_resource_get_info_ext(res_id, &info_ext);
    if (ret != 0) {
        return;
    }

    uint32_t width = info_ext.base.width;
    uint32_t height = info_ext.base.height;
    uint32_t tex_id = info_ext.base.tex_id;

    if (width == 0 || height == 0 || tex_id == 0) {
        return;
    }

    if (ready_count <= 5) {
        helix_log("[FRAME_READY] scanout %u: tex_id=%u %ux%u",
                  scanout_id, tex_id, width, height);
    }

    /* Create or update encoder */
    HelixScanoutEncoder *enc = &fe->scanout_encoders[scanout_id];
    if (!enc->configured || enc->width != (int32_t)width || enc->height != (int32_t)height) {
        int32_t prev_bitrate = enc->bitrate;
        if (create_scanout_encoder(fe, scanout_id, width, height, prev_bitrate) != 0) {
            return;
        }
    }

    /* Check if VT is still processing the previous frame.
     * With MaxFrameDelayCount=0, VTCompressionSessionEncodeFrame BLOCKS
     * until the previous callback completes. If we called EncodeFrame
     * while VT is busy, the QEMU main loop would freeze — killing SSH,
     * console, everything. Instead, we drop the frame pre-encode.
     * This is the PRIMARY defense against main loop hangs. */
    if (helix_atomic_load(&enc->vt_busy)) {
        static uint64_t vt_busy_drops = 0;
        vt_busy_drops++;
        if (vt_busy_drops <= 5 || (vt_busy_drops % 500) == 0) {
            helix_log("[FRAME_READY] Dropping frame — VT still processing "
                      "previous frame (dropped %llu total)", vt_busy_drops);
        }
        return;
    }

    /* Select ring slot and advance index (both done here so they stay
     * in sync — the blit function uses the slot we chose). */
    uint32_t slot = enc->blit_ring_idx;
    enc->blit_ring_idx = (slot + 1) % HELIX_BLIT_RING_SIZE;

    /* If this slot is still being encoded by VT, drop the frame.
     * Secondary safety net — with vt_busy check above, this should
     * rarely trigger. Per-scanout: one slow scanout only drops its
     * own frames, not other scanouts'. */
    if (helix_atomic_load(&enc->blit_slot_busy[slot])) {
        static uint64_t backpressure_drops = 0;
        backpressure_drops++;
        if (backpressure_drops <= 5 || (backpressure_drops % 500) == 0) {
            helix_log("[FRAME_READY] Dropping frame — slot %u still encoding "
                      "(dropped %llu total)", slot, backpressure_drops);
        }
        return;
    }

    IOSurfaceRef blit_surface = helix_gl_blit_frame(fe, scanout_id, slot,
                                                      tex_id, width, height);

    if (!blit_surface) {
        static uint64_t blit_fail_count = 0;
        blit_fail_count++;
        if (blit_fail_count <= 10 || (blit_fail_count % 1000) == 0) {
            helix_log("[FRAME_READY] GL blit failed for scanout %u "
                      "(tex_id=%u %ux%u) — frame dropped #%llu",
                      scanout_id, tex_id, width, height, blit_fail_count);
        }
        return;
    }

    /* Wrap IOSurface directly as CVPixelBuffer — zero-copy */
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cvRet = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault, blit_surface, NULL, &pixelBuffer);

    if (cvRet != kCVReturnSuccess || !pixelBuffer) {
        static uint64_t cvpb_fail_count = 0;
        cvpb_fail_count++;
        if (cvpb_fail_count <= 10 || (cvpb_fail_count % 1000) == 0) {
            helix_log("[FRAME_READY] ERROR: CVPixelBufferCreateWithIOSurface failed "
                      "for scanout %u: %d — frame dropped #%llu",
                      scanout_id, (int)cvRet, cvpb_fail_count);
        }
        return;
    }

    /* Generate monotonic PTS */
    enc->frame_count++;
    int64_t pts = enc->frame_count * 16666667;  /* ~60fps in nanoseconds */
    CMTime cmPts = CMTimeMake(pts, 1000000000);
    CMTime cmDuration = CMTimeMake(16666667, 1000000000);

    /* Force keyframe on first frame only */
    CFMutableDictionaryRef frameProps = NULL;
    if (enc->frame_count == 1) {
        frameProps = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(frameProps,
                             kVTEncodeFrameOptionKey_ForceKeyFrame,
                             kCFBooleanTrue);
    }

    /* Hold fe->mutex during EncodeFrame to prevent a TOCTOU race:
     * without this, a client handler's CONFIG_REQ could call
     * create_scanout_encoder which invalidates and CFReleases the old
     * session between our read of enc->session and the EncodeFrame call.
     * Since vt_busy=false guarantees VT's queue is empty,
     * EncodeFrame returns in microseconds — no main loop stall. */
    pthread_mutex_lock(&fe->mutex);

    if (!enc->session) {
        /* Encoder was torn down between our check and the lock */
        pthread_mutex_unlock(&fe->mutex);
        if (frameProps) CFRelease(frameProps);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    /* Mark ring slot as busy and VT as in-flight, then submit.
     * Pass slot index in sourceFrameRefCon (low 8 bits).
     * vt_busy MUST be set BEFORE EncodeFrame — it prevents the next
     * helix_scanout_frame_ready from calling EncodeFrame while VT is
     * processing, which would block the QEMU main loop. */
    helix_atomic_store(&enc->blit_slot_busy[slot], true);
    helix_atomic_store(&enc->vt_busy, true);

    OSStatus encStatus = VTCompressionSessionEncodeFrame(
        enc->session, pixelBuffer, cmPts, cmDuration,
        frameProps, (void *)(uintptr_t)slot, NULL);

    pthread_mutex_unlock(&fe->mutex);

    if (enc->frame_count <= 5 || (enc->frame_count % 100) == 0) {
        helix_log("[ENCODE] scanout=%u frame=%lld slot=%u status=%d %ux%u",
                  scanout_id, enc->frame_count, slot, (int)encStatus,
                  width, height);
    }

    if (encStatus != noErr) {
        /* Encode failed — callback won't fire, so clear busy flags */
        helix_atomic_store(&enc->blit_slot_busy[slot], false);
        helix_atomic_store(&enc->vt_busy, false);
    }

    if (frameProps) CFRelease(frameProps);
    CVPixelBufferRelease(pixelBuffer);
}

/* ========================================================================
 * Multi-client TCP server
 * ======================================================================== */

/*
 * Add a client to the client list. Returns client index or -1.
 */
static int helix_add_client(HelixFrameExport *fe, int fd)
{
    pthread_mutex_lock(&fe->clients_lock);
    for (int i = 0; i < HELIX_MAX_CLIENTS; i++) {
        if (!fe->clients[i].active) {
            fe->clients[i].fd = fd;
            fe->clients[i].active = true;
            fe->clients[i].subscribed = false;
            fe->clients[i].subscribed_scanout = 0;
            pthread_mutex_init(&fe->clients[i].send_lock, NULL);
            pthread_mutex_unlock(&fe->clients_lock);
            helix_log("[HELIX] Added client %d (fd=%d)", i, fd);
            return i;
        }
    }
    pthread_mutex_unlock(&fe->clients_lock);
    return -1;
}

/*
 * Remove a client from the client list.
 */
static void helix_remove_client(HelixFrameExport *fe, int client_idx)
{
    pthread_mutex_lock(&fe->clients_lock);
    if (client_idx >= 0 && client_idx < HELIX_MAX_CLIENTS) {
        HelixClient *c = &fe->clients[client_idx];
        if (c->active) {
            helix_log("[HELIX] Removing client %d (fd=%d, scanout=%u)",
                      client_idx, c->fd, c->subscribed_scanout);
            close(c->fd);
            c->active = false;
            c->subscribed = false;
            pthread_mutex_destroy(&c->send_lock);
        }
    }
    pthread_mutex_unlock(&fe->clients_lock);
}

/*
 * Per-client handler thread.
 * Reads messages from a single client and handles SUBSCRIBE, ENABLE_SCANOUT, etc.
 */
typedef struct ClientThreadArg {
    HelixFrameExport *fe;
    int client_idx;
} ClientThreadArg;

static void *client_handler_thread(void *arg)
{
    ClientThreadArg *cta = (ClientThreadArg *)arg;
    HelixFrameExport *fe = cta->fe;
    int client_idx = cta->client_idx;
    int client_fd = fe->clients[client_idx].fd;
    free(cta);

    helix_log("[HELIX] Client %d handler started (fd=%d)", client_idx, client_fd);

    while (1) {
        HelixMsgHeader header;
        if (!read_exact_bytes(client_fd, &header, sizeof(header))) {
            break;
        }

        if (header.magic != HELIX_MSG_MAGIC) {
            helix_log("[HELIX] Client %d: invalid magic 0x%x", client_idx, header.magic);
            break;
        }

        if (header.msg_type == HELIX_MSG_SUBSCRIBE) {
            /* Read subscribe payload: scanout_id (4 bytes) */
            uint32_t scanout_id;
            if (!read_exact_bytes(client_fd, &scanout_id, 4)) break;

            helix_log("[HELIX] Client %d subscribing to scanout %u (fe=%p g_fe=%p)",
                      client_idx, scanout_id, (void *)fe, (void *)g_helix_export);

            pthread_mutex_lock(&fe->clients_lock);
            fe->clients[client_idx].subscribed = true;
            fe->clients[client_idx].subscribed_scanout = scanout_id;
            pthread_mutex_unlock(&fe->clients_lock);

            /* Verify by checking immediately */
            helix_log("[HELIX] After subscribe: client[%d].active=%d .subscribed=%d .scanout=%u",
                      client_idx,
                      fe->clients[client_idx].active,
                      fe->clients[client_idx].subscribed,
                      fe->clients[client_idx].subscribed_scanout);

            /* Send subscribe response */
            uint8_t resp_buf[sizeof(HelixMsgHeader) + 8];
            HelixMsgHeader *resp_hdr = (HelixMsgHeader *)resp_buf;
            resp_hdr->magic = HELIX_MSG_MAGIC;
            resp_hdr->msg_type = HELIX_MSG_SUBSCRIBE_RESP;
            resp_hdr->flags = 0;
            resp_hdr->session_id = (uint16_t)scanout_id;
            resp_hdr->payload_size = 8;
            uint32_t *resp_data = (uint32_t *)(resp_buf + sizeof(HelixMsgHeader));
            resp_data[0] = scanout_id;
            resp_data[1] = 1;  /* success */

            pthread_mutex_lock(&fe->clients[client_idx].send_lock);
            bool ok = send_exact_bytes(client_fd, resp_buf, sizeof(resp_buf));
            pthread_mutex_unlock(&fe->clients[client_idx].send_lock);
            if (!ok) {
                helix_log("[HELIX] Client %d: failed to send SUBSCRIBE_RESP", client_idx);
                break;
            }

        } else if (header.msg_type == HELIX_MSG_ENABLE_SCANOUT) {
            uint32_t payload[4];
            if (!read_exact_bytes(client_fd, payload, 16)) break;

            /* Must hold BQL when calling QEMU device model functions
             * from a non-main thread. helix_enable_scanout modifies
             * virtio-gpu scanout state and calls graphic_console_init. */
            bql_lock_impl(__FILE__, __LINE__);
            int result = helix_enable_scanout(fe->virtio_gpu, payload[0],
                                              payload[1], payload[2]);
            bql_unlock();

            uint8_t resp_buf[sizeof(HelixMsgHeader) + 72];
            memset(resp_buf, 0, sizeof(resp_buf));
            HelixMsgHeader *resp_hdr = (HelixMsgHeader *)resp_buf;
            resp_hdr->magic = HELIX_MSG_MAGIC;
            resp_hdr->msg_type = HELIX_MSG_SCANOUT_RESP;
            resp_hdr->session_id = header.session_id;
            resp_hdr->payload_size = 72;
            uint32_t *resp_data = (uint32_t *)(resp_buf + sizeof(HelixMsgHeader));
            resp_data[0] = payload[0];
            resp_data[1] = (result == 0) ? 1 : 0;
            snprintf((char *)(resp_data + 2), 64, "Virtual-%u", payload[0] + 1);

            pthread_mutex_lock(&fe->clients[client_idx].send_lock);
            bool ok = send_exact_bytes(client_fd, resp_buf, sizeof(resp_buf));
            pthread_mutex_unlock(&fe->clients[client_idx].send_lock);
            if (!ok) {
                helix_log("[HELIX] Client %d: failed to send SCANOUT_RESP", client_idx);
                break;
            }

        } else if (header.msg_type == HELIX_MSG_DISABLE_SCANOUT) {
            uint32_t scanout_id;
            if (!read_exact_bytes(client_fd, &scanout_id, 4)) break;
            bql_lock_impl(__FILE__, __LINE__);
            helix_disable_scanout(fe->virtio_gpu, scanout_id);
            bql_unlock();

        } else if (header.msg_type == HELIX_MSG_PING) {
            HelixMsgHeader pong = {
                .magic = HELIX_MSG_MAGIC,
                .msg_type = HELIX_MSG_PONG,
                .session_id = header.session_id,
                .payload_size = 0
            };
            pthread_mutex_lock(&fe->clients[client_idx].send_lock);
            bool ok = send_exact_bytes(client_fd, &pong, sizeof(pong));
            pthread_mutex_unlock(&fe->clients[client_idx].send_lock);
            if (!ok) {
                helix_log("[HELIX] Client %d: failed to send PONG", client_idx);
                break;
            }

        } else if (header.msg_type == HELIX_MSG_CONFIG_REQ) {
            /* Per-scanout bitrate configuration from client */
            HelixConfigRequest cfg;
            memcpy(&cfg.header, &header, sizeof(header));
            size_t remaining = sizeof(HelixConfigRequest) - sizeof(HelixMsgHeader);
            if (!read_exact_bytes(client_fd, ((uint8_t *)&cfg) + sizeof(HelixMsgHeader),
                                  remaining)) break;

            /* Apply bitrate to the scanout this client is subscribed to */
            uint32_t target_scanout = fe->clients[client_idx].subscribed_scanout;
            int32_t new_bitrate = (int32_t)cfg.bitrate;

            helix_log("[HELIX] Client %d CONFIG_REQ: scanout=%u bitrate=%d",
                      client_idx, target_scanout, new_bitrate);

            if (target_scanout < HELIX_MAX_SCANOUTS && new_bitrate > 0) {
                HelixScanoutEncoder *enc = &fe->scanout_encoders[target_scanout];
                if (enc->configured && enc->bitrate != new_bitrate) {
                    /* Reconfigure encoder with new bitrate */
                    create_scanout_encoder(fe, target_scanout,
                                           enc->width, enc->height, new_bitrate);
                } else if (!enc->configured) {
                    /* Store bitrate for when encoder is created on first frame */
                    enc->bitrate = new_bitrate;
                }
            }

        } else {
            /* Skip unknown messages */
            if (header.payload_size > 0 && header.payload_size < 64 * 1024 * 1024) {
                uint8_t *skip = malloc(header.payload_size);
                if (skip) {
                    read_exact_bytes(client_fd, skip, header.payload_size);
                    free(skip);
                }
            }
        }
    }

    helix_log("[HELIX] Client %d disconnected", client_idx);
    helix_remove_client(fe, client_idx);
    return NULL;
}

/*
 * Multi-client accept thread - spawns a handler thread per client
 */
static void *multi_accept_thread(void *arg)
{
    HelixFrameExport *fe = (HelixFrameExport *)arg;

    while (1) {
        helix_log("[HELIX] Waiting for client connection...");

        int client_fd = accept(fe->listen_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            helix_log("[HELIX] Accept failed: %s", strerror(errno));
            break;
        }

        helix_log("[HELIX] Client connected (fd=%d)", client_fd);

        int keepalive = 1;
        setsockopt(client_fd, SOL_SOCKET, SO_KEEPALIVE, &keepalive, sizeof(keepalive));
#ifdef SO_NOSIGPIPE
        int nosigpipe = 1;
        setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
#endif

        /* Set socket to O_NONBLOCK — CRITICAL for macOS.
         * MSG_DONTWAIT is unreliable on macOS: send() can block in __sendto
         * even with MSG_DONTWAIT on sockets in closing/half-open states.
         * O_NONBLOCK is the only reliable way to get non-blocking sends.
         * read_exact_bytes() uses poll() to handle the non-blocking reads. */
        int flags = fcntl(client_fd, F_GETFL, 0);
        if (flags < 0 || fcntl(client_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            helix_log("[HELIX] CRITICAL: fcntl O_NONBLOCK failed (fd=%d): %s — "
                      "rejecting client to prevent potential deadlock",
                      client_fd, strerror(errno));
            close(client_fd);
            continue;
        }

        int client_idx = helix_add_client(fe, client_fd);
        if (client_idx < 0) {
            helix_log("[HELIX] No client slots available, rejecting");
            close(client_fd);
            continue;
        }

        ClientThreadArg *cta = malloc(sizeof(ClientThreadArg));
        if (!cta) {
            helix_log("[HELIX] Failed to allocate client thread arg");
            helix_remove_client(fe, client_idx);
            continue;
        }
        cta->fe = fe;
        cta->client_idx = client_idx;

        pthread_t thread;
        if (pthread_create(&thread, NULL, client_handler_thread, cta) != 0) {
            helix_log("[HELIX] Failed to create client thread");
            free(cta);
            helix_remove_client(fe, client_idx);
            continue;
        }
        pthread_detach(thread);
    }

    return NULL;
}

/*
 * Cleanup frame export (singleton lives for process lifetime,
 * but this is here for completeness).
 */
void helix_frame_export_cleanup(HelixFrameExport *fe)
{
    if (!fe) return;

    pthread_mutex_lock(&fe->mutex);
    fe->valid = false;
    pthread_mutex_unlock(&fe->mutex);

    /* Invalidate all encoder sessions — this cancels pending encodes
     * and prevents callbacks from firing after we return. */
    for (int i = 0; i < HELIX_MAX_SCANOUTS; i++) {
        HelixScanoutEncoder *enc = &fe->scanout_encoders[i];
        if (enc->session) {
            VTCompressionSessionInvalidate(enc->session);
            CFRelease(enc->session);
            enc->session = NULL;
        }
        helix_destroy_scanout_blit(fe, i);
    }

    if (fe->listen_fd >= 0) {
        close(fe->listen_fd);
    }

    pthread_mutex_destroy(&fe->mutex);
    pthread_mutex_destroy(&fe->clients_lock);
}

/*
 * Initialize frame export subsystem
 * Called from virtio_gpu_virgl_init() in QEMU
 */
int helix_frame_export_init(void *virtio_gpu, int vsock_port)
{
    helix_log("========================================");
    helix_log("[HELIX] VERSION: 2026-02-15-v10-ipa-granule-test");
    helix_log("[HELIX] BUILD: Multi-client, per-scanout auto-encode, assert(isv) restored");
    helix_log("========================================");
    helix_log("[HELIX] Initializing frame export on vsock port %d", vsock_port);

    /* If already initialized (e.g. guest reboot), just update virtio_gpu pointer */
    if (g_helix_export && g_helix_export->valid) {
        helix_log("[HELIX] Already initialized, updating virtio_gpu pointer");
        g_helix_export->virtio_gpu = virtio_gpu;
        return 0;
    }

    HelixFrameExport *fe = calloc(1, sizeof(HelixFrameExport));
    if (!fe) {
        error_report("[HELIX] Failed to allocate HelixFrameExport");
        return -1;
    }

    pthread_mutex_init(&fe->mutex, NULL);
    pthread_mutex_init(&fe->clients_lock, NULL);
    fe->valid = true;
    fe->virtio_gpu = virtio_gpu;
    fe->listen_fd = -1;

    /* Initialize client slots */
    for (int i = 0; i < HELIX_MAX_CLIENTS; i++) {
        fe->clients[i].active = false;
        fe->clients[i].fd = -1;
    }

    /* Initialize scanout encoder slots */
    for (int i = 0; i < HELIX_MAX_SCANOUTS; i++) {
        fe->scanout_encoders[i].session = NULL;
        fe->scanout_encoders[i].configured = false;
        fe->scanout_encoders[i].blit_ring_idx = 0;
        fe->scanout_encoders[i].blit_width = 0;
        fe->scanout_encoders[i].blit_height = 0;
        helix_atomic_store(&fe->scanout_encoders[i].vt_busy, false);
        for (int j = 0; j < HELIX_BLIT_RING_SIZE; j++) {
            fe->scanout_encoders[i].blit_surfaces[j] = NULL;
            fe->scanout_encoders[i].blit_egl_surfaces[j] = NULL;
            fe->scanout_encoders[i].blit_textures[j] = 0;
            fe->scanout_encoders[i].blit_fbos[j] = 0;
            helix_atomic_store(&fe->scanout_encoders[i].blit_slot_busy[j], false);
        }
        fe->scanout_encoders[i].blit_src_fbo = 0;
    }

    /* Set up TCP socket listener (BEFORE setting g_helix_export — if
     * setup fails and we free fe, g_helix_export must not point at
     * freed memory or helix_scanout_frame_ready will use-after-free) */
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        error_report("Failed to create TCP socket: %s", strerror(errno));
        free(fe);
        return -1;
    }

    int optval = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(vsock_port);

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        error_report("Failed to bind TCP socket on port %d: %s",
                     vsock_port, strerror(errno));
        close(listen_fd);
        free(fe);
        return -1;
    }

    if (listen(listen_fd, 16) < 0) {
        error_report("Failed to listen on TCP socket: %s", strerror(errno));
        close(listen_fd);
        free(fe);
        return -1;
    }

    fe->listen_fd = listen_fd;

    error_report("[HELIX] Frame export ready: TCP 127.0.0.1:%d (guest: 10.0.2.2:%d)",
                 vsock_port, vsock_port);

    /* Start multi-client accept thread */
    pthread_t thread;
    if (pthread_create(&thread, NULL, multi_accept_thread, fe) != 0) {
        error_report("Failed to create accept thread: %s", strerror(errno));
        close(listen_fd);
        free(fe);
        return -1;
    }
    pthread_detach(thread);

    /* Set global singleton LAST — after all setup succeeds. If we set it
     * earlier and setup fails, helix_scanout_frame_ready would dereference
     * freed memory on every page flip. */
    g_helix_export = fe;

    return 0;
}

#endif /* __APPLE__ */
