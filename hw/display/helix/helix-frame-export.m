/*
 * Helix Frame Export for QEMU/UTM
 *
 * Zero-copy video encoding: virtio-gpu resource -> Metal texture ->
 * IOSurface -> VideoToolbox H.264 -> vsock back to guest
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "helix-frame-export.h"

#ifdef __APPLE__

#include <dispatch/dispatch.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <Metal/Metal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdarg.h>

/* virglrenderer includes */
#include "virglrenderer.h"

/* Forward declarations */
extern uint32_t virtio_gpu_get_scanout_resource_id(void *virtio_gpu, uint32_t scanout_idx);

/* virglrenderer function that may not be in header (unstable API) */
extern enum virgl_renderer_native_handle_type
virgl_renderer_create_handle_for_scanout(uint32_t res_id,
                                         uint32_t width,
                                         uint32_t height,
                                         uint32_t virgl_format,
                                         uint32_t padding,
                                         uint32_t stride,
                                         uint32_t offset,
                                         virgl_renderer_native_handle *handle);

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
    int64_t pts = (int64_t)sourceFrameRefCon;

    if (status != noErr) {
        error_report("VideoToolbox encode failed: %d\n", (int)status);
        fe->encode_errors++;
        return;
    }

    if (!sampleBuffer) {
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

    /* Get the data buffer */
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) {
        error_report("No data buffer in sample\n");
        return;
    }

    size_t totalLength = 0;
    char *dataPtr = NULL;
    OSStatus err = CMBlockBufferGetDataPointer(dataBuffer, 0, NULL,
                                                &totalLength, &dataPtr);
    if (err != noErr || !dataPtr) {
        error_report("Failed to get data pointer: %d\n", (int)err);
        return;
    }

    /* Build response message */
    size_t response_size = sizeof(HelixFrameResponse) + sizeof(uint32_t) + totalLength;
    uint8_t *response = malloc(response_size);
    if (!response) {
        error_report("Failed to allocate response buffer\n");
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
    resp->nal_count = 1;  /* Single NAL unit for now */

    /* Write NAL size and data */
    uint32_t nal_size = (uint32_t)totalLength;
    memcpy(response + sizeof(HelixFrameResponse), &nal_size, sizeof(nal_size));
    memcpy(response + sizeof(HelixFrameResponse) + sizeof(uint32_t),
           dataPtr, totalLength);

    /* Send response over vsock */
    ssize_t sent = send(fe->vsock_fd, response, response_size, 0);
    if (sent < 0) {
        error_report("Failed to send response: %s\n", strerror(errno));
    } else {
        fe->frames_encoded++;
        fe->bytes_sent += sent;
    }

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

    /* H.264 Main Profile, Level 4.1 (suitable for 1080p60) */
    VTSessionSetProperty(fe->encoder_session,
                         kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Main_AutoLevel);

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
 * Look up IOSurface for a virtio-gpu resource (zero-copy)
 *
 * The MTLTexture MUST be backed by IOSurface. If not, this fails
 * and we need to modify virglrenderer to create IOSurface-backed textures.
 */
IOSurfaceRef helix_get_iosurface_for_resource(void *virtio_gpu,
                                               uint32_t resource_id)
{
    struct virgl_renderer_resource_info_ext info_ext = {0};
    enum virgl_renderer_native_handle_type type;
    virgl_renderer_native_handle handle;

    error_report("[HELIX] Looking up resource_id=%u", resource_id);

    int ret = virgl_renderer_resource_get_info_ext(resource_id, &info_ext);
    if (ret != 0) {
        error_report("[HELIX] virgl_renderer_resource_get_info_ext failed: ret=%d", ret);
        return NULL;
    }

    error_report("[HELIX] Resource %u: native_type=%d, width=%u, height=%u, depth=%u",
                 resource_id, info_ext.native_type,
                 info_ext.base.width, info_ext.base.height, info_ext.base.depth);

    /*
     * If resource doesn't have Metal texture backing, try to create it.
     * This is what virgl_cmd_set_scanout_blob does - call create_handle_for_scanout
     * to convert a regular resource into a Metal texture.
     */
    if (info_ext.native_type != VIRGL_NATIVE_HANDLE_METAL_TEXTURE) {
        error_report("[HELIX] Resource %u doesn't have Metal texture, creating one...", resource_id);

        type = virgl_renderer_create_handle_for_scanout(
            resource_id,
            info_ext.base.width,
            info_ext.base.height,
            info_ext.base.virgl_format,
            0,  /* padding */
            info_ext.base.stride,
            0,  /* offset */
            &handle);

        if (type != VIRGL_NATIVE_HANDLE_METAL_TEXTURE) {
            error_report("[HELIX] create_handle_for_scanout failed: type=%d (expected %d)",
                         type, VIRGL_NATIVE_HANDLE_METAL_TEXTURE);
            return NULL;
        }

        error_report("[HELIX] Successfully created Metal texture for resource %u", resource_id);

        /* Update info_ext with the new handle */
        info_ext.native_type = type;
        info_ext.native_handle = handle;
    }

    /* native_handle is MTLTexture* */
    id<MTLTexture> texture = (__bridge id<MTLTexture>)(void *)info_ext.native_handle;
    if (!texture) {
        error_report("[HELIX] Resource %u has NULL Metal texture", resource_id);
        return NULL;
    }

    error_report("[HELIX] Got Metal texture %p for resource %u", texture, resource_id);

    /* Get IOSurface - texture MUST be backed by IOSurface for zero-copy */
    IOSurfaceRef surface = texture.iosurface;
    if (!surface) {
        error_report("[HELIX] Metal texture has no IOSurface backing - "
                     "virglrenderer must create IOSurface-backed textures");
        return NULL;
    }

    error_report("[HELIX] Got IOSurface %p (width=%zu, height=%zu)",
                 surface, IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));

    IOSurfaceIncrementUseCount(surface);
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
 * Handle frame request from guest
 */
static int handle_frame_request(HelixFrameExport *fe,
                                 const HelixFrameRequest *req)
{
    error_report("[HELIX] Frame request: resource_id=%u, %ux%u, pts=%lld",
                 req->resource_id, req->width, req->height, req->pts);

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

    /*
     * IMPORTANT: Regular virtio-gpu resources don't have Metal texture backing.
     * Only scanout resources (those being displayed) get Metal textures via
     * virgl_renderer_create_handle_for_scanout().
     *
     * If resource_id is 0, use the current scanout resource.
     */
    uint32_t resource_id = req->resource_id;
    if (resource_id == 0) {
        resource_id = helix_get_scanout_resource(fe->virtio_gpu);
        error_report("[HELIX] Using scanout resource_id=%u", resource_id);

        if (resource_id == 0) {
            error_report("[HELIX] No scanout resource set");
            return HELIX_ERR_RESOURCE_NOT_FOUND;
        }
    }

    /* Look up IOSurface for this resource */
    IOSurfaceRef surface = helix_get_iosurface_for_resource(
        fe->virtio_gpu, resource_id);

    if (!surface) {
        error_report("[HELIX] Failed to get IOSurface for resource %u", req->resource_id);
        error_report("[HELIX] NOTE: Only scanout resources have Metal texture backing");
        return HELIX_ERR_RESOURCE_NOT_FOUND;
    }

    /* Encode the frame */
    int ret = helix_encode_iosurface(fe, surface, req->pts, req->duration,
                                      req->force_keyframe != 0);

    IOSurfaceDecrementUseCount(surface);

    if (ret == HELIX_ERR_OK) {
        error_report("[HELIX] Frame encoded successfully");
    } else {
        error_report("[HELIX] Frame encoding failed: %d", ret);
    }

    return ret;
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
        return handle_frame_request(fe, (const HelixFrameRequest *)data);

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

    if (fe->encoder_session) {
        VTCompressionSessionCompleteFrames(fe->encoder_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(fe->encoder_session);
        CFRelease(fe->encoder_session);
    }

    if (fe->vsock_fd >= 0) {
        close(fe->vsock_fd);
    }

    free(fe);
}

/*
 * Forward declaration
 */
static void *vsock_accept_thread(void *arg);

/*
 * vsock server thread - listens for connections and processes messages
 */
static void *vsock_server_thread(void *arg)
{
    HelixFrameExport *fe = (HelixFrameExport *)arg;
    uint8_t buffer[65536];

    while (1) {
        ssize_t received = recv(fe->vsock_fd, buffer, sizeof(buffer), 0);
        if (received <= 0) {
            if (received < 0 && errno != EINTR) {
                error_report("vsock recv error: %s\n", strerror(errno));
            }
            break;
        }

        int ret = helix_frame_export_process_msg(fe, buffer, received);
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

/*
 * Initialize frame export subsystem
 * This would be called from virtio_gpu_virgl_init() in QEMU
 */
int helix_frame_export_init(void *virtio_gpu, int vsock_port)
{
    error_report("[HELIX] Initializing frame export on vsock port %d", vsock_port);

    HelixFrameExport *fe = calloc(1, sizeof(HelixFrameExport));
    if (!fe) {
        error_report("[HELIX-DEBUG] Failed to allocate HelixFrameExport");
        return -1;
    }

    fe->virtio_gpu = virtio_gpu;
    fe->vsock_fd = -1;
    fe->session_id = 1;  /* Default session */

    /*
     * Set up UNIX socket listener for helix frame export protocol
     *
     * macOS doesn't have kernel vsock support, so we use UNIX socket + TCP proxy:
     * - Socket created in QEMU's CWD (macOS sandbox blocks /tmp)
     * - socat proxies TCP port 5900 to this socket
     * - Guest connects to 10.0.2.2:5900 via QEMU user-mode networking
     *
     * For production, this should be replaced with virtserialport
     */
    const char *socket_path = "helix-frame-export.sock";

    /* Remove existing socket if present */
    unlink(socket_path);

    /* Create UNIX domain socket */
    int listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        error_report("Failed to create UNIX socket: %s\n", strerror(errno));
        free(fe);
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        error_report("Failed to bind UNIX socket: %s\n", strerror(errno));
        close(listen_fd);
        free(fe);
        return -1;
    }

    if (listen(listen_fd, 1) < 0) {
        error_report("Failed to listen on UNIX socket: %s\n", strerror(errno));
        close(listen_fd);
        unlink(socket_path);
        free(fe);
        return -1;
    }

    error_report("[HELIX] Frame export ready: socket=%s, proxy=10.0.2.2:%d\n",
                 socket_path, vsock_port);

    /* Accept connections in background thread */
    pthread_t thread;
    fe->vsock_fd = listen_fd;  /* Store listen fd temporarily */
    if (pthread_create(&thread, NULL, vsock_accept_thread, fe) != 0) {
        error_report("Failed to create accept thread: %s\n", strerror(errno));
        close(listen_fd);
        unlink(socket_path);
        free(fe);
        return -1;
    }

    pthread_detach(thread);

    /* Store in virtio-gpu device for later access */
    /* TODO: Add helix_frame_export field to VirtIOGPU struct */

    return 0;
}

/*
 * Accept thread - waits for guest connections
 */
static void *vsock_accept_thread(void *arg)
{
    HelixFrameExport *fe = (HelixFrameExport *)arg;
    int listen_fd = fe->vsock_fd;

    while (1) {
        error_report("[HELIX] Waiting for guest connection...");

        int client_fd = accept(listen_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            error_report("[HELIX] Accept failed: %s", strerror(errno));
            break;
        }

        error_report("[HELIX] Guest connected!");

        /* Update vsock_fd to client connection */
        fe->vsock_fd = client_fd;

        /* Handle this client connection */
        vsock_server_thread(fe);

        /* Client disconnected */
        error_report("[HELIX] Guest disconnected");
        close(client_fd);
        fe->vsock_fd = listen_fd;  /* Back to listening */
    }

    return NULL;
}

#endif /* __APPLE__ */
