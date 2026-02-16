/*
 * Virtio GPU Device
 *
 * Copyright Red Hat, Inc. 2013-2014
 *
 * Authors:
 *     Dave Airlie <airlied@redhat.com>
 *     Gerd Hoffmann <kraxel@redhat.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"

#include "hw/virtio/virtio-gpu.h"
#include "migration/blocker.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "qemu/main-loop.h"
#include "hw/display/edid.h"
#include "trace.h"

void
virtio_gpu_base_reset(VirtIOGPUBase *g)
{
    int i;

    g->enable = 0;

    /* Reset to only scanout 0 enabled (VM console).
     * Without this, ENABLE_SCANOUT calls persist across guest reboots,
     * causing drm_fb_helper to try updating 16 virtual consoles at boot
     * which overwhelms virtio-gpu and makes the VM unresponsive. */
    g->enabled_output_bitmask = 1;

    for (i = 0; i < g->conf.max_outputs; i++) {
        g->req_state[i].width = g->conf.xres;
        g->req_state[i].height = g->conf.yres;
        g->scanout[i].resource_id = 0;
        g->scanout[i].width = 0;
        g->scanout[i].height = 0;
        g->scanout[i].x = 0;
        g->scanout[i].y = 0;
        g->scanout[i].ds = NULL;
    }
}

void
virtio_gpu_base_fill_display_info(VirtIOGPUBase *g,
                                  struct virtio_gpu_resp_display_info *dpy_info)
{
    int i;

    for (i = 0; i < g->conf.max_outputs; i++) {
        if (g->enabled_output_bitmask & (1 << i)) {
            dpy_info->pmodes[i].enabled = 1;
            dpy_info->pmodes[i].r.width = cpu_to_le32(g->req_state[i].width);
            dpy_info->pmodes[i].r.height = cpu_to_le32(g->req_state[i].height);
        }
    }
}

void
virtio_gpu_base_generate_edid(VirtIOGPUBase *g, int scanout,
                              struct virtio_gpu_resp_edid *edid)
{
    qemu_edid_info info = {
        .width_mm = g->req_state[scanout].width_mm,
        .height_mm = g->req_state[scanout].height_mm,
        .prefx = g->req_state[scanout].width,
        .prefy = g->req_state[scanout].height,
        .refresh_rate = g->req_state[scanout].refresh_rate,
    };

    edid->size = cpu_to_le32(sizeof(edid->edid));
    qemu_edid_generate(edid->edid, sizeof(edid->edid), &info);
}

static void virtio_gpu_invalidate_display(void *opaque)
{
}

static void virtio_gpu_update_display(void *opaque)
{
}

static void virtio_gpu_text_update(void *opaque, console_ch_t *chardata)
{
}

void virtio_gpu_notify_event(VirtIOGPUBase *g, uint32_t event_type)
{
    g->virtio_config.events_read |= event_type;
    virtio_notify_config(&g->parent_obj);
}

/* Helix: enable a scanout on-demand for container desktop capture.
 * Sets the display resolution and triggers a hotplug event so the
 * guest kernel's DRM driver sees the connector as "connected". */
int helix_enable_scanout(void *virtio_gpu, uint32_t scanout_id,
                         uint32_t width, uint32_t height)
{
    VirtIOGPUBase *g = VIRTIO_GPU_BASE(virtio_gpu);
    if (scanout_id >= g->conf.max_outputs || scanout_id == 0) {
        error_report("[HELIX] Invalid scanout_id %u (max=%d)\n",
                     scanout_id, g->conf.max_outputs);
        return -1;
    }

    g->req_state[scanout_id].width = width;
    g->req_state[scanout_id].height = height;
    g->enabled_output_bitmask |= (1 << scanout_id);

    /* Lazily create graphic console for this scanout if it doesn't exist yet.
     * We only create console 0 at device realize time to avoid a deadlock
     * with SPICE GL displays (see virtio_gpu_base_device_realize). */
    if (!g->scanout[scanout_id].con) {
        g->scanout[scanout_id].con =
            graphic_console_init(DEVICE(g), scanout_id, g->hw_ops, g);
    }

    virtio_gpu_notify_event(g, VIRTIO_GPU_EVENT_DISPLAY);

    error_report("[HELIX] Scanout %u enabled: %ux%u\n",
                 scanout_id, width, height);
    return 0;
}

int helix_disable_scanout(void *virtio_gpu, uint32_t scanout_id)
{
    VirtIOGPUBase *g = VIRTIO_GPU_BASE(virtio_gpu);
    if (scanout_id >= g->conf.max_outputs || scanout_id == 0) {
        return -1;
    }

    g->req_state[scanout_id].width = 0;
    g->req_state[scanout_id].height = 0;
    g->enabled_output_bitmask &= ~(1 << scanout_id);
    virtio_gpu_notify_event(g, VIRTIO_GPU_EVENT_DISPLAY);

    error_report("[HELIX] Scanout %u disabled\n", scanout_id);
    return 0;
}

static void virtio_gpu_ui_info(void *opaque, uint32_t idx, QemuUIInfo *info)
{
    VirtIOGPUBase *g = opaque;

    if (idx >= g->conf.max_outputs) {
        return;
    }

    g->req_state[idx].x = info->xoff;
    g->req_state[idx].y = info->yoff;
    g->req_state[idx].refresh_rate = info->refresh_rate;
    g->req_state[idx].width = info->width;
    g->req_state[idx].height = info->height;
    g->req_state[idx].width_mm = info->width_mm;
    g->req_state[idx].height_mm = info->height_mm;

    if (info->width && info->height) {
        g->enabled_output_bitmask |= (1 << idx);
    } else {
        g->enabled_output_bitmask &= ~(1 << idx);
    }

    /* send event to guest */
    virtio_gpu_notify_event(g, VIRTIO_GPU_EVENT_DISPLAY);
    return;
}

static void
virtio_gpu_gl_flushed(void *opaque)
{
    VirtIOGPUBase *g = opaque;
    VirtIOGPUBaseClass *vgc = VIRTIO_GPU_BASE_GET_CLASS(g);

    if (vgc->gl_flushed) {
        vgc->gl_flushed(g);
    }
}

static void
virtio_gpu_gl_block(void *opaque, bool block)
{
    VirtIOGPUBase *g = opaque;

    if (block) {
        g->renderer_blocked++;
    } else {
        g->renderer_blocked--;
    }
    assert(g->renderer_blocked >= 0);

    if (!block && g->renderer_blocked == 0) {
        virtio_gpu_gl_flushed(g);
    }
}

/*
 * Block/unblock the virtio-gpu command queue for helix frame encoding.
 * Mirrors SPICE's gl_block mechanism to provide backpressure:
 * block=true before GL blit, block=false in VT encode callback.
 */
void helix_gl_block(void *virtio_gpu, bool block)
{
    virtio_gpu_gl_block(VIRTIO_GPU_BASE(virtio_gpu), block);
}

/*
 * BH (bottom-half) callback for deferred gl_block(false).
 * Fires on the main thread after VT encode completion schedules it.
 * This matches SPICE's qemu_spice_gl_unblock_bh pattern exactly.
 */
static void helix_gl_unblock_bh(void *opaque)
{
    virtio_gpu_gl_block(VIRTIO_GPU_BASE(opaque), false);
}

/*
 * Create a BH for deferred gl_block(false). Called once during init.
 * Returns an opaque handle (QEMUBH*) to pass to helix_schedule_gl_unblock.
 */
void *helix_create_gl_unblock_bh(void *virtio_gpu)
{
    return qemu_bh_new(helix_gl_unblock_bh, virtio_gpu);
}

/*
 * Schedule the gl_unblock BH from any thread (thread-safe).
 * Called from the VT encode completion callback.
 */
void helix_schedule_gl_unblock(void *bh)
{
    if (bh) {
        qemu_bh_schedule((QEMUBH *)bh);
    }
}

static int
virtio_gpu_get_flags(void *opaque)
{
    VirtIOGPUBase *g = opaque;
    int flags = GRAPHIC_FLAGS_NONE;

    if (virtio_gpu_virgl_enabled(g->conf)) {
        flags |= GRAPHIC_FLAGS_GL;
    }

    if (virtio_gpu_dmabuf_enabled(g->conf)) {
        flags |= GRAPHIC_FLAGS_DMABUF;
    }

    return flags;
}

static const GraphicHwOps virtio_gpu_ops = {
    .get_flags = virtio_gpu_get_flags,
    .invalidate = virtio_gpu_invalidate_display,
    .gfx_update = virtio_gpu_update_display,
    .text_update = virtio_gpu_text_update,
    .ui_info = virtio_gpu_ui_info,
    .gl_block = virtio_gpu_gl_block,
};

/* Secondary scanout ops: returns no GL/DMABUF flags, forcing SPICE to
 * use a 2D display listener for these consoles. This prevents UTM's
 * broken gl_draw_done handling from affecting the shared renderer_blocked
 * counter (2D SPICE path doesn't use gl_draw_async at all). */
static int
virtio_gpu_get_flags_no_gl(void *opaque)
{
    return GRAPHIC_FLAGS_NONE;
}

static const GraphicHwOps virtio_gpu_secondary_ops = {
    .get_flags = virtio_gpu_get_flags_no_gl,
    .invalidate = virtio_gpu_invalidate_display,
    .gfx_update = virtio_gpu_update_display,
    .text_update = virtio_gpu_text_update,
    .ui_info = virtio_gpu_ui_info,
    .gl_block = virtio_gpu_gl_block,
};

bool
virtio_gpu_base_device_realize(DeviceState *qdev,
                               VirtIOHandleOutput ctrl_cb,
                               VirtIOHandleOutput cursor_cb,
                               Error **errp)
{
    VirtIODevice *vdev = VIRTIO_DEVICE(qdev);
    VirtIOGPUBase *g = VIRTIO_GPU_BASE(qdev);
    int i;

    if (g->conf.max_outputs > VIRTIO_GPU_MAX_SCANOUTS) {
        error_setg(errp, "invalid max_outputs > %d", VIRTIO_GPU_MAX_SCANOUTS);
        return false;
    }

    if (virtio_gpu_virgl_enabled(g->conf)) {
        error_setg(&g->migration_blocker, "virgl is not yet migratable");
        if (migrate_add_blocker(&g->migration_blocker, errp) < 0) {
            return false;
        }
    }

    g->virtio_config.num_scanouts = cpu_to_le32(g->conf.max_outputs);
    virtio_init(VIRTIO_DEVICE(g), VIRTIO_ID_GPU,
                sizeof(struct virtio_gpu_config));

    if (virtio_gpu_virgl_enabled(g->conf)) {
        /* use larger control queue in 3d mode — 1024 is VIRTQUEUE_MAX_SIZE.
         * With multiple GPU contexts (e.g. 4 gnome-shells), 256 entries
         * saturates quickly causing all guests to block on ring submission
         * (virtio_gpu_queue_ctrl_sgs) while QEMU drains commands. */
        virtio_add_queue(vdev, 1024, ctrl_cb);
        virtio_add_queue(vdev, 16, cursor_cb);
    } else {
        virtio_add_queue(vdev, 64, ctrl_cb);
        virtio_add_queue(vdev, 16, cursor_cb);
    }

    g->enabled_output_bitmask = 1;

    /* Apply preferred EDID resolution to all scanouts, not just scanout 0 */
    for (i = 0; i < g->conf.max_outputs; i++) {
        g->req_state[i].width = g->conf.xres;
        g->req_state[i].height = g->conf.yres;
    }

    g->hw_ops = &virtio_gpu_ops;

    /* Console 0 gets GL-capable ops for the primary SPICE GL display.
     * Secondary consoles get ops that report no GL flags, forcing SPICE
     * to use a 2D display listener. This avoids the gl_draw_done deadlock
     * where UTM never fires gl_draw_done for secondary SPICE GL channels,
     * permanently blocking renderer_blocked. */
    g->scanout[0].con =
        graphic_console_init(DEVICE(g), 0, &virtio_gpu_ops, g);
    for (i = 1; i < g->conf.max_outputs; i++) {
        g->scanout[i].con =
            graphic_console_init(DEVICE(g), i, &virtio_gpu_secondary_ops, g);
    }

    return true;
}

static uint64_t
virtio_gpu_base_get_features(VirtIODevice *vdev, uint64_t features,
                             Error **errp)
{
    VirtIOGPUBase *g = VIRTIO_GPU_BASE(vdev);

    if (virtio_gpu_virgl_enabled(g->conf) ||
        virtio_gpu_rutabaga_enabled(g->conf)) {
        features |= (1 << VIRTIO_GPU_F_VIRGL);
    }
    if (virtio_gpu_edid_enabled(g->conf)) {
        features |= (1 << VIRTIO_GPU_F_EDID);
    }
    if (virtio_gpu_blob_enabled(g->conf)) {
        features |= (1 << VIRTIO_GPU_F_RESOURCE_BLOB);
    }
    if (virtio_gpu_context_init_enabled(g->conf)) {
        features |= (1 << VIRTIO_GPU_F_CONTEXT_INIT);
    }
    if (virtio_gpu_resource_uuid_enabled(g->conf)) {
        features |= (1 << VIRTIO_GPU_F_RESOURCE_UUID);
    }

    return features;
}

static void
virtio_gpu_base_set_features(VirtIODevice *vdev, uint64_t features)
{
    static const uint32_t virgl = (1 << VIRTIO_GPU_F_VIRGL);

    trace_virtio_gpu_features(((features & virgl) == virgl));
}

void
virtio_gpu_base_device_unrealize(DeviceState *qdev)
{
    VirtIOGPUBase *g = VIRTIO_GPU_BASE(qdev);
    VirtIODevice *vdev = VIRTIO_DEVICE(qdev);

    virtio_del_queue(vdev, 0);
    virtio_del_queue(vdev, 1);
    virtio_cleanup(vdev);
    migrate_del_blocker(&g->migration_blocker);
}

static void
virtio_gpu_base_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    VirtioDeviceClass *vdc = VIRTIO_DEVICE_CLASS(klass);

    vdc->unrealize = virtio_gpu_base_device_unrealize;
    vdc->get_features = virtio_gpu_base_get_features;
    vdc->set_features = virtio_gpu_base_set_features;

    set_bit(DEVICE_CATEGORY_DISPLAY, dc->categories);
    dc->hotpluggable = false;
}

static const TypeInfo virtio_gpu_base_info = {
    .name = TYPE_VIRTIO_GPU_BASE,
    .parent = TYPE_VIRTIO_DEVICE,
    .instance_size = sizeof(VirtIOGPUBase),
    .class_size = sizeof(VirtIOGPUBaseClass),
    .class_init = virtio_gpu_base_class_init,
    .abstract = true
};
module_obj(TYPE_VIRTIO_GPU_BASE);
module_kconfig(VIRTIO_GPU);

static void
virtio_register_types(void)
{
    type_register_static(&virtio_gpu_base_info);
}

type_init(virtio_register_types)

QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_ctrl_hdr)                != 24);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_update_cursor)           != 56);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resource_unref)          != 32);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resource_create_2d)      != 40);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_set_scanout)             != 48);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resource_flush)          != 48);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_transfer_to_host_2d)     != 56);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_mem_entry)               != 16);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resource_attach_backing) != 32);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resource_detach_backing) != 32);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resp_display_info)       != 408);

QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_transfer_host_3d)        != 72);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resource_create_3d)      != 72);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_ctx_create)              != 96);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_ctx_destroy)             != 24);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_ctx_resource)            != 32);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_cmd_submit)              != 32);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_get_capset_info)         != 32);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resp_capset_info)        != 40);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_get_capset)              != 32);
QEMU_BUILD_BUG_ON(sizeof(struct virtio_gpu_resp_capset)             != 24);
