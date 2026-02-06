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

    /* VideoToolbox outputs H.264 in avcc format (4-byte length prefixes).
     * Convert to Annex B (start codes 0x00000001) for vsockenc. */
    size_t annexb_size = totalLength; /* Start codes are same size as length prefixes */
    uint8_t *annexb_data = malloc(annexb_size);
    if (!annexb_data) {
        error_report("Failed to allocate annexb buffer\n");
        pthread_mutex_unlock(&fe->mutex);
        return;
    }

    helix_log("[HELIX] Converting avcc to Annex B: input_size=%zu", totalLength);
    size_t src_offset = 0;
    size_t dst_offset = 0;
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
 * Handle frame request from guest
 */
static int handle_frame_request(HelixFrameExport *fe,
                                 const HelixFrameRequest *req)
{
    helix_log("[HELIX] Frame request RAW: resource_id=%u, width=%u (0x%x), height=%u (0x%x), pts=%lld",
             req->resource_id, req->width, req->width, req->height, req->height, req->pts);

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
     * NEW APPROACH: Read from DisplaySurface instead of GPU resource
     *
     * This eliminates the race condition where the guest compositor can free
     * GPU resources while we're reading them. DisplaySurface is QEMU-managed
     * CPU memory that's updated during SET_SCANOUT and damage notifications.
     *
     * The old approach (helix_get_iosurface_for_resource) would crash when the
     * compositor freed scanout resources during workspace switches or screen
     * changes. The new approach (helix_get_iosurface_from_scanout) reads from
     * a stable DisplaySurface copy, just like SPICE does.
     */
    helix_log("[HELIX] ═══════════════════════════════════════════════════════");
    helix_log("[HELIX] Reading from scanout DisplaySurface (safe, no race condition)");
    helix_log("[HELIX] Frame parameters: %ux%u, pts=%lld", req->width, req->height, req->pts);

    IOSurfaceRef surface = helix_get_iosurface_from_scanout(
        fe->virtio_gpu, 0  /* scanout_id - always 0 for single display */);

    if (!surface) {
        error_report("[HELIX] ❌ FAILED to get IOSurface from DisplaySurface");
        error_report("[HELIX] DisplaySurface may not be initialized yet (no scanout set)");
        return HELIX_ERR_RESOURCE_NOT_FOUND;
    }

    helix_log("[HELIX] ✅ IOSurface extraction from DisplaySurface successful, proceeding to encode");

    /* Encode the frame */
    int ret = helix_encode_iosurface(fe, surface, req->pts, req->duration,
                                      req->force_keyframe != 0);

    IOSurfaceDecrementUseCount(surface);

    if (ret == HELIX_ERR_OK) {
        helix_log("[HELIX] Frame encode request submitted (async callback will send response)");
    } else {
        error_report("[HELIX] Frame encoding failed: %d", ret);
    }

    /* Don't return a response here - the VideoToolbox callback will send it asynchronously */
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
    error_report("========================================");
    error_report("[HELIX] VERSION: 2026-02-06-v4-TCP-direct");
    error_report("[HELIX] BUILD: TCP listener, no socat needed");
    error_report("========================================");
    error_report("[HELIX] Initializing frame export on vsock port %d", vsock_port);

    HelixFrameExport *fe = calloc(1, sizeof(HelixFrameExport));
    if (!fe) {
        error_report("[HELIX-DEBUG] Failed to allocate HelixFrameExport");
        return -1;
    }

    /* Initialize thread safety */
    pthread_mutex_init(&fe->mutex, NULL);
    fe->valid = true;

    fe->virtio_gpu = virtio_gpu;
    fe->vsock_fd = -1;
    fe->session_id = 1;  /* Default session */

    /*
     * Set up TCP socket listener for helix frame export protocol
     *
     * Guest connects to 10.0.2.2:<port> via QEMU user-mode networking.
     * SLiRP forwards this to 127.0.0.1:<port> on the host, which is
     * where we listen. No socat proxy needed.
     */
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        error_report("Failed to create TCP socket: %s\n", strerror(errno));
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
        error_report("Failed to bind TCP socket on port %d: %s\n",
                     vsock_port, strerror(errno));
        close(listen_fd);
        free(fe);
        return -1;
    }

    if (listen(listen_fd, 1) < 0) {
        error_report("Failed to listen on TCP socket: %s\n", strerror(errno));
        close(listen_fd);
        free(fe);
        return -1;
    }

    error_report("[HELIX] Frame export ready: TCP 127.0.0.1:%d (guest: 10.0.2.2:%d)\n",
                 vsock_port, vsock_port);

    /* Accept connections in background thread */
    pthread_t thread;
    fe->vsock_fd = listen_fd;  /* Store listen fd temporarily */
    if (pthread_create(&thread, NULL, vsock_accept_thread, fe) != 0) {
        error_report("Failed to create accept thread: %s\n", strerror(errno));
        close(listen_fd);
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
        helix_log("[HELIX] Guest disconnected");

        /* Close socket - callbacks will check vsock_fd < 0 before sending */
        close(client_fd);
        fe->vsock_fd = -1;

        /*
         * DO NOT destroy encoder session here - VideoToolbox callbacks are async
         * and may still fire. The callbacks check if vsock_fd < 0 and discard frames.
         * The encoder session will be reused for the next client or destroyed on shutdown.
         */

        /* Sleep briefly to ensure any pending callbacks finish */
        usleep(50000);  /* 50ms */

        /* Back to listening */
        fe->vsock_fd = listen_fd;
    }

    return NULL;
}

#endif /* __APPLE__ */
