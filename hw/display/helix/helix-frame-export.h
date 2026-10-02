/*
 * Helix Frame Export for QEMU/UTM
 *
 * This module provides zero-copy video encoding by:
 * 1. Listening for frame requests from guest via vsock
 * 2. Looking up virtio-gpu resources via virglrenderer
 * 3. Encoding with VideoToolbox using the native Metal texture
 * 4. Sending H.264 NAL units back to guest
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HELIX_FRAME_EXPORT_H
#define HELIX_FRAME_EXPORT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <VideoToolbox/VideoToolbox.h>
#include <IOSurface/IOSurface.h>
#endif

/* vsock port for frame export (well-known port) */
#define HELIX_VSOCK_PORT 5000

/* Message types (guest <-> host) */
#define HELIX_MSG_FRAME_REQUEST   0x01  /* Guest -> Host: encode this resource */
#define HELIX_MSG_FRAME_RESPONSE  0x02  /* Host -> Guest: encoded NAL data */
#define HELIX_MSG_KEYFRAME_REQ    0x03  /* Guest -> Host: force keyframe */
#define HELIX_MSG_CONFIG_REQ      0x04  /* Guest -> Host: configure encoder */
#define HELIX_MSG_CONFIG_RESP     0x05  /* Host -> Guest: encoder config ack */
#define HELIX_MSG_PING            0x10  /* Keepalive */
#define HELIX_MSG_PONG            0x11  /* Keepalive response */
#define HELIX_MSG_ENABLE_SCANOUT  0x20  /* Guest -> Host: connect DRM connector */
#define HELIX_MSG_DISABLE_SCANOUT 0x21  /* Guest -> Host: disconnect DRM connector */
#define HELIX_MSG_SCANOUT_RESP    0x22  /* Host -> Guest: scanout enable/disable result */
#define HELIX_MSG_SUBSCRIBE       0x30  /* Client -> Host: subscribe to scanout stream */
#define HELIX_MSG_SUBSCRIBE_RESP  0x31  /* Host -> Client: subscription confirmed */
#define HELIX_MSG_ERROR           0xFF  /* Error response */

/* Frame request flags */
#define HELIX_FLAG_PIXEL_DATA     0x01  /* Raw pixel data follows the frame request */

/* Pixel formats (matching DRM/GBM formats) */
#define HELIX_FORMAT_BGRA8888     0x34325241  /* DRM_FORMAT_ARGB8888 */
#define HELIX_FORMAT_RGBA8888     0x34324241  /* DRM_FORMAT_ABGR8888 */
#define HELIX_FORMAT_NV12         0x3231564E  /* DRM_FORMAT_NV12 */
#define HELIX_FORMAT_UNKNOWN      0x00000000

/* Message header (common to all messages) */
typedef struct HelixMsgHeader {
    uint32_t magic;         /* 'HXFR' = 0x52465848 */
    uint8_t  msg_type;
    uint8_t  flags;
    uint16_t session_id;    /* For multiplexing multiple streams */
    uint32_t payload_size;
} __attribute__((packed)) HelixMsgHeader;

#define HELIX_MSG_MAGIC 0x52465848  /* 'HXFR' in little-endian */

/* Frame request: guest asks host to encode a virtio-gpu resource */
typedef struct HelixFrameRequest {
    HelixMsgHeader header;
    uint32_t resource_id;   /* virtio-gpu resource ID */
    uint32_t width;
    uint32_t height;
    uint32_t format;        /* HELIX_FORMAT_* */
    uint32_t stride;        /* Bytes per row */
    int64_t  pts;           /* Presentation timestamp (nanoseconds) */
    int64_t  duration;      /* Frame duration (nanoseconds) */
    uint8_t  force_keyframe;
    uint8_t  reserved[7];
} __attribute__((packed)) HelixFrameRequest;

/* Frame response: host returns encoded H.264 data */
typedef struct HelixFrameResponse {
    HelixMsgHeader header;
    int64_t  pts;           /* Same as request */
    int64_t  dts;           /* Decode timestamp */
    uint8_t  is_keyframe;
    uint8_t  reserved[3];
    uint32_t nal_count;     /* Number of NAL units */
    /* Followed by: nal_count x (uint32_t size + NAL data) */
} __attribute__((packed)) HelixFrameResponse;

/* Encoder configuration request */
typedef struct HelixConfigRequest {
    HelixMsgHeader header;
    uint32_t width;
    uint32_t height;
    uint32_t bitrate;       /* Target bitrate in bits/sec */
    uint32_t framerate_num; /* Framerate numerator */
    uint32_t framerate_den; /* Framerate denominator */
    uint8_t  profile;       /* H.264 profile (66=baseline, 77=main, 100=high) */
    uint8_t  level;         /* H.264 level * 10 (e.g., 40 = level 4.0) */
    uint8_t  realtime;      /* 1 = optimize for low latency */
    uint8_t  reserved[5];
} __attribute__((packed)) HelixConfigRequest;

/* Error response */
typedef struct HelixErrorResponse {
    HelixMsgHeader header;
    int32_t  error_code;
    char     message[256];
} __attribute__((packed)) HelixErrorResponse;

/* Error codes */
#define HELIX_ERR_OK              0
#define HELIX_ERR_INVALID_MSG    -1
#define HELIX_ERR_RESOURCE_NOT_FOUND -2
#define HELIX_ERR_NOT_METAL_TEXTURE  -3
#define HELIX_ERR_NO_IOSURFACE       -4
#define HELIX_ERR_ENCODE_FAILED      -5
#define HELIX_ERR_NOT_CONFIGURED     -6
#define HELIX_ERR_INTERNAL           -99

#ifdef __APPLE__

#define HELIX_MAX_CLIENTS  16
#define HELIX_MAX_SCANOUTS 16
#define HELIX_BLIT_RING_SIZE 3  /* Triple-buffer for async VT encode */

/* Keepalive interval: re-encode the last raw frame when the screen is static.
 * 500ms = 2 FPS minimum on idle screens. This produces properly encoded H.264
 * (not re-sent P-frames which corrupt the decoder). */
#define HELIX_KEEPALIVE_INTERVAL_MS 500

/*
 * Per-client connection state
 */
typedef struct HelixClient {
    int fd;
    uint32_t subscribed_scanout;  /* which scanout this client receives */
    bool active;
    bool subscribed;              /* has sent SUBSCRIBE message */
    pthread_mutex_t send_lock;    /* protects send() on this fd */
} HelixClient;

/*
 * Per-scanout encoder state
 */
typedef struct HelixScanoutEncoder {
    VTCompressionSessionRef session;
    int32_t width;
    int32_t height;
    int32_t bitrate;        /* Target bitrate in bps (0 = auto-scale from resolution) */
    bool configured;
    uint64_t frame_count;

    /* Zero-copy GL blit ring buffer for frame capture.
     * Triple-buffered: GL blit writes to slot N while VideoToolbox
     * hardware-encodes slots N-1 and N-2 asynchronously.
     *
     * Flow (zero CPU copies):
     *   virgl tex_id → [GL blit] → IOSurface[N] → [CVPixelBufferCreateWithIOSurface]
     *   → CVPixelBuffer → [VTCompressionSessionEncodeFrame] → H.264
     *
     * Each IOSurface is pre-bound to a GL FBO via ANGLE's EGL_IOSURFACE_ANGLE. */
    IOSurfaceRef blit_surfaces[HELIX_BLIT_RING_SIZE];
    void *blit_egl_surfaces[HELIX_BLIT_RING_SIZE];   /* EGLSurface[] */
    uint32_t blit_textures[HELIX_BLIT_RING_SIZE];     /* GL texture per slot */
    uint32_t blit_fbos[HELIX_BLIT_RING_SIZE];         /* GL FBO per slot (write) */
    uint32_t blit_src_fbo;       /* Shared FBO for reading virgl texture */
    uint32_t blit_ring_idx;      /* Next ring slot to write */
    volatile bool blit_slot_busy[HELIX_BLIT_RING_SIZE]; /* VT encoding in progress */
    volatile bool vt_busy;       /* VT has a frame in flight (prevents EncodeFrame from blocking main loop) */
    int32_t blit_width;
    int32_t blit_height;

    /* Frame keepalive: re-encode the last IOSurface when the screen is static.
     * When no page flips arrive for keepalive_interval_ns, the last blitted
     * IOSurface is re-submitted to VideoToolbox. This produces a valid H.264
     * frame with proper frame_num and reference list, unlike re-sending an
     * already-encoded P-frame which corrupts the decoder's DPB. */
    uint32_t last_blit_slot;         /* Ring slot of last successful blit */
    bool has_blitted_frame;          /* True after first successful encode */
    volatile uint64_t last_frame_ns; /* CLOCK_MONOTONIC nanoseconds of last encode */

} HelixScanoutEncoder;

/*
 * Frame export context - singleton, manages all scanouts and clients
 */
typedef struct HelixFrameExport {
    /* Thread safety */
    pthread_mutex_t mutex;
    bool valid;

    /* Multi-scanout encoders */
    HelixScanoutEncoder scanout_encoders[HELIX_MAX_SCANOUTS];

    /* Multi-client connections */
    HelixClient clients[HELIX_MAX_CLIENTS];
    pthread_mutex_t clients_lock;

    /* Statistics */
    uint64_t frames_encoded;
    uint64_t bytes_sent;
    uint64_t encode_errors;

    /* Reference to virtio-gpu for resource lookup */
    void *virtio_gpu;

    /* TCP listener fd */
    int listen_fd;

    /* EGL context for GL blit operations (shares texture namespace with
     * virglrenderer via spice_gl_ctx share group) */
    void *helix_egl_ctx;            /* EGLContext */

} HelixFrameExport;

/*
 * Initialize frame export subsystem
 * Called from virtio_gpu_virgl_init()
 */
int helix_frame_export_init(void *virtio_gpu, int vsock_port);

/*
 * Cleanup frame export
 */
void helix_frame_export_cleanup(HelixFrameExport *fe);

/*
 * Auto-encode a scanout frame on page flip (damage-based).
 * Called from helix_update_scanout_displaysurface() in virtio-gpu-virgl.c.
 * Encodes the scanout's DisplaySurface and pushes H.264 to subscribed clients.
 */
void helix_scanout_frame_ready(void *virtio_gpu, uint32_t scanout_id,
                                uint32_t resource_id);

/*
 * Get the global HelixFrameExport instance.
 * Returns NULL if not initialized.
 */
HelixFrameExport *helix_get_frame_export(void);

#endif /* __APPLE__ */

#endif /* HELIX_FRAME_EXPORT_H */
