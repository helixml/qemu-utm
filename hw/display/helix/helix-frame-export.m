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

/*
 * VideoToolbox encoder output callback
 * Called asynchronously when a frame is encoded
 */
static void encoder_output_callback(void *outputCallbackRefCon,
                                    void *sourceFrameRefCon,
                                    OSStatus status,
                                    VTEncodeInfoFlags infoFlags,
                                    CMSampleBufferRef sampleBuffer)
{
    HelixFrameExport *fe = (HelixFrameExport *)outputCallbackRefCon;

    error_report("[HELIX] encoder_output_callback called: status=%d, sampleBuffer=%p",
                 (int)status, sampleBuffer);

    /* Safety check: ensure fe is valid */
    if (!fe) {
        fprintf(stderr, "[HELIX] encoder_output_callback: NULL fe pointer!\n");
        return;
    }

    /* Lock mutex for thread safety */
    pthread_mutex_lock(&fe->mutex);

    /* Check if struct is still valid */
    if (!fe->valid) {
        helix_log("[HELIX] encoder_output_callback: fe marked invalid, discarding frame");
        pthread_mutex_unlock(&fe->mutex);
        return;
    }

    int64_t pts = (int64_t)sourceFrameRefCon;

    if (status != noErr) {
        helix_log("[HELIX] VideoToolbox encode failed: %d", (int)status);
        fe->encode_errors++;
        pthread_mutex_unlock(&fe->mutex);
        return;
    }

    if (!sampleBuffer) {
        helix_log("[HELIX] encoder_output_callback: NULL sampleBuffer");
        pthread_mutex_unlock(&fe->mutex);
        return;
    }

    /* Check if socket is still valid before processing */
    if (fe->vsock_fd < 0) {
        helix_log("[HELIX] encoder_output_callback: socket closed, discarding frame");
        pthread_mutex_unlock(&fe->mutex);
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

    /*
     * For keyframes, extract SPS/PPS from the format description.
     * VideoToolbox stores these in CMFormatDescription, NOT in the data buffer.
     * h264parse needs SPS/PPS before it can process any slice data.
     */
    uint8_t *sps_pps_data = NULL;
    size_t sps_pps_size = 0;

    if (is_keyframe) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmt) {
            size_t paramCount = 0;
            int nalUnitHeaderLen = 0;
            OSStatus fmtErr = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, 0, NULL, NULL, &paramCount, &nalUnitHeaderLen);

            if (fmtErr == noErr && paramCount > 0) {
                /* First pass: calculate total size needed */
                size_t total_param_size = 0;
                for (size_t i = 0; i < paramCount; i++) {
                    const uint8_t *paramData = NULL;
                    size_t paramSize = 0;
                    fmtErr = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, i, &paramData, &paramSize, NULL, NULL);
                    if (fmtErr == noErr) {
                        total_param_size += 4 + paramSize; /* 4-byte start code + NAL data */
                    }
                }

                /* Allocate and fill SPS/PPS buffer */
                sps_pps_data = malloc(total_param_size);
                if (sps_pps_data) {
                    size_t offset = 0;
                    for (size_t i = 0; i < paramCount; i++) {
                        const uint8_t *paramData = NULL;
                        size_t paramSize = 0;
                        fmtErr = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            fmt, i, &paramData, &paramSize, NULL, NULL);
                        if (fmtErr == noErr && paramData) {
                            /* Write Annex B start code */
                            sps_pps_data[offset++] = 0x00;
                            sps_pps_data[offset++] = 0x00;
                            sps_pps_data[offset++] = 0x00;
                            sps_pps_data[offset++] = 0x01;
                            /* Copy parameter set data */
                            memcpy(sps_pps_data + offset, paramData, paramSize);
                            offset += paramSize;
                            helix_log("[HELIX] Parameter set %zu: %zu bytes (NAL type %d)",
                                      i, paramSize, paramData[0] & 0x1F);
                        }
                    }
                    sps_pps_size = offset;
                    helix_log("[HELIX] Extracted %zu parameter sets, total %zu bytes",
                              paramCount, sps_pps_size);
                }
            }
        }
    }

    /* Get the data buffer */
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) {
        error_report("No data buffer in sample\n");
        free(sps_pps_data);
        return;
    }

    size_t totalLength = 0;
    char *dataPtr = NULL;
    OSStatus err = CMBlockBufferGetDataPointer(dataBuffer, 0, NULL,
                                                &totalLength, &dataPtr);
    if (err != noErr || !dataPtr) {
        error_report("Failed to get data pointer: %d\n", (int)err);
        free(sps_pps_data);
        return;
    }

    /* VideoToolbox outputs H.264 in avcc format (4-byte length prefixes).
     * Convert to Annex B (start codes 0x00000001) for vsockenc.
     * For keyframes, prepend SPS/PPS extracted from format description. */
    size_t annexb_size = sps_pps_size + totalLength;
    uint8_t *annexb_data = malloc(annexb_size);
    if (!annexb_data) {
        error_report("Failed to allocate annexb buffer\n");
        free(sps_pps_data);
        pthread_mutex_unlock(&fe->mutex);
        return;
    }

    helix_log("[HELIX] Converting avcc to Annex B: input_size=%zu, sps_pps_size=%zu",
              totalLength, sps_pps_size);
    size_t src_offset = 0;
    size_t dst_offset = 0;

    /* Prepend SPS/PPS for keyframes */
    if (sps_pps_data && sps_pps_size > 0) {
        memcpy(annexb_data, sps_pps_data, sps_pps_size);
        dst_offset = sps_pps_size;
        free(sps_pps_data);
        sps_pps_data = NULL;
    }
    uint32_t nal_count_actual = 0;
    while (src_offset < totalLength) {
        /* Read 4-byte NAL length (big-endian) */
        if (src_offset + 4 > totalLength) {
            error_report("Invalid avcc data: truncated length prefix\n");
            free(annexb_data);
            pthread_mutex_unlock(&fe->mutex);
            return;
        }

        uint32_t nal_len = ((uint8_t)dataPtr[src_offset] << 24) |
                           ((uint8_t)dataPtr[src_offset + 1] << 16) |
                           ((uint8_t)dataPtr[src_offset + 2] << 8) |
                           ((uint8_t)dataPtr[src_offset + 3]);
        src_offset += 4;

        if (src_offset + nal_len > totalLength) {
            error_report("Invalid avcc data: NAL length %u exceeds buffer\n", nal_len);
            free(annexb_data);
            pthread_mutex_unlock(&fe->mutex);
            return;
        }

        /* Write Annex B start code */
        annexb_data[dst_offset++] = 0x00;
        annexb_data[dst_offset++] = 0x00;
        annexb_data[dst_offset++] = 0x00;
        annexb_data[dst_offset++] = 0x01;

        /* Copy NAL data */
        memcpy(annexb_data + dst_offset, dataPtr + src_offset, nal_len);
        dst_offset += nal_len;
        src_offset += nal_len;
        nal_count_actual++;
    }

    helix_log("[HELIX] Converted %u NAL units, output_size=%zu", nal_count_actual, dst_offset);

    /* Build response message */
    size_t response_size = sizeof(HelixFrameResponse) + sizeof(uint32_t) + dst_offset;
    uint8_t *response = malloc(response_size);
    if (!response) {
        error_report("Failed to allocate response buffer\n");
        free(annexb_data);
        pthread_mutex_unlock(&fe->mutex);
        return;
    }

    HelixFrameResponse *resp = (HelixFrameResponse *)response;
    resp->header.magic = HELIX_MSG_MAGIC;
    resp->header.msg_type = HELIX_MSG_FRAME_RESPONSE;
    resp->header.flags = 0;
    resp->header.session_id = fe->session_id;
    resp->header.payload_size = response_size - sizeof(HelixMsgHeader);

    CMTime decode_time = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
    resp->pts = pts;
    resp->dts = CMTimeGetSeconds(decode_time) * 1000000000LL;
    resp->is_keyframe = is_keyframe ? 1 : 0;
    resp->nal_count = 1;  /* Single blob with Annex B data */

    /* Write NAL size and Annex B data */
    uint32_t nal_size = (uint32_t)dst_offset;
    memcpy(response + sizeof(HelixFrameResponse), &nal_size, sizeof(nal_size));
    memcpy(response + sizeof(HelixFrameResponse) + sizeof(uint32_t),
           annexb_data, dst_offset);

    free(annexb_data);

    /* Send response over vsock (check if socket is still open) */
    if (fe->vsock_fd >= 0) {
        ssize_t sent = send(fe->vsock_fd, response, response_size, 0);
        if (sent < 0) {
            error_report("[HELIX] Failed to send response: %s\n", strerror(errno));
        } else {
            fe->frames_encoded++;
            fe->bytes_sent += sent;
            error_report("[HELIX] Frame sent successfully: %zu bytes, pts=%lld, keyframe=%d",
                         sent, pts, is_keyframe);
        }
    } else {
        helix_log("[HELIX] Callback fired but socket already closed, discarding frame");
    }

    pthread_mutex_unlock(&fe->mutex);
    free(response);
}

/*
 * Create and configure VideoToolbox encoder session
 */
static int create_encoder_session(HelixFrameExport *fe,
                                   int32_t width,
                                   int32_t height,
                                   int32_t bitrate,
                                   bool realtime)
{
    OSStatus status;

    /* Clean up existing session */
    if (fe->encoder_session) {
        VTCompressionSessionCompleteFrames(fe->encoder_session,
                                            kCMTimeInvalid);
        VTCompressionSessionInvalidate(fe->encoder_session);
        CFRelease(fe->encoder_session);
        fe->encoder_session = NULL;
    }

    /* Source image attributes (IOSurface-backed) */
    CFMutableDictionaryRef sourceAttrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    /* We accept IOSurface-backed pixel buffers */
    CFDictionarySetValue(sourceAttrs,
                         kCVPixelBufferIOSurfacePropertiesKey,
                         CFDictionaryCreate(kCFAllocatorDefault,
                                           NULL, NULL, 0,
                                           &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks));

    /* Create compression session */
    status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCMVideoCodecType_H264,
        NULL,           /* encoderSpecification - let VT choose */
        sourceAttrs,    /* sourceImageBufferAttributes */
        NULL,           /* compressedDataAllocator */
        encoder_output_callback,
        fe,             /* outputCallbackRefCon */
        &fe->encoder_session
    );

    CFRelease(sourceAttrs);

    if (status != noErr) {
        error_report("VTCompressionSessionCreate failed: %d\n", (int)status);
        return -1;
    }

    /* Configure for low latency if requested */
    if (realtime) {
        VTSessionSetProperty(fe->encoder_session,
                             kVTCompressionPropertyKey_RealTime,
                             kCFBooleanTrue);

        /* Disable B-frames for lower latency */
        VTSessionSetProperty(fe->encoder_session,
                             kVTCompressionPropertyKey_AllowFrameReordering,
                             kCFBooleanFalse);

        /* Max keyframe interval (1 per second at 60fps) */
        int maxKeyFrameInterval = 60;
        CFNumberRef maxKeyFrameIntervalRef = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberIntType, &maxKeyFrameInterval);
        VTSessionSetProperty(fe->encoder_session,
                             kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             maxKeyFrameIntervalRef);
        CFRelease(maxKeyFrameIntervalRef);
    }

    /* Set bitrate */
    if (bitrate > 0) {
        CFNumberRef bitrateRef = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberIntType, &bitrate);
        VTSessionSetProperty(fe->encoder_session,
                             kVTCompressionPropertyKey_AverageBitRate,
                             bitrateRef);
        CFRelease(bitrateRef);
    }

    /* H.264 Baseline Profile for low-latency streaming (no B-frames) */
    VTSessionSetProperty(fe->encoder_session,
                         kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Baseline_AutoLevel);

    /* Prepare to encode */
    status = VTCompressionSessionPrepareToEncodeFrames(fe->encoder_session);
    if (status != noErr) {
        error_report("PrepareToEncodeFrames failed: %d\n", (int)status);
        CFRelease(fe->encoder_session);
        fe->encoder_session = NULL;
        return -1;
    }

    fe->width = width;
    fe->height = height;
    fe->bitrate = bitrate;
    fe->realtime = realtime;
    fe->configured = true;

    return 0;
}

/*
 * Get the current scanout resource ID
 * Returns the resource_id of scanout 0, or 0 if none set
 */
static uint32_t helix_get_scanout_resource(void *virtio_gpu)
{
    uint32_t resource_id = virtio_gpu_get_scanout_resource_id(virtio_gpu, 0);

    error_report("[HELIX] Current scanout[0] resource_id=%u", resource_id);

    return resource_id;
}

/*
 * Create IOSurface from virtio-gpu resource via readback
 *
 * Due to ANGLE layer, resources are GL textures wrapped by ANGLE,
 * not direct Metal textures. We try two approaches:
 * 1. virgl_renderer_resource_map() - direct memory mapping (preferred)
 * 2. virgl_renderer_transfer_read_iov() - explicit transfer (fallback)
 *
 * This involves one CPU copy, but it works with ANGLE.
 */
IOSurfaceRef helix_get_iosurface_for_resource(void *virtio_gpu,
                                               uint32_t resource_id)
{
    struct virgl_renderer_resource_info_ext info_ext = {0};

    helix_log("[HELIX] Looking up resource_id=%u", resource_id);

    int ret = virgl_renderer_resource_get_info_ext(resource_id, &info_ext);
    if (ret != 0) {
        helix_log("[HELIX] virgl_renderer_resource_get_info_ext failed: ret=%d", ret);
        return NULL;
    }

    uint32_t width = info_ext.base.width;
    uint32_t height = info_ext.base.height;
    uint32_t stride = info_ext.base.stride;

    helix_log("[HELIX] Resource %u: native_type=%d, width=%u, height=%u, stride=%u",
             resource_id, info_ext.native_type, width, height, stride);

    if (width == 0 || height == 0) {
        helix_log("[HELIX] Invalid resource dimensions");
        return NULL;
    }

    /* Calculate buffer size (BGRA8888 = 4 bytes per pixel) */
    size_t bytes_per_pixel = 4;
    size_t row_bytes = width * bytes_per_pixel;
    size_t buffer_size = row_bytes * height;

    void *pixel_data = NULL;
    void *mapped_data = NULL;
    uint64_t mapped_size = 0;

    /* Skip resources that are too small (likely being destroyed/recreated) */
    if (width < 64 || height < 64) {
        helix_log("[HELIX] Resource %u dimensions too small (%ux%u), skipping",
                 resource_id, width, height);
        return NULL;
    }

    /* Try method 1: Direct resource mapping (works for blob resources) */
    helix_log("[HELIX] Attempting direct resource map for resource %u", resource_id);
    ret = virgl_renderer_resource_map(resource_id, &mapped_data, &mapped_size);

    if (ret == 0 && mapped_data && mapped_size >= buffer_size) {
        helix_log("[HELIX] Successfully mapped resource %u: %p, size=%llu",
                 resource_id, mapped_data, mapped_size);
        pixel_data = malloc(buffer_size);
        if (pixel_data) {
            memcpy(pixel_data, mapped_data, buffer_size);
            virgl_renderer_resource_unmap(resource_id);
            helix_log("[HELIX] Copied %zu bytes from mapped resource", buffer_size);
        } else {
            virgl_renderer_resource_unmap(resource_id);
            helix_log("[HELIX] Failed to allocate copy buffer");
            return NULL;
        }
    } else {
        /* Method 2: Transfer read (fallback for non-blob resources) */
        helix_log("[HELIX] Resource map failed (ret=%d), trying transfer_read_iov", ret);

        pixel_data = malloc(buffer_size);
        if (!pixel_data) {
            helix_log("[HELIX] Failed to allocate %zu bytes for pixel data", buffer_size);
            return NULL;
        }

        struct iovec iov = {
            .iov_base = pixel_data,
            .iov_len = buffer_size
        };

        struct {
            uint32_t x, y, z;
            uint32_t w, h, d;
        } box = {
            .x = 0,
            .y = 0,
            .z = 0,
            .w = width,
            .h = height,
            .d = 1
        };

        helix_log("[HELIX] Reading pixel data from resource %u (%ux%u) via transfer",
                 resource_id, width, height);

        /* Force context 0 before transfer (required for some resources) */
        virgl_renderer_force_ctx_0();

        /* CRITICAL: Re-validate resource still exists before transfer
         * The guest compositor can free scanout resources at any time.
         * Without this check, virgl_renderer_transfer_read_iov() will crash
         * trying to read from freed memory (race condition).
         */
        helix_log("[HELIX] Re-validating resource %u before transfer (race condition check)", resource_id);
        struct virgl_renderer_resource_info_ext recheck = {0};
        ret = virgl_renderer_resource_get_info_ext(resource_id, &recheck);
        helix_log("[HELIX] Re-validation: ret=%d, width=%u->%u, height=%u->%u",
                 ret, width, recheck.base.width, height, recheck.base.height);

        if (ret != 0 || recheck.base.width != width || recheck.base.height != height) {
            helix_log("[HELIX] ERROR: Resource %u no longer valid (ret=%d) - likely freed by compositor",
                     resource_id, ret);
            helix_log("[HELIX] This is the race condition - scanout was freed between lookup and transfer");
            free(pixel_data);
            return NULL;
        }
        helix_log("[HELIX] Resource %u still valid, proceeding with transfer", resource_id);

        helix_log("[HELIX] About to call virgl_renderer_transfer_read_iov (THIS IS WHERE CRASH HAPPENS IF RESOURCE FREED)...");
        helix_log("[HELIX] Transfer params: resource=%u, ctx=0, stride=%u, box=(%ux%u)",
                 resource_id, stride, width, height);

        ret = virgl_renderer_transfer_read_iov(
            resource_id,
            0,          /* ctx_id */
            0,          /* level */
            stride,     /* stride */
            0,          /* layer_stride */
            (struct virgl_box *)&box,
            0,          /* offset */
            &iov,
            1           /* iovec_cnt */
        );

        helix_log("[HELIX] ✅ virgl_renderer_transfer_read_iov COMPLETED successfully: ret=%d", ret);

        if (ret != 0) {
            helix_log("[HELIX] virgl_renderer_transfer_read_iov failed: ret=%d", ret);
            free(pixel_data);
            return NULL;
        }

        helix_log("[HELIX] Successfully read %zu bytes via transfer", buffer_size);
    }

    /* Create IOSurface from pixel data */
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
    CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
    CFNumberRef bytesPerRow = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &row_bytes);
    uint32_t pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef pixelFormatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pixelFormat);

    CFDictionarySetValue(props, kIOSurfaceWidth, widthNum);
    CFDictionarySetValue(props, kIOSurfaceHeight, heightNum);
    CFDictionarySetValue(props, kIOSurfaceBytesPerRow, bytesPerRow);
    CFDictionarySetValue(props, kIOSurfacePixelFormat, pixelFormatNum);

    CFRelease(widthNum);
    CFRelease(heightNum);
    CFRelease(bytesPerRow);
    CFRelease(pixelFormatNum);

    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);

    if (!surface) {
        helix_log("[HELIX] Failed to create IOSurface");
        free(pixel_data);
        return NULL;
    }

    /* Lock IOSurface and copy pixel data */
    helix_log("[HELIX] Locking IOSurface %p to copy %zu bytes of pixel data", surface, buffer_size);
    IOSurfaceLock(surface, 0, NULL);
    void *surface_base = IOSurfaceGetBaseAddress(surface);
    helix_log("[HELIX] IOSurface base address: %p, copying pixel data...", surface_base);
    memcpy(surface_base, pixel_data, buffer_size);
    IOSurfaceUnlock(surface, 0, NULL);
    helix_log("[HELIX] IOSurface unlocked, pixel data copied successfully");

    free(pixel_data);

    helix_log("[HELIX] ✅ Successfully created IOSurface %p (%ux%u) from resource %u",
             surface, width, height, resource_id);

    return surface;
}

/*
 * Get IOSurface from scanout DisplaySurface (SAFE - no race condition)
 *
 * This reads from the DisplaySurface (QEMU-managed memory) instead of
 * directly from GPU resources. The DisplaySurface is updated during
 * SET_SCANOUT and damage notifications, so it's always safe to read.
 */
IOSurfaceRef helix_get_iosurface_from_scanout(void *virtio_gpu,
                                                uint32_t scanout_id)
{
    helix_log("[HELIX-v3] helix_get_iosurface_from_scanout called: scanout_id=%u", scanout_id);

    if (!virtio_gpu) {
        helix_log("[HELIX] ERROR: virtio_gpu pointer is NULL");
        return NULL;
    }

    /* Use safe helper function from virtio-gpu-virgl.c to get DisplaySurface data
     * This avoids accessing DisplaySurface struct directly and prevents crashes */
    uint32_t width = 0, height = 0, stride = 0;
    void *data = NULL;

    bool success = virtio_gpu_get_scanout_surface_data(
        virtio_gpu, scanout_id, &width, &height, &stride, &data);

    if (!success) {
        helix_log("[HELIX] Failed to get DisplaySurface data for scanout %u", scanout_id);
        helix_log("[HELIX] DisplaySurface may not be initialized yet (no SET_SCANOUT_BLOB command)");
        return NULL;
    }

    helix_log("[HELIX] DisplaySurface data retrieved: %ux%u, stride=%u", width, height, stride);

    /* Calculate expected size */
    size_t bytes_per_pixel = 4;  /* BGRA8888 */
    size_t row_bytes = width * bytes_per_pixel;
    size_t buffer_size = row_bytes * height;

    /* Create IOSurface from DisplaySurface pixel data */
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
    CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
    CFNumberRef bytesPerRow = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &row_bytes);
    uint32_t pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef pixelFormatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pixelFormat);

    CFDictionarySetValue(props, kIOSurfaceWidth, widthNum);
    CFDictionarySetValue(props, kIOSurfaceHeight, heightNum);
    CFDictionarySetValue(props, kIOSurfaceBytesPerRow, bytesPerRow);
    CFDictionarySetValue(props, kIOSurfacePixelFormat, pixelFormatNum);

    CFRelease(widthNum);
    CFRelease(heightNum);
    CFRelease(bytesPerRow);
    CFRelease(pixelFormatNum);

    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);

    if (!surface) {
        helix_log("[HELIX] Failed to create IOSurface");
        return NULL;
    }

    /* Lock IOSurface and copy pixel data from DisplaySurface */
    IOSurfaceLock(surface, 0, NULL);
    void *surface_base = IOSurfaceGetBaseAddress(surface);

    /* Copy row by row in case strides differ */
    if (stride == row_bytes) {
        /* Fast path: strides match, single memcpy */
        memcpy(surface_base, data, buffer_size);
    } else {
        /* Slow path: copy row by row */
        for (uint32_t y = 0; y < height; y++) {
            memcpy((uint8_t *)surface_base + y * row_bytes,
                   (uint8_t *)data + y * stride,
                   row_bytes);
        }
    }

    IOSurfaceUnlock(surface, 0, NULL);

    helix_log("[HELIX] ✅ Successfully created IOSurface %p (%ux%u) from DisplaySurface (scanout %u)",
             surface, width, height, scanout_id);

    return surface;
}

/*
 * Encode an IOSurface frame
 */
int helix_encode_iosurface(HelixFrameExport *fe,
                           IOSurfaceRef surface,
                           int64_t pts,
                           int64_t duration,
                           bool force_keyframe)
{
    if (!fe->configured || !fe->encoder_session) {
        return HELIX_ERR_NOT_CONFIGURED;
    }

    /* Create CVPixelBuffer from IOSurface (zero-copy) */
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cvRet = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault,
        surface,
        NULL,  /* pixelBufferAttributes */
        &pixelBuffer
    );

    if (cvRet != kCVReturnSuccess || !pixelBuffer) {
        error_report("CVPixelBufferCreateWithIOSurface failed: %d\n", cvRet);
        return HELIX_ERR_NO_IOSURFACE;
    }

    /* Presentation timestamp */
    CMTime cmPts = CMTimeMake(pts, 1000000000);  /* nanoseconds */
    CMTime cmDuration = CMTimeMake(duration, 1000000000);

    /* Frame properties */
    CFMutableDictionaryRef frameProps = NULL;
    if (force_keyframe) {
        frameProps = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(frameProps,
                             kVTEncodeFrameOptionKey_ForceKeyFrame,
                             kCFBooleanTrue);
    }

    /* Encode the frame */
    OSStatus status = VTCompressionSessionEncodeFrame(
        fe->encoder_session,
        pixelBuffer,
        cmPts,
        cmDuration,
        frameProps,
        (void *)pts,  /* sourceFrameRefCon - pass pts for callback */
        NULL          /* infoFlagsOut */
    );

    if (frameProps) {
        CFRelease(frameProps);
    }
    CVPixelBufferRelease(pixelBuffer);

    if (status != noErr) {
        error_report("VTCompressionSessionEncodeFrame failed: %d\n", (int)status);
        return HELIX_ERR_ENCODE_FAILED;
    }

    return HELIX_ERR_OK;
}

/*
 * Create NV12 bi-planar IOSurface from raw pixel data.
 *
 * NV12 layout: Y plane (full resolution) + UV plane (half resolution, interleaved).
 * Total size = width * height * 1.5
 *
 * VideoToolbox natively encodes from NV12 ('420v'), so this avoids the
 * internal BGRA→NV12 colorspace conversion that happens with BGRA input.
 */
static IOSurfaceRef helix_create_nv12_iosurface(const uint8_t *pixel_data,
                                                  size_t pixel_data_size,
                                                  uint32_t width,
                                                  uint32_t height)
{
    uint32_t y_stride = width;
    uint32_t uv_stride = width;  /* NV12: interleaved CbCr, half width but 2 bytes per pair */
    uint32_t uv_height = height / 2;
    size_t y_size = (size_t)y_stride * height;
    size_t uv_size = (size_t)uv_stride * uv_height;
    size_t total_size = y_size + uv_size;

    if (pixel_data_size < total_size) {
        helix_log("[HELIX] NV12 pixel data too small: got %zu, expected %zu (%ux%u)",
                  pixel_data_size, total_size, width, height);
        return NULL;
    }

    /* Create bi-planar IOSurface with NV12 format */
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    int w = (int)width, h = (int)height;
    uint32_t pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    int plane_count = 2;

    CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &w);
    CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &h);
    CFNumberRef pixelFormatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pixel_format);
    CFNumberRef planeCountNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &plane_count);

    CFDictionarySetValue(props, kIOSurfaceWidth, widthNum);
    CFDictionarySetValue(props, kIOSurfaceHeight, heightNum);
    CFDictionarySetValue(props, kIOSurfacePixelFormat, pixelFormatNum);

    /* Plane info array */
    CFMutableArrayRef planeArray = CFArrayCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeArrayCallBacks);

    /* Plane 0: Y (luma) - full resolution, 1 byte per element */
    {
        CFMutableDictionaryRef plane = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);

        int pw = w, ph = h, pbpr = (int)y_stride, pbpe = 1;
        size_t ps = y_size;
        CFNumberRef pWidth = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pw);
        CFNumberRef pHeight = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &ph);
        CFNumberRef pBPR = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pbpr);
        CFNumberRef pBPE = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pbpe);
        CFNumberRef pSize = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &ps);

        CFDictionarySetValue(plane, kIOSurfacePlaneWidth, pWidth);
        CFDictionarySetValue(plane, kIOSurfacePlaneHeight, pHeight);
        CFDictionarySetValue(plane, kIOSurfacePlaneBytesPerRow, pBPR);
        CFDictionarySetValue(plane, kIOSurfacePlaneBytesPerElement, pBPE);
        CFDictionarySetValue(plane, kIOSurfacePlaneSize, pSize);

        CFRelease(pWidth);
        CFRelease(pHeight);
        CFRelease(pBPR);
        CFRelease(pBPE);
        CFRelease(pSize);

        CFArrayAppendValue(planeArray, plane);
        CFRelease(plane);
    }

    /* Plane 1: UV (chroma) - half resolution, 2 bytes per element (interleaved CbCr) */
    {
        CFMutableDictionaryRef plane = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);

        int pw = w / 2, ph = (int)uv_height, pbpr = (int)uv_stride, pbpe = 2;
        size_t ps = uv_size;
        CFNumberRef pWidth = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pw);
        CFNumberRef pHeight = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &ph);
        CFNumberRef pBPR = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pbpr);
        CFNumberRef pBPE = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pbpe);
        CFNumberRef pSize = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &ps);

        CFDictionarySetValue(plane, kIOSurfacePlaneWidth, pWidth);
        CFDictionarySetValue(plane, kIOSurfacePlaneHeight, pHeight);
        CFDictionarySetValue(plane, kIOSurfacePlaneBytesPerRow, pBPR);
        CFDictionarySetValue(plane, kIOSurfacePlaneBytesPerElement, pBPE);
        CFDictionarySetValue(plane, kIOSurfacePlaneSize, pSize);

        CFRelease(pWidth);
        CFRelease(pHeight);
        CFRelease(pBPR);
        CFRelease(pBPE);
        CFRelease(pSize);

        CFArrayAppendValue(planeArray, plane);
        CFRelease(plane);
    }

    CFDictionarySetValue(props, kIOSurfacePlaneInfo, planeArray);

    CFRelease(widthNum);
    CFRelease(heightNum);
    CFRelease(pixelFormatNum);
    CFRelease(planeCountNum);
    CFRelease(planeArray);

    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);

    if (!surface) {
        helix_log("[HELIX] Failed to create NV12 IOSurface");
        return NULL;
    }

    /* Copy Y and UV planes into the IOSurface */
    IOSurfaceLock(surface, 0, NULL);

    void *y_base = IOSurfaceGetBaseAddressOfPlane(surface, 0);
    size_t y_dest_stride = IOSurfaceGetBytesPerRowOfPlane(surface, 0);

    void *uv_base = IOSurfaceGetBaseAddressOfPlane(surface, 1);
    size_t uv_dest_stride = IOSurfaceGetBytesPerRowOfPlane(surface, 1);

    /* Copy Y plane */
    if (y_dest_stride == y_stride) {
        memcpy(y_base, pixel_data, y_size);
    } else {
        for (uint32_t row = 0; row < height; row++) {
            memcpy((uint8_t *)y_base + row * y_dest_stride,
                   pixel_data + row * y_stride,
                   y_stride);
        }
    }

    /* Copy UV plane */
    const uint8_t *uv_src = pixel_data + y_size;
    if (uv_dest_stride == uv_stride) {
        memcpy(uv_base, uv_src, uv_size);
    } else {
        for (uint32_t row = 0; row < uv_height; row++) {
            memcpy((uint8_t *)uv_base + row * uv_dest_stride,
                   uv_src + row * uv_stride,
                   uv_stride);
        }
    }

    IOSurfaceUnlock(surface, 0, NULL);

    helix_log("[HELIX] Created NV12 IOSurface %p (%ux%u) from %zu bytes (Y=%zu + UV=%zu)",
              surface, width, height, pixel_data_size, y_size, uv_size);

    return surface;
}

/*
 * Create IOSurface from raw pixel data received over the network.
 * This is used when the guest sends SHM pixel data (resource_id=0)
 * because the host can't read container-internal screen data from
 * the VM's GPU resources or DisplaySurface.
 *
 * Supports BGRA (single-plane) and NV12 (bi-planar) formats.
 */
static IOSurfaceRef helix_create_iosurface_from_pixels(const uint8_t *pixel_data,
                                                         size_t pixel_data_size,
                                                         uint32_t width,
                                                         uint32_t height,
                                                         uint32_t stride,
                                                         uint32_t format)
{
    if (!pixel_data || pixel_data_size == 0 || width == 0 || height == 0) {
        helix_log("[HELIX] Invalid pixel data parameters");
        return NULL;
    }

    /* NV12 bi-planar path */
    if (format == HELIX_FORMAT_NV12) {
        return helix_create_nv12_iosurface(pixel_data, pixel_data_size, width, height);
    }

    /* BGRA/RGBA single-plane path */
    uint32_t pixel_format = kCVPixelFormatType_32BGRA;  /* default */
    size_t bytes_per_pixel = 4;
    if (format == HELIX_FORMAT_RGBA8888) {
        pixel_format = kCVPixelFormatType_32RGBA;
    }

    size_t row_bytes = width * bytes_per_pixel;
    size_t expected_size = stride * height;

    /* Sanity check */
    if (pixel_data_size < expected_size) {
        helix_log("[HELIX] Pixel data too small: got %zu, expected %zu (%ux%u, stride=%u)",
                  pixel_data_size, expected_size, width, height, stride);
        /* Try with row_bytes if stride wasn't set correctly */
        expected_size = row_bytes * height;
        if (pixel_data_size < expected_size) {
            helix_log("[HELIX] Still too small even with calculated stride, aborting");
            return NULL;
        }
    }

    /* Create IOSurface */
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
    CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
    CFNumberRef bytesPerRow = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &row_bytes);
    CFNumberRef pixelFormatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pixel_format);

    CFDictionarySetValue(props, kIOSurfaceWidth, widthNum);
    CFDictionarySetValue(props, kIOSurfaceHeight, heightNum);
    CFDictionarySetValue(props, kIOSurfaceBytesPerRow, bytesPerRow);
    CFDictionarySetValue(props, kIOSurfacePixelFormat, pixelFormatNum);

    CFRelease(widthNum);
    CFRelease(heightNum);
    CFRelease(bytesPerRow);
    CFRelease(pixelFormatNum);

    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);

    if (!surface) {
        helix_log("[HELIX] Failed to create IOSurface from pixel data");
        return NULL;
    }

    /* Copy pixel data into IOSurface */
    IOSurfaceLock(surface, 0, NULL);
    void *surface_base = IOSurfaceGetBaseAddress(surface);

    if (stride == row_bytes) {
        /* Fast path: strides match */
        memcpy(surface_base, pixel_data, row_bytes * height);
    } else {
        /* Slow path: copy row by row (source stride != dest stride) */
        for (uint32_t y = 0; y < height; y++) {
            memcpy((uint8_t *)surface_base + y * row_bytes,
                   pixel_data + y * stride,
                   row_bytes);
        }
    }

    IOSurfaceUnlock(surface, 0, NULL);

    helix_log("[HELIX] Created IOSurface %p (%ux%u) from %zu bytes of pixel data",
              surface, width, height, pixel_data_size);

    return surface;
}

/*
 * Handle frame request from guest
 *
 * When pixel_data is non-NULL, the guest sent raw pixel data (SHM buffer)
 * and we encode those pixels directly. Otherwise, we read from the VM's
 * DisplaySurface (which shows the VM desktop, not container screens).
 */
static int handle_frame_request(HelixFrameExport *fe,
                                 const HelixFrameRequest *req,
                                 uint8_t *pixel_data,
                                 size_t pixel_data_size)
{
    helix_log("[HELIX] Frame request: resource_id=%u, %ux%u, pts=%lld, pixel_data=%s (%zu bytes)",
             req->resource_id, req->width, req->height, req->pts,
             pixel_data ? "YES" : "NO", pixel_data_size);

    /* Auto-configure encoder on first frame or resolution change */
    if (!fe->configured ||
        fe->width != (int32_t)req->width ||
        fe->height != (int32_t)req->height) {

        error_report("[HELIX] Configuring encoder: %ux%u, 8Mbps, realtime",
                     req->width, req->height);

        int ret = create_encoder_session(fe, req->width, req->height,
                                          8000000,  /* 8 Mbps default */
                                          true);    /* realtime */
        if (ret != 0) {
            error_report("[HELIX] Failed to create encoder session");
            return HELIX_ERR_INTERNAL;
        }
    }

    IOSurfaceRef surface = NULL;

    if (pixel_data && pixel_data_size > 0) {
        /*
         * Guest sent raw pixel data from container's screen capture.
         * Create IOSurface directly from the received pixels.
         * This is the correct path for container-internal video streaming.
         */
        helix_log("[HELIX] Using pixel data from guest (%zu bytes)", pixel_data_size);
        surface = helix_create_iosurface_from_pixels(
            pixel_data, pixel_data_size,
            req->width, req->height, req->stride, req->format);
    } else {
        /*
         * No pixel data - fall back to reading from VM's DisplaySurface.
         * This captures the VM's own desktop, which is only useful for
         * debugging or when the VM screen itself needs to be streamed.
         */
        helix_log("[HELIX] No pixel data, falling back to DisplaySurface");
        surface = helix_get_iosurface_from_scanout(
            fe->virtio_gpu, 0  /* scanout_id */);
    }

    if (!surface) {
        error_report("[HELIX] Failed to get IOSurface for encoding");
        return HELIX_ERR_RESOURCE_NOT_FOUND;
    }

    /* Encode the frame */
    int ret = helix_encode_iosurface(fe, surface, req->pts, req->duration,
                                      req->force_keyframe != 0);

    CFRelease(surface);

    if (ret == HELIX_ERR_OK) {
        helix_log("[HELIX] Frame encode submitted (callback will send response)");
    } else {
        error_report("[HELIX] Frame encoding failed: %d", ret);
    }

    return HELIX_ERR_OK;
}

/*
 * Handle config request from guest
 */
static int handle_config_request(HelixFrameExport *fe,
                                  const HelixConfigRequest *req)
{
    int ret = create_encoder_session(fe,
                                      req->width,
                                      req->height,
                                      req->bitrate,
                                      req->realtime != 0);
    return ret == 0 ? HELIX_ERR_OK : HELIX_ERR_INTERNAL;
}

/*
 * Process incoming message from guest
 */
int helix_frame_export_process_msg(HelixFrameExport *fe,
                                    const uint8_t *data,
                                    size_t len)
{
    if (len < sizeof(HelixMsgHeader)) {
        return HELIX_ERR_INVALID_MSG;
    }

    const HelixMsgHeader *header = (const HelixMsgHeader *)data;

    if (header->magic != HELIX_MSG_MAGIC) {
        error_report("Invalid message magic: 0x%08x\n", header->magic);
        return HELIX_ERR_INVALID_MSG;
    }

    switch (header->msg_type) {
    case HELIX_MSG_FRAME_REQUEST:
        if (len < sizeof(HelixFrameRequest)) {
            return HELIX_ERR_INVALID_MSG;
        }
        return handle_frame_request(fe, (const HelixFrameRequest *)data, NULL, 0);

    case HELIX_MSG_CONFIG_REQ:
        if (len < sizeof(HelixConfigRequest)) {
            return HELIX_ERR_INVALID_MSG;
        }
        return handle_config_request(fe, (const HelixConfigRequest *)data);

    case HELIX_MSG_KEYFRAME_REQ:
        /* Force next frame to be keyframe */
        /* This is handled implicitly via force_keyframe in frame request */
        return HELIX_ERR_OK;

    case HELIX_MSG_PING:
        {
            /* Send pong response */
            HelixMsgHeader pong = {
                .magic = HELIX_MSG_MAGIC,
                .msg_type = HELIX_MSG_PONG,
                .flags = 0,
                .session_id = header->session_id,
                .payload_size = 0
            };
            send(fe->vsock_fd, &pong, sizeof(pong), 0);
            return HELIX_ERR_OK;
        }

    case HELIX_MSG_ENABLE_SCANOUT:
        {
            if (len < sizeof(HelixMsgHeader) + 16) {
                return HELIX_ERR_INVALID_MSG;
            }
            const uint8_t *payload = data + sizeof(HelixMsgHeader);
            uint32_t scanout_id = *(uint32_t *)payload;
            uint32_t width = *(uint32_t *)(payload + 4);
            uint32_t height = *(uint32_t *)(payload + 8);

            error_report("[HELIX] ENABLE_SCANOUT: id=%u, %ux%u\n",
                         scanout_id, width, height);

            int ret = helix_enable_scanout(fe->virtio_gpu, scanout_id, width, height);

            /* Send response */
            uint8_t resp_buf[sizeof(HelixMsgHeader) + 72];
            HelixMsgHeader *resp_hdr = (HelixMsgHeader *)resp_buf;
            resp_hdr->magic = HELIX_MSG_MAGIC;
            resp_hdr->msg_type = HELIX_MSG_SCANOUT_RESP;
            resp_hdr->flags = 0;
            resp_hdr->session_id = header->session_id;
            resp_hdr->payload_size = 72;
            uint32_t *resp_payload = (uint32_t *)(resp_buf + sizeof(HelixMsgHeader));
            resp_payload[0] = scanout_id;
            resp_payload[1] = (ret == 0) ? 1 : 0;
            snprintf((char *)(resp_payload + 2), 64, "Virtual-%u", scanout_id + 1);
            send(fe->vsock_fd, resp_buf, sizeof(resp_buf), 0);
            return HELIX_ERR_OK;
        }

    case HELIX_MSG_DISABLE_SCANOUT:
        {
            if (len < sizeof(HelixMsgHeader) + 4) {
                return HELIX_ERR_INVALID_MSG;
            }
            uint32_t scanout_id = *(uint32_t *)(data + sizeof(HelixMsgHeader));
            helix_disable_scanout(fe->virtio_gpu, scanout_id);
            return HELIX_ERR_OK;
        }

    default:
        error_report("Unknown message type: %d\n", header->msg_type);
        return HELIX_ERR_INVALID_MSG;
    }
}

/*
 * Cleanup frame export
 */
void helix_frame_export_cleanup(HelixFrameExport *fe)
{
    if (!fe) return;

    /* Mark struct as invalid to prevent callbacks from accessing it */
    pthread_mutex_lock(&fe->mutex);
    fe->valid = false;
    pthread_mutex_unlock(&fe->mutex);

    /* Wait for any pending callbacks to finish */
    usleep(100000);  /* 100ms */

    if (fe->encoder_session) {
        VTCompressionSessionCompleteFrames(fe->encoder_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(fe->encoder_session);
        CFRelease(fe->encoder_session);
    }

    if (fe->vsock_fd >= 0) {
        close(fe->vsock_fd);
    }

    /* Destroy mutex */
    pthread_mutex_destroy(&fe->mutex);

    free(fe);
}

/*
 * Forward declaration
 */
static void *vsock_accept_thread(void *arg);

/*
 * Read exactly n bytes from socket
 */
static bool read_exact_bytes(int fd, void *buf, size_t n)
{
    size_t total = 0;
    while (total < n) {
        ssize_t r = recv(fd, (uint8_t *)buf + total, n - total, 0);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return false;
        }
        total += r;
    }
    return true;
}

/*
 * vsock server thread - listens for connections and processes messages
 *
 * Uses a message-framing protocol: read header first to determine message
 * size, then read remaining payload. This supports large payloads (pixel data).
 */
static void *vsock_server_thread(void *arg)
{
    HelixFrameExport *fe = (HelixFrameExport *)arg;

    while (1) {
        /* Step 1: Read message header */
        HelixMsgHeader header;
        if (!read_exact_bytes(fe->vsock_fd, &header, sizeof(header))) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                error_report("[HELIX] Client recv timeout (10min idle), disconnecting");
            } else if (errno != EINTR) {
                error_report("[HELIX] vsock recv error: %s", strerror(errno));
            }
            break;
        }

        if (header.magic != HELIX_MSG_MAGIC) {
            error_report("[HELIX] Invalid message magic: 0x%08x", header.magic);
            break;
        }

        /* Step 2: Read the rest of the fixed-size message based on type */
        int ret = HELIX_ERR_OK;

        if (header.msg_type == HELIX_MSG_FRAME_REQUEST) {
            /* Read remaining HelixFrameRequest fields */
            HelixFrameRequest req;
            memcpy(&req.header, &header, sizeof(header));
            size_t remaining = sizeof(HelixFrameRequest) - sizeof(HelixMsgHeader);
            if (!read_exact_bytes(fe->vsock_fd, ((uint8_t *)&req) + sizeof(HelixMsgHeader),
                                  remaining)) {
                error_report("[HELIX] Failed to read frame request body");
                break;
            }

            /* Step 3: If HELIX_FLAG_PIXEL_DATA, read pixel data from socket */
            uint8_t *pixel_data = NULL;
            size_t pixel_data_size = 0;

            if (header.flags & HELIX_FLAG_PIXEL_DATA) {
                pixel_data_size = header.payload_size -
                                  (sizeof(HelixFrameRequest) - sizeof(HelixMsgHeader));
                if (pixel_data_size > 0 && pixel_data_size <= 64 * 1024 * 1024) {
                    pixel_data = malloc(pixel_data_size);
                    if (!pixel_data) {
                        error_report("[HELIX] Failed to allocate %zu bytes for pixel data",
                                     pixel_data_size);
                        break;
                    }
                    if (!read_exact_bytes(fe->vsock_fd, pixel_data, pixel_data_size)) {
                        error_report("[HELIX] Failed to read pixel data (%zu bytes)",
                                     pixel_data_size);
                        free(pixel_data);
                        break;
                    }
                    helix_log("[HELIX] Received %zu bytes of pixel data", pixel_data_size);
                }
            }

            ret = handle_frame_request(fe, &req, pixel_data, pixel_data_size);
            free(pixel_data);

        } else if (header.msg_type == HELIX_MSG_CONFIG_REQ) {
            HelixConfigRequest config_req;
            memcpy(&config_req.header, &header, sizeof(header));
            size_t remaining = sizeof(HelixConfigRequest) - sizeof(HelixMsgHeader);
            if (!read_exact_bytes(fe->vsock_fd,
                                  ((uint8_t *)&config_req) + sizeof(HelixMsgHeader),
                                  remaining)) {
                error_report("[HELIX] Failed to read config request body");
                break;
            }
            ret = handle_config_request(fe, &config_req);

        } else if (header.msg_type == HELIX_MSG_PING) {
            HelixMsgHeader pong = {
                .magic = HELIX_MSG_MAGIC,
                .msg_type = HELIX_MSG_PONG,
                .flags = 0,
                .session_id = header.session_id,
                .payload_size = 0
            };
            send(fe->vsock_fd, &pong, sizeof(pong), 0);
            continue;

        } else if (header.msg_type == HELIX_MSG_ENABLE_SCANOUT) {
            /* Read payload: scanout_id(4) + width(4) + height(4) + refresh(4) */
            uint32_t payload[4];
            if (!read_exact_bytes(fe->vsock_fd, payload, 16)) {
                error_report("[HELIX] Failed to read enable_scanout payload");
                break;
            }

            error_report("[HELIX] ENABLE_SCANOUT: id=%u, %ux%u@%u",
                         payload[0], payload[1], payload[2], payload[3]);

            int result = helix_enable_scanout(fe->virtio_gpu, payload[0],
                                              payload[1], payload[2]);

            /* Send response */
            uint8_t resp_buf[sizeof(HelixMsgHeader) + 72];
            memset(resp_buf, 0, sizeof(resp_buf));
            HelixMsgHeader *resp_hdr = (HelixMsgHeader *)resp_buf;
            resp_hdr->magic = HELIX_MSG_MAGIC;
            resp_hdr->msg_type = HELIX_MSG_SCANOUT_RESP;
            resp_hdr->session_id = header.session_id;
            resp_hdr->payload_size = 72;
            uint32_t *resp_data = (uint32_t *)(resp_buf + sizeof(HelixMsgHeader));
            resp_data[0] = payload[0];  /* scanout_id */
            resp_data[1] = (result == 0) ? 1 : 0;  /* success */
            snprintf((char *)(resp_data + 2), 64, "Virtual-%u", payload[0] + 1);
            send(fe->vsock_fd, resp_buf, sizeof(resp_buf), 0);
            continue;

        } else if (header.msg_type == HELIX_MSG_DISABLE_SCANOUT) {
            uint32_t scanout_id;
            if (!read_exact_bytes(fe->vsock_fd, &scanout_id, 4)) {
                break;
            }
            helix_disable_scanout(fe->virtio_gpu, scanout_id);
            continue;

        } else {
            error_report("[HELIX] Unknown message type: %d", header.msg_type);
            /* Skip any payload */
            if (header.payload_size > 0) {
                uint8_t *skip = malloc(header.payload_size);
                if (skip) {
                    read_exact_bytes(fe->vsock_fd, skip, header.payload_size);
                    free(skip);
                }
            }
            continue;
        }

        int ret_unused = ret; (void)ret_unused;
        if (ret != HELIX_ERR_OK) {
            /* Send error response */
            HelixErrorResponse err = {
                .header = {
                    .magic = HELIX_MSG_MAGIC,
                    .msg_type = HELIX_MSG_ERROR,
                    .flags = 0,
                    .session_id = fe->session_id,
                    .payload_size = sizeof(HelixErrorResponse) - sizeof(HelixMsgHeader)
                },
                .error_code = ret
            };
            snprintf(err.message, sizeof(err.message), "Error: %d", ret);
            send(fe->vsock_fd, &err, sizeof(err), 0);
        }
    }

    return NULL;
}

/* ========================================================================
 * Multi-client / Multi-scanout support
 * ======================================================================== */

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
        ssize_t sent = send(c->fd, response_data, response_size, MSG_NOSIGNAL);
        if (sent < 0) {
            helix_log("[HELIX] Failed to send to client %d (scanout %u): %s",
                      i, scanout_id, strerror(errno));
        }
        pthread_mutex_unlock(&c->send_lock);
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
    int64_t pts = (int64_t)sourceFrameRefCon;

    if (status != noErr || !sampleBuffer) {
        fe->encode_errors++;
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
        return;
    }

    size_t totalLength = 0;
    char *dataPtr = NULL;
    if (CMBlockBufferGetDataPointer(dataBuffer, 0, NULL, &totalLength, &dataPtr) != noErr) {
        free(sps_pps_data);
        return;
    }

    /* Convert avcc to Annex B */
    size_t annexb_size = sps_pps_size + totalLength;
    uint8_t *annexb_data = malloc(annexb_size);
    if (!annexb_data) {
        free(sps_pps_data);
        return;
    }

    size_t src_offset = 0, dst_offset = 0;

    if (sps_pps_data && sps_pps_size > 0) {
        memcpy(annexb_data, sps_pps_data, sps_pps_size);
        dst_offset = sps_pps_size;
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
        return;
    }

    HelixFrameResponse *resp = (HelixFrameResponse *)response;
    resp->header.magic = HELIX_MSG_MAGIC;
    resp->header.msg_type = HELIX_MSG_FRAME_RESPONSE;
    resp->header.flags = 0;
    resp->header.session_id = (uint16_t)scanout_id;
    resp->header.payload_size = response_size - sizeof(HelixMsgHeader);

    CMTime decode_time = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
    resp->pts = pts;
    resp->dts = CMTimeGetSeconds(decode_time) * 1000000000LL;
    resp->is_keyframe = is_keyframe ? 1 : 0;
    resp->nal_count = 1;

    uint32_t nal_size = (uint32_t)dst_offset;
    memcpy(response + sizeof(HelixFrameResponse), &nal_size, sizeof(nal_size));
    memcpy(response + sizeof(HelixFrameResponse) + sizeof(uint32_t),
           annexb_data, dst_offset);
    free(annexb_data);

    /* Also send to legacy single-client if it matches */
    pthread_mutex_lock(&fe->mutex);
    if (fe->vsock_fd >= 0 && fe->session_id == scanout_id) {
        send(fe->vsock_fd, response, response_size, 0);
    }
    pthread_mutex_unlock(&fe->mutex);

    /* Send to all subscribed multi-clients */
    helix_send_to_subscribed_clients(fe, scanout_id, response, response_size);

    fe->frames_encoded++;
    free(response);
}

/* Per-scanout encoder context storage (leaked intentionally - lives for process lifetime) */
static ScanoutEncoderCtx g_scanout_ctx[HELIX_MAX_SCANOUTS];

/*
 * Called from virtio-gpu-virgl.c during SET_SCANOUT_BLOB when virglrenderer
 * provides a Metal texture handle. This is the same point where SPICE captures
 * the Metal texture for display. We store it for zero-copy VideoToolbox encoding.
 */
void helix_set_scanout_metal_texture(uint32_t scanout_id, uintptr_t metal_handle)
{
    HelixFrameExport *fe = g_helix_export;
    if (!fe || !fe->valid || scanout_id >= HELIX_MAX_SCANOUTS) {
        return;
    }

    HelixScanoutEncoder *enc = &fe->scanout_encoders[scanout_id];

    /* Release previous Metal texture reference */
    if (enc->metal_texture) {
        CFRelease((__bridge_transfer id)(enc->metal_texture));
        enc->metal_texture = NULL;
        enc->metal_iosurface = NULL;
    }

    if (metal_handle == 0) {
        return;
    }

    /* Retain the Metal texture and extract its IOSurface */
    id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)metal_handle;
    IOSurfaceRef surface = tex.iosurface;

    if (surface) {
        enc->metal_texture = (__bridge_retained void *)tex;
        enc->metal_iosurface = surface;  /* IOSurface lifetime tied to texture */
        helix_log("[HELIX] Scanout %u: captured Metal texture %p → IOSurface %p (%lux%lu)",
                  scanout_id, (void *)metal_handle, surface,
                  IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
    } else {
        helix_log("[HELIX] Scanout %u: Metal texture %p has NO IOSurface backing",
                  scanout_id, (void *)metal_handle);
    }
}

/*
 * Create per-scanout encoder session
 */
static int create_scanout_encoder(HelixFrameExport *fe, uint32_t scanout_id,
                                    int32_t width, int32_t height,
                                    int32_t bitrate)
{
    if (scanout_id >= HELIX_MAX_SCANOUTS) return -1;

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
    CFDictionarySetValue(sourceAttrs, kCVPixelBufferIOSurfacePropertiesKey,
        CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                           &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks));

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
        return -1;
    }

    /* Configure for low-latency streaming */
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

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

    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Baseline_AutoLevel);

    status = VTCompressionSessionPrepareToEncodeFrames(enc->session);
    if (status != noErr) {
        helix_log("[HELIX] PrepareToEncodeFrames failed for scanout %u: %d",
                  scanout_id, (int)status);
        CFRelease(enc->session);
        enc->session = NULL;
        return -1;
    }

    enc->width = width;
    enc->height = height;
    enc->bitrate = effective_bitrate;
    enc->configured = true;

    helix_log("[HELIX] Created encoder for scanout %u: %dx%d bitrate=%d",
              scanout_id, width, height, effective_bitrate);
    return 0;
}

/* ========================================================================
 * GPU blit: IOSurface-backed GL blit for zero-copy frame encoding
 *
 * Instead of CPU readback (virgl_renderer_transfer_read_iov which copies
 * 59MB/frame at 5K), we:
 * 1. Create an IOSurface
 * 2. Bind it to a GL texture via ANGLE's EGL_IOSURFACE_ANGLE extension
 * 3. glBlitFramebuffer from virglrenderer's tex_id to the IOSurface texture
 * 4. Pass the IOSurface directly to VideoToolbox for H.264 encoding
 *
 * The GL blit is sub-millisecond on Apple Silicon even at 5K.
 * ======================================================================== */

/*
 * Initialize GPU blit subsystem: create a shared EGL context.
 * Must be called when virglrenderer's GL context is current (i.e. right
 * after virgl_renderer_init in virtio_gpu_virgl_init).
 */
static void helix_init_gpu_blit(HelixFrameExport *fe)
{
    fe->gl_blit_available = false;
    fe->helix_egl_ctx = NULL;

    if (!qemu_egl_display) {
        helix_log("[GPU_BLIT] EGL display not available, GPU blit disabled");
        return;
    }

    /* Get the current EGL context (should be virglrenderer's after virgl_renderer_init) */
    EGLContext current = eglGetCurrentContext();
    if (current == EGL_NO_CONTEXT) {
        helix_log("[GPU_BLIT] No current EGL context at init time, GPU blit disabled");
        return;
    }

    /* Create a new EGL context that shares textures with virglrenderer.
     * This lets us see virglrenderer's tex_id textures from our context. */
    bool gles = true;  /* ANGLE on macOS uses GLES */
    const EGLint ctx_att_gles[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    const EGLint ctx_att_core[] = {
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };

    EGLContext helix_ctx = eglCreateContext(
        qemu_egl_display, qemu_egl_config, current,
        gles ? ctx_att_gles : ctx_att_core);

    if (helix_ctx == EGL_NO_CONTEXT) {
        /* Try core profile if GLES failed */
        helix_ctx = eglCreateContext(
            qemu_egl_display, qemu_egl_config, current, ctx_att_core);
    }

    if (helix_ctx == EGL_NO_CONTEXT) {
        helix_log("[GPU_BLIT] Failed to create shared EGL context: %s",
                  eglGetError() == EGL_BAD_MATCH ? "EGL_BAD_MATCH" :
                  eglGetError() == EGL_BAD_CONFIG ? "EGL_BAD_CONFIG" : "unknown");
        return;
    }

    fe->helix_egl_ctx = helix_ctx;
    fe->gl_blit_available = true;

    helix_log("[GPU_BLIT] GPU blit initialized: shared EGL context=%p (share=%p)",
              helix_ctx, current);
    helix_log("[GPU_BLIT] ANGLE native device=%p", qemu_egl_angle_native_device);
}

/*
 * Destroy per-scanout GPU blit resources.
 */
static void helix_destroy_scanout_blit(HelixScanoutEncoder *enc)
{
    if (enc->blit_egl_surface) {
        eglDestroySurface(qemu_egl_display, (EGLSurface)enc->blit_egl_surface);
        enc->blit_egl_surface = NULL;
    }
    /* GL objects (textures, FBOs) are destroyed when the EGL surface is destroyed */
    enc->blit_dst_tex = 0;
    enc->blit_dst_fbo = 0;
    enc->blit_src_fbo = 0;
    if (enc->blit_iosurface) {
        CFRelease(enc->blit_iosurface);
        enc->blit_iosurface = NULL;
    }
    enc->blit_width = 0;
    enc->blit_height = 0;
}

/*
 * Set up per-scanout GPU blit resources: IOSurface + EGL pbuffer + GL FBOs.
 * Returns true on success.
 */
static bool helix_setup_scanout_blit(HelixFrameExport *fe,
                                     HelixScanoutEncoder *enc,
                                     uint32_t scanout_id,
                                     uint32_t width, uint32_t height)
{
    /* Clean up previous resources if size changed */
    if (enc->blit_iosurface) {
        helix_destroy_scanout_blit(enc);
    }

    /* 1. Create IOSurface (BGRA, same format VideoToolbox expects) */
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    int w = (int)width, h = (int)height;
    size_t bpe = 4;
    uint32_t pixfmt = 'BGRA';
    CFNumberRef wNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &w);
    CFNumberRef hNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &h);
    CFNumberRef bpeNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &bpe);
    CFNumberRef pfNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pixfmt);
    CFDictionarySetValue(props, kIOSurfaceWidth, wNum);
    CFDictionarySetValue(props, kIOSurfaceHeight, hNum);
    CFDictionarySetValue(props, kIOSurfaceBytesPerElement, bpeNum);
    CFDictionarySetValue(props, kIOSurfacePixelFormat, pfNum);
#if TARGET_OS_OSX
    CFDictionarySetValue(props, kIOSurfaceIsGlobal, kCFBooleanTrue);
#endif
    CFRelease(wNum);
    CFRelease(hNum);
    CFRelease(bpeNum);
    CFRelease(pfNum);

    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);

    if (!surface) {
        helix_log("[GPU_BLIT] IOSurfaceCreate failed for scanout %u (%ux%u)",
                  scanout_id, width, height);
        return false;
    }

    /* 2. Query ANGLE's texture target for IOSurface binding */
    EGLint target = 0;
    GLenum tex_target = GL_TEXTURE_2D;
    if (eglGetConfigAttrib(qemu_egl_display, qemu_egl_config,
                           EGL_BIND_TO_TEXTURE_TARGET_ANGLE, &target) == EGL_TRUE) {
        if (target == EGL_TEXTURE_RECTANGLE_ANGLE) {
            tex_target = GL_TEXTURE_RECTANGLE;
        }
        /* else default GL_TEXTURE_2D */
    }

    /* 3. Create EGL pbuffer from IOSurface (ANGLE extension) */
    const EGLint pbuf_attrs[] = {
        EGL_WIDTH,                         (EGLint)width,
        EGL_HEIGHT,                        (EGLint)height,
        EGL_IOSURFACE_PLANE_ANGLE,         0,
        EGL_TEXTURE_TARGET,                target ? target : EGL_TEXTURE_2D,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT,                EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE,            GL_UNSIGNED_BYTE,
        EGL_IOSURFACE_USAGE_HINT_ANGLE,    EGL_IOSURFACE_WRITE_HINT_ANGLE,
        EGL_NONE,                          EGL_NONE,
    };

    /* Save current EGL state */
    EGLContext prev_ctx = eglGetCurrentContext();
    EGLSurface prev_draw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface prev_read = eglGetCurrentSurface(EGL_READ);

    /* qemu_egl_init_buffer_surface creates the pbuffer and makes context current */
    EGLSurface pbuf = qemu_egl_init_buffer_surface(
        (EGLContext)fe->helix_egl_ctx,
        EGL_IOSURFACE_ANGLE,
        (EGLClientBuffer)surface,
        pbuf_attrs);

    if (!pbuf) {
        helix_log("[GPU_BLIT] EGL pbuffer creation failed for scanout %u (%ux%u)",
                  scanout_id, width, height);
        /* Restore context */
        eglMakeCurrent(qemu_egl_display, prev_draw, prev_read, prev_ctx);
        CFRelease(surface);
        return false;
    }

    /* 4. Create GL texture and bind to IOSurface via pbuffer.
     * After eglBindTexImage, writes to this texture go to the IOSurface. */
    GLuint dst_tex;
    glGenTextures(1, &dst_tex);
    glBindTexture(tex_target, dst_tex);
    glTexParameteri(tex_target, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(tex_target, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    if (eglBindTexImage(qemu_egl_display, pbuf, EGL_BACK_BUFFER) != EGL_TRUE) {
        helix_log("[GPU_BLIT] eglBindTexImage failed for scanout %u", scanout_id);
        glDeleteTextures(1, &dst_tex);
        eglMakeCurrent(qemu_egl_display, prev_draw, prev_read, prev_ctx);
        qemu_egl_destroy_surface(pbuf);
        CFRelease(surface);
        return false;
    }

    /* 5. Create FBOs: destination (IOSurface-backed) and source (for tex_id) */
    GLuint dst_fbo, src_fbo;
    glGenFramebuffers(1, &dst_fbo);
    glGenFramebuffers(1, &src_fbo);

    /* Attach destination texture to destination FBO */
    glBindFramebuffer(GL_FRAMEBUFFER, dst_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, tex_target, dst_tex, 0);

    GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fbo_status != GL_FRAMEBUFFER_COMPLETE) {
        helix_log("[GPU_BLIT] Dest FBO incomplete (status=0x%x) for scanout %u",
                  fbo_status, scanout_id);
        glDeleteFramebuffers(1, &dst_fbo);
        glDeleteFramebuffers(1, &src_fbo);
        glDeleteTextures(1, &dst_tex);
        eglMakeCurrent(qemu_egl_display, prev_draw, prev_read, prev_ctx);
        qemu_egl_destroy_surface(pbuf);
        CFRelease(surface);
        return false;
    }

    /* Restore previous EGL state */
    eglMakeCurrent(qemu_egl_display, prev_draw, prev_read, prev_ctx);

    /* Store resources */
    enc->blit_iosurface = surface;
    enc->blit_dst_tex = dst_tex;
    enc->blit_dst_fbo = dst_fbo;
    enc->blit_src_fbo = src_fbo;
    enc->blit_egl_surface = (void *)pbuf;
    enc->blit_width = (int32_t)width;
    enc->blit_height = (int32_t)height;

    helix_log("[GPU_BLIT] Setup scanout %u: %ux%u IOSurface=%p tex=%u dst_fbo=%u src_fbo=%u target=0x%x",
              scanout_id, width, height, surface, dst_tex, dst_fbo, src_fbo, tex_target);

    return true;
}

/*
 * Perform GPU blit from virglrenderer's texture to IOSurface.
 * Returns the IOSurface (with incremented use count) on success, NULL on failure.
 */
static IOSurfaceRef helix_gpu_blit_frame(HelixFrameExport *fe,
                                         HelixScanoutEncoder *enc,
                                         uint32_t scanout_id,
                                         uint32_t tex_id,
                                         uint32_t width, uint32_t height)
{
    /* Save current EGL state */
    EGLContext prev_ctx = eglGetCurrentContext();
    EGLSurface prev_draw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface prev_read = eglGetCurrentSurface(EGL_READ);

    /* Make helix context current with the IOSurface pbuffer.
     * This is required for the IOSurface-backed texture to be writable. */
    EGLBoolean ok = eglMakeCurrent(qemu_egl_display,
                                    (EGLSurface)enc->blit_egl_surface,
                                    (EGLSurface)enc->blit_egl_surface,
                                    (EGLContext)fe->helix_egl_ctx);
    if (!ok) {
        helix_log("[GPU_BLIT] eglMakeCurrent failed for scanout %u", scanout_id);
        eglMakeCurrent(qemu_egl_display, prev_draw, prev_read, prev_ctx);
        return NULL;
    }

    /* Attach virglrenderer's texture to source FBO */
    glBindFramebuffer(GL_READ_FRAMEBUFFER, enc->blit_src_fbo);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, tex_id, 0);

    GLenum src_status = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
    if (src_status != GL_FRAMEBUFFER_COMPLETE) {
        static uint64_t src_err_count = 0;
        if (++src_err_count <= 5) {
            helix_log("[GPU_BLIT] Source FBO incomplete (status=0x%x) tex_id=%u scanout=%u",
                      src_status, tex_id, scanout_id);
        }
        eglMakeCurrent(qemu_egl_display, prev_draw, prev_read, prev_ctx);
        return NULL;
    }

    /* Bind destination FBO (IOSurface-backed) */
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, enc->blit_dst_fbo);

    /* GPU blit: copies texture data entirely on GPU.
     * At 5K (5120x2880) this is sub-millisecond vs 59MB CPU readback. */
    glBlitFramebuffer(0, 0, (GLint)width, (GLint)height,
                      0, 0, (GLint)width, (GLint)height,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    /* Ensure blit completes before VideoToolbox reads the IOSurface */
    glFinish();

    /* Restore previous EGL state so virglrenderer isn't disrupted */
    eglMakeCurrent(qemu_egl_display, prev_draw, prev_read, prev_ctx);

    /* Return the IOSurface with incremented use count */
    IOSurfaceIncrementUseCount(enc->blit_iosurface);
    return enc->blit_iosurface;
}

/*
 * Auto-encode a scanout frame on page flip.
 * Called from helix_update_scanout_displaysurface() in virtio-gpu-virgl.c
 * whenever a scanout's DisplaySurface is updated.
 *
 * This function:
 * 1. Checks if any clients are subscribed to this scanout
 * 2. Creates/updates the per-scanout encoder if needed
 * 3. Gets the DisplaySurface pixels as an IOSurface
 * 4. Encodes with VideoToolbox
 * 5. The callback sends H.264 to subscribed clients
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
     * Zero-copy path: get the Metal texture backing the scanout's GPU resource,
     * extract its IOSurface, and pass directly to VideoToolbox.
     *
     * This mirrors how SPICE displays the scanout (via ScanoutTextureNative.handle)
     * but feeds it to H.264 encoding instead of display.
     *
     * Fallback: CPU readback via virgl_renderer_transfer_read_iov into cached IOSurface.
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

    if (width == 0 || height == 0) {
        return;
    }

    /* Try zero-copy: use Metal texture's IOSurface captured at SET_SCANOUT time.
     * This is exactly how SPICE displays the scanout — same texture, same IOSurface. */
    HelixScanoutEncoder *enc_check = &fe->scanout_encoders[scanout_id];
    IOSurfaceRef zero_copy_surface = enc_check->metal_iosurface;

    if (ready_count <= 5) {
        helix_log("[FRAME_READY] scanout %u: tex_id=%u metal_texture=%p metal_iosurface=%p gl_blit=%d",
                  scanout_id, info_ext.base.tex_id, enc_check->metal_texture,
                  zero_copy_surface, fe->gl_blit_available);
    }

    /* Create or update encoder */
    HelixScanoutEncoder *enc = &fe->scanout_encoders[scanout_id];
    if (!enc->configured || enc->width != (int32_t)width || enc->height != (int32_t)height) {
        int32_t prev_bitrate = enc->bitrate;
        if (create_scanout_encoder(fe, scanout_id, width, height, prev_bitrate) != 0) {
            return;
        }
        if (enc->cached_surface) {
            CFRelease(enc->cached_surface);
            enc->cached_surface = NULL;
        }
        if (enc->encode_snapshot) {
            CFRelease(enc->encode_snapshot);
            enc->encode_snapshot = NULL;
        }
    }

    IOSurfaceRef encode_surface = NULL;

    /*
     * Frame capture priority:
     * 1. GPU blit via EGL/ANGLE (sub-ms, zero CPU copy, uses tex_id)
     * 2. Metal IOSurface snapshot (if metal_iosurface available)
     * 3. CPU readback via virgl_renderer_transfer_read_iov (slow, 59MB/frame at 5K)
     */

    /* Path 1: GPU blit — get virglrenderer's GL texture ID and blit to IOSurface */
    uint32_t tex_id = info_ext.base.tex_id;
    if (fe->gl_blit_available && tex_id != 0) {
        /* Ensure per-scanout blit resources exist and match current dimensions */
        if (!enc->blit_iosurface ||
            enc->blit_width != (int32_t)width ||
            enc->blit_height != (int32_t)height) {
            helix_setup_scanout_blit(fe, enc, scanout_id, width, height);
        }

        if (enc->blit_iosurface) {
            encode_surface = helix_gpu_blit_frame(fe, enc, scanout_id,
                                                   tex_id, width, height);
            if (encode_surface) {
                static uint64_t gpu_blit_count = 0;
                gpu_blit_count++;
                if (gpu_blit_count <= 5 || (gpu_blit_count % 500) == 0) {
                    helix_log("[FRAME_READY] GPU blit #%llu: scanout=%u tex_id=%u %ux%u",
                              gpu_blit_count, scanout_id, tex_id, width, height);
                }
            }
        }
    }

    /* Path 2: Metal IOSurface snapshot (existing zero-copy path, rarely reached) */
    if (!encode_surface && zero_copy_surface) {
        /* Create or recreate snapshot surface if dimensions changed */
        if (enc->encode_snapshot) {
            uint32_t snap_w = (uint32_t)IOSurfaceGetWidth(enc->encode_snapshot);
            uint32_t snap_h = (uint32_t)IOSurfaceGetHeight(enc->encode_snapshot);
            if (snap_w != width || snap_h != height) {
                CFRelease(enc->encode_snapshot);
                enc->encode_snapshot = NULL;
            }
        }
        if (!enc->encode_snapshot) {
            size_t row_bytes = width * 4;
            CFMutableDictionaryRef props = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
            CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
            CFNumberRef bytesPerRow = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &row_bytes);
            uint32_t pixelFormat = kCVPixelFormatType_32BGRA;
            CFNumberRef pixelFormatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pixelFormat);
            CFDictionarySetValue(props, kIOSurfaceWidth, widthNum);
            CFDictionarySetValue(props, kIOSurfaceHeight, heightNum);
            CFDictionarySetValue(props, kIOSurfaceBytesPerRow, bytesPerRow);
            CFDictionarySetValue(props, kIOSurfacePixelFormat, pixelFormatNum);
            CFRelease(widthNum);
            CFRelease(heightNum);
            CFRelease(bytesPerRow);
            CFRelease(pixelFormatNum);
            enc->encode_snapshot = IOSurfaceCreate(props);
            CFRelease(props);
            if (!enc->encode_snapshot) {
                return;
            }
            helix_log("[FRAME_READY] Created encode_snapshot IOSurface for scanout %u: %ux%u",
                      scanout_id, width, height);
        }

        IOSurfaceLock(zero_copy_surface, kIOSurfaceLockReadOnly, NULL);
        IOSurfaceLock(enc->encode_snapshot, 0, NULL);

        void *src = IOSurfaceGetBaseAddress(zero_copy_surface);
        void *dst = IOSurfaceGetBaseAddress(enc->encode_snapshot);
        size_t src_stride = IOSurfaceGetBytesPerRow(zero_copy_surface);
        size_t dst_stride = IOSurfaceGetBytesPerRow(enc->encode_snapshot);
        size_t copy_bytes = width * 4;

        if (src_stride == dst_stride && src_stride == copy_bytes) {
            memcpy(dst, src, copy_bytes * height);
        } else {
            for (uint32_t row = 0; row < height; row++) {
                memcpy((uint8_t *)dst + row * dst_stride,
                       (uint8_t *)src + row * src_stride,
                       copy_bytes);
            }
        }

        IOSurfaceUnlock(enc->encode_snapshot, 0, NULL);
        IOSurfaceUnlock(zero_copy_surface, kIOSurfaceLockReadOnly, NULL);

        encode_surface = enc->encode_snapshot;
        IOSurfaceIncrementUseCount(encode_surface);
    }

    /* Path 3: CPU readback (last resort — 59MB/frame at 5K) */
    if (!encode_surface) {
        static uint64_t cpu_fallback_count = 0;
        cpu_fallback_count++;
        if (cpu_fallback_count <= 5 || (cpu_fallback_count % 500) == 0) {
            helix_log("[FRAME_READY] CPU fallback #%llu: scanout=%u res=%u tex_id=%u gl_blit=%d",
                      cpu_fallback_count, scanout_id, res_id, tex_id,
                      fe->gl_blit_available);
        }

        if (!enc->cached_surface) {
            size_t row_bytes = width * 4;
            CFMutableDictionaryRef props = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
            CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
            CFNumberRef bytesPerRow = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &row_bytes);
            uint32_t pixelFormat = kCVPixelFormatType_32BGRA;
            CFNumberRef pixelFormatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pixelFormat);
            CFDictionarySetValue(props, kIOSurfaceWidth, widthNum);
            CFDictionarySetValue(props, kIOSurfaceHeight, heightNum);
            CFDictionarySetValue(props, kIOSurfaceBytesPerRow, bytesPerRow);
            CFDictionarySetValue(props, kIOSurfacePixelFormat, pixelFormatNum);
            CFRelease(widthNum);
            CFRelease(heightNum);
            CFRelease(bytesPerRow);
            CFRelease(pixelFormatNum);
            enc->cached_surface = IOSurfaceCreate(props);
            CFRelease(props);
            if (!enc->cached_surface) {
                return;
            }
            helix_log("[FRAME_READY] CPU fallback: created cached IOSurface for scanout %u: %ux%u",
                      scanout_id, width, height);
        }

        IOSurfaceLock(enc->cached_surface, 0, NULL);
        void *surface_base = IOSurfaceGetBaseAddress(enc->cached_surface);
        size_t row_bytes = width * 4;
        size_t buffer_size = row_bytes * height;

        struct iovec iov = { .iov_base = surface_base, .iov_len = buffer_size };
        struct { uint32_t x, y, z, w, h, d; } box = { 0, 0, 0, width, height, 1 };

        virgl_renderer_force_ctx_0();
        ret = virgl_renderer_transfer_read_iov(
            res_id, 0, 0, (uint32_t)row_bytes, 0,
            (struct virgl_box *)&box, 0, &iov, 1);
        IOSurfaceUnlock(enc->cached_surface, 0, NULL);

        if (ret != 0) {
            return;
        }
        encode_surface = enc->cached_surface;
        IOSurfaceIncrementUseCount(encode_surface);
    }

    /*
     * Create a per-frame CVPixelBuffer with its own IOSurface backing.
     * CRITICAL: We must NOT wrap encode_surface directly because
     * VTCompressionSessionEncodeFrame is asynchronous — VideoToolbox may still
     * be reading from the surface when the next frame's GPU blit/memcpy
     * overwrites it. Instead, copy into a fresh CVPixelBuffer that VT owns
     * exclusively. On Apple Silicon unified memory, this memcpy is sub-ms
     * even at 5K (59MB @ 100+ GB/s bandwidth).
     */
    NSDictionary *pbAttrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cvRet = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)pbAttrs, &pixelBuffer);

    if (cvRet == kCVReturnSuccess && pixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        IOSurfaceLock(encode_surface, kIOSurfaceLockReadOnly, NULL);

        void *src = IOSurfaceGetBaseAddress(encode_surface);
        void *dst = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t src_stride = IOSurfaceGetBytesPerRow(encode_surface);
        size_t dst_stride = CVPixelBufferGetBytesPerRow(pixelBuffer);

        if (src_stride == dst_stride) {
            memcpy(dst, src, dst_stride * height);
        } else {
            size_t copy_bytes = (size_t)width * 4;
            for (uint32_t row = 0; row < height; row++) {
                memcpy((uint8_t *)dst + row * dst_stride,
                       (uint8_t *)src + row * src_stride,
                       copy_bytes);
            }
        }

        IOSurfaceUnlock(encode_surface, kIOSurfaceLockReadOnly, NULL);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    }

    IOSurfaceDecrementUseCount(encode_surface);

    if (cvRet != kCVReturnSuccess || !pixelBuffer) {
        return;
    }

    /* Generate monotonic PTS */
    enc->frame_count++;
    int64_t pts = enc->frame_count * 16666667;  /* ~60fps in nanoseconds */
    CMTime cmPts = CMTimeMake(pts, 1000000000);
    CMTime cmDuration = CMTimeMake(16666667, 1000000000);

    /* Force keyframe on first frame */
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

    /* Encode */
    OSStatus encStatus = VTCompressionSessionEncodeFrame(
        enc->session, pixelBuffer, cmPts, cmDuration,
        frameProps, (void *)pts, NULL);

    if (enc->frame_count <= 5 || (enc->frame_count % 100) == 0) {
        helix_log("[ENCODE] scanout=%u frame=%lld status=%d %ux%u",
                  scanout_id, enc->frame_count, (int)encStatus, width, height);
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
            send(client_fd, resp_buf, sizeof(resp_buf), 0);
            pthread_mutex_unlock(&fe->clients[client_idx].send_lock);

        } else if (header.msg_type == HELIX_MSG_ENABLE_SCANOUT) {
            uint32_t payload[4];
            if (!read_exact_bytes(client_fd, payload, 16)) break;

            int result = helix_enable_scanout(fe->virtio_gpu, payload[0],
                                              payload[1], payload[2]);

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
            send(client_fd, resp_buf, sizeof(resp_buf), 0);
            pthread_mutex_unlock(&fe->clients[client_idx].send_lock);

        } else if (header.msg_type == HELIX_MSG_DISABLE_SCANOUT) {
            uint32_t scanout_id;
            if (!read_exact_bytes(client_fd, &scanout_id, 4)) break;
            helix_disable_scanout(fe->virtio_gpu, scanout_id);

        } else if (header.msg_type == HELIX_MSG_PING) {
            HelixMsgHeader pong = {
                .magic = HELIX_MSG_MAGIC,
                .msg_type = HELIX_MSG_PONG,
                .session_id = header.session_id,
                .payload_size = 0
            };
            pthread_mutex_lock(&fe->clients[client_idx].send_lock);
            send(client_fd, &pong, sizeof(pong), 0);
            pthread_mutex_unlock(&fe->clients[client_idx].send_lock);

        } else if (header.msg_type == HELIX_MSG_FRAME_REQUEST) {
            /* Legacy: handle frame request from this client */
            HelixFrameRequest req;
            memcpy(&req.header, &header, sizeof(header));
            size_t remaining = sizeof(HelixFrameRequest) - sizeof(HelixMsgHeader);
            if (!read_exact_bytes(client_fd, ((uint8_t *)&req) + sizeof(HelixMsgHeader),
                                  remaining)) break;

            uint8_t *pixel_data = NULL;
            size_t pixel_data_size = 0;
            if (header.flags & HELIX_FLAG_PIXEL_DATA) {
                pixel_data_size = header.payload_size - remaining;
                if (pixel_data_size > 0 && pixel_data_size <= 64 * 1024 * 1024) {
                    pixel_data = malloc(pixel_data_size);
                    if (pixel_data && !read_exact_bytes(client_fd, pixel_data, pixel_data_size)) {
                        free(pixel_data);
                        break;
                    }
                }
            }

            /* For legacy frame requests, set vsock_fd to this client temporarily */
            pthread_mutex_lock(&fe->mutex);
            int old_fd = fe->vsock_fd;
            fe->vsock_fd = client_fd;
            pthread_mutex_unlock(&fe->mutex);

            handle_frame_request(fe, &req, pixel_data, pixel_data_size);
            free(pixel_data);

            pthread_mutex_lock(&fe->mutex);
            fe->vsock_fd = old_fd;
            pthread_mutex_unlock(&fe->mutex);

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

        struct timeval tv = { .tv_sec = 600, .tv_usec = 0 };
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        int client_idx = helix_add_client(fe, client_fd);
        if (client_idx < 0) {
            helix_log("[HELIX] No client slots available, rejecting");
            close(client_fd);
            continue;
        }

        /* Also set legacy vsock_fd for backward compat (first client) */
        pthread_mutex_lock(&fe->mutex);
        if (fe->vsock_fd < 0 || fe->vsock_fd == fe->listen_fd) {
            fe->vsock_fd = client_fd;
        }
        pthread_mutex_unlock(&fe->mutex);

        ClientThreadArg *cta = malloc(sizeof(ClientThreadArg));
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
 * Initialize frame export subsystem
 * This would be called from virtio_gpu_virgl_init() in QEMU
 */
int helix_frame_export_init(void *virtio_gpu, int vsock_port)
{
    helix_log("========================================");
    helix_log("[HELIX] VERSION: 2026-02-08-v7-gpu-blit");
    helix_log("[HELIX] BUILD: Multi-client, per-scanout auto-encode");
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
    fe->vsock_fd = -1;
    fe->listen_fd = -1;
    fe->session_id = 1;

    /* Initialize client slots */
    for (int i = 0; i < HELIX_MAX_CLIENTS; i++) {
        fe->clients[i].active = false;
        fe->clients[i].fd = -1;
    }

    /* Initialize scanout encoder slots */
    for (int i = 0; i < HELIX_MAX_SCANOUTS; i++) {
        fe->scanout_encoders[i].session = NULL;
        fe->scanout_encoders[i].configured = false;
        fe->scanout_encoders[i].cached_surface = NULL;
        fe->scanout_encoders[i].encode_snapshot = NULL;
        fe->scanout_encoders[i].metal_texture = NULL;
        fe->scanout_encoders[i].metal_iosurface = NULL;
        fe->scanout_encoders[i].blit_iosurface = NULL;
        fe->scanout_encoders[i].blit_dst_tex = 0;
        fe->scanout_encoders[i].blit_dst_fbo = 0;
        fe->scanout_encoders[i].blit_src_fbo = 0;
        fe->scanout_encoders[i].blit_egl_surface = NULL;
        fe->scanout_encoders[i].blit_width = 0;
        fe->scanout_encoders[i].blit_height = 0;
    }

    /* Set global singleton */
    g_helix_export = fe;

    /* Initialize GPU blit subsystem (must happen while virglrenderer's
     * GL context is current — we're called right after virgl_renderer_init) */
    helix_init_gpu_blit(fe);

    /* Set up TCP socket listener */
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

    return 0;
}

#endif /* __APPLE__ */
