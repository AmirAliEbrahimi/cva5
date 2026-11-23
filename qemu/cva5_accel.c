/*
 * cva5_accel -- the hls4ml accelerator's control block and DMA, for QEMU.
 *
 * This models the plumbing in examples/xilinx/axi/cva5_accel_axi.sv and
 * nothing else. The network itself is loaded: tools/nn_accel/host_model.py
 * builds hls4ml's own generated C++ into libcva5_accel_model.so, which this
 * dlopens. That is deliberate -- a model written here would be stale the
 * first time the network was retrained, and the generated code is the same
 * C++ Vitis HLS turns into the RTL, verified against the board on all eight
 * CIFAR images including the packed result word.
 *
 * What is modelled, and all of it exists because it has caused a bug on
 * hardware at least once:
 *
 *   The DMA takes an OFFSET within main memory, not an address. Its port is
 *   only as wide as the window, so a pointer would put the top bits nowhere
 *   and read from offset zero -- the reset vector, streamed into the
 *   accelerator, returning a confident wrong answer.
 *
 *   DMA_CONTROL starts only on bit 31. aximm2s reads the top byte's strobe,
 *   so a plain write clears the flags and starts nothing, which looks
 *   exactly like a DMA that was never connected.
 *
 *   The pad counter. Four bytes a pixel, R G B and a zero; cva5_axis_lane
 *   drops the top byte and counts the ones that were not zero. Nothing
 *   downstream can tell a mis-packed image from a correct one -- the colours
 *   shift and the classifier quietly worsens -- so the count is the only
 *   symptom there is.
 *
 *   result_valid is set by a beat arriving and cleared by the result being
 *   read, in that priority. It resets only with the device, not when a guest
 *   program is reloaded, so a result nobody collected is still here for the
 *   next program -- which on hardware produced eight identical
 *   classifications in 31 cycles each.
 *
 *   irq IS result_valid, so reading the result lowers the line. Completing
 *   the PLIC source before that read leaves it high and the source comes
 *   straight back.
 *
 * What is NOT modelled: timing. A real inference is 7,093 cycles and this
 * one is instant. Nothing in the software depends on the latency -- it polls
 * a status bit or waits on an interrupt -- but a program that measured it
 * would get nonsense, and examples/sw/cifar.c's cycle column is meaningless
 * under QEMU for that reason.
 *
 * Drop this in hw/misc/ and add it to hw/misc/meson.build; see qemu/README.md.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

/* This tree's QEMU has the reorganised headers -- hw/core/sysbus.h rather
 * than hw/sysbus.h, system/address-spaces.h rather than exec/. The ones
 * confirmed by hw/riscv/cva5_pynq.c are included directly; the rest are
 * probed, so this file builds against either layout. */
#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qapi/error.h"
#include "hw/core/sysbus.h"
#include "system/address-spaces.h"

#if defined(__has_include)
#  if __has_include("hw/core/irq.h")
#    include "hw/core/irq.h"
#  else
#    include "hw/irq.h"
#  endif
#  if __has_include("hw/core/qdev-properties.h")
#    include "hw/core/qdev-properties.h"
#  else
#    include "hw/qdev-properties.h"
#  endif
#else
#  include "hw/irq.h"
#  include "hw/qdev-properties.h"
#endif

#include "migration/vmstate.h"

#include <dlfcn.h>

#define TYPE_CVA5_ACCEL "cva5.accel"
OBJECT_DECLARE_SIMPLE_TYPE(Cva5AccelState, CVA5_ACCEL)

/* examples/sw/soc.h is the authority for every one of these. */
#define R_DMA_CONTROL   0x00
#define R_DMA_ADDRLO    0x08
#define R_DMA_ADDRHI    0x0c
#define R_DMA_LENLO     0x18
#define R_DMA_LENHI     0x1c
#define R_ACCEL_CTRL    0x20
#define R_ACCEL_STATUS  0x24
#define R_ACCEL_RESULT  0x28
#define R_ACCEL_PADSEEN 0x2c

#define DMA_START       (1u << 31)
#define DMA_BUSY        (1u << 31)
#define DMA_COMPLETE    (1u << 29)

#define ST_DONE         (1u << 0)
#define ST_IDLE         (1u << 1)
#define ST_READY        (1u << 2)
#define ST_RESULT       (1u << 3)
#define ST_DMA_DONE     (1u << 4)

#define IMG_PIXELS      (32 * 32)
#define IMG_BYTES       (IMG_PIXELS * 4)

typedef uint32_t (*cva5_infer_fn)(const unsigned char *);

struct Cva5AccelState {
    SysBusDevice parent_obj;

    MemoryRegion iomem;
    qemu_irq irq;

    /* Where main memory starts, so an offset can be turned back into an
     * address. The guest writes offsets because the hardware's port is
     * narrower than the bus. */
    uint32_t ram_base;
    char *model_path;

    uint32_t dma_addr;
    uint32_t dma_len;
    uint32_t dma_ctrl;
    uint32_t result;
    uint32_t pad_seen;
    bool result_valid;
    bool ap_start;

    void *dl;
    cva5_infer_fn infer;
};

static void cva5_accel_update_irq(Cva5AccelState *s)
{
    /* irq is result_valid in the RTL, not a separate latch. */
    qemu_set_irq(s->irq, s->result_valid);
}

/*
 * One inference: read the image out of guest memory, drop the pad byte of
 * each pixel and count the ones that were not zero, hand the rest to the
 * model.
 */
static void cva5_accel_run(Cva5AccelState *s)
{
    g_autofree uint8_t *buf = NULL;
    uint32_t len = s->dma_len;
    hwaddr addr = (hwaddr)s->ram_base + s->dma_addr;
    uint32_t i;

    if (len != IMG_BYTES) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cva5.accel: DMA length %u, the accelerator consumes "
                      "exactly %u bytes (32x32 pixels, 4 bytes each)\n",
                      len, (unsigned)IMG_BYTES);
        if (len > IMG_BYTES) {
            len = IMG_BYTES;
        } else {
            s->dma_ctrl = (s->dma_ctrl & ~DMA_BUSY) | DMA_COMPLETE;
            return;
        }
    }

    buf = g_malloc0(IMG_BYTES);
    if (address_space_read(&address_space_memory, addr,
                           MEMTXATTRS_UNSPECIFIED, buf, len) != MEMTX_OK) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cva5.accel: DMA read from 0x%" HWADDR_PRIx " failed -- "
                      "note that DMA_ADDRLO takes an OFFSET within main "
                      "memory, not a pointer\n", addr);
        s->dma_ctrl = (s->dma_ctrl & ~DMA_BUSY) | DMA_COMPLETE;
        return;
    }

    /* cva5_axis_lane: tdata[23:0] through, the top byte counted if set.
     * Saturating, because a counter that wraps to zero reports success. */
    for (i = 0; i < IMG_PIXELS; i++) {
        if (buf[i * 4 + 3] != 0 && s->pad_seen != 0xffff) {
            s->pad_seen++;
        }
    }

    if (!s->infer) {
        qemu_log_mask(LOG_UNIMP,
                      "cva5.accel: no model loaded, returning zero -- build "
                      "one with 'make -C tools/nn_accel host-model'\n");
        s->result = 0;
    } else {
        s->result = s->infer(buf);
    }

    s->result_valid = true;
    s->dma_ctrl = (s->dma_ctrl & ~DMA_BUSY) | DMA_COMPLETE;
    cva5_accel_update_irq(s);
}

static uint64_t cva5_accel_read(void *opaque, hwaddr off, unsigned size)
{
    Cva5AccelState *s = CVA5_ACCEL(opaque);
    uint32_t v;

    switch (off) {
    case R_DMA_CONTROL:
        return s->dma_ctrl;
    case R_DMA_ADDRLO:
        return s->dma_addr;
    case R_DMA_ADDRHI:
    case R_DMA_LENHI:
        return 0;
    case R_DMA_LENLO:
        return s->dma_len;
    case R_ACCEL_CTRL:
        return s->ap_start ? 1 : 0;
    case R_ACCEL_STATUS:
        /* Idle and ready always: the model returns within the write that
         * started it, so the guest can never observe it running. */
        v = ST_IDLE | ST_READY;
        if (s->result_valid) {
            v |= ST_RESULT | ST_DONE;
        }
        if (s->dma_ctrl & DMA_COMPLETE) {
            v |= ST_DMA_DONE;
        }
        return v;
    case R_ACCEL_RESULT:
        /* The read is the acknowledgement. This is what lowers irq, and
         * software that completes its PLIC source before getting here will
         * see the source raised again immediately. */
        v = s->result;
        s->result_valid = false;
        cva5_accel_update_irq(s);
        return v;
    case R_ACCEL_PADSEEN:
        return s->pad_seen;
    default:
        qemu_log_mask(LOG_UNIMP, "cva5.accel: read of unmapped +0x%" HWADDR_PRIx
                      "\n", off);
        return 0;
    }
}

static void cva5_accel_write(void *opaque, hwaddr off, uint64_t val,
                             unsigned size)
{
    Cva5AccelState *s = CVA5_ACCEL(opaque);

    switch (off) {
    case R_DMA_CONTROL:
        /* Only bit 31 starts it. aximm2s decodes the top byte's strobe, so
         * a plain write of 1 -- or of 0 -- clears the flags and starts
         * nothing. Getting this wrong on hardware looked exactly like a DMA
         * that was never connected, so it is modelled rather than
         * simplified. */
        if (val & DMA_START) {
            s->dma_ctrl = DMA_BUSY;
            cva5_accel_run(s);
        } else {
            s->dma_ctrl = 0;
        }
        return;
    case R_DMA_ADDRLO:
        s->dma_addr = val;
        return;
    case R_DMA_LENLO:
        s->dma_len = val;
        return;
    case R_DMA_ADDRHI:
    case R_DMA_LENHI:
        return;
    case R_ACCEL_CTRL:
        /* ap_start is taken on ap_ready, which here is the same cycle. */
        s->ap_start = false;
        return;
    case R_ACCEL_RESULT:
    case R_ACCEL_STATUS:
    case R_ACCEL_PADSEEN:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cva5.accel: write to read-only +0x%" HWADDR_PRIx "\n",
                      off);
        return;
    default:
        qemu_log_mask(LOG_UNIMP, "cva5.accel: write to unmapped +0x%"
                      HWADDR_PRIx "\n", off);
        return;
    }
}

static const MemoryRegionOps cva5_accel_ops = {
    .read = cva5_accel_read,
    .write = cva5_accel_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void cva5_accel_reset(DeviceState *dev)
{
    Cva5AccelState *s = CVA5_ACCEL(dev);

    s->dma_addr = 0;
    s->dma_len = 0;
    s->dma_ctrl = 0;
    s->result = 0;
    s->pad_seen = 0;
    s->result_valid = false;
    s->ap_start = false;
    cva5_accel_update_irq(s);
}

static void cva5_accel_realize(DeviceState *dev, Error **errp)
{
    Cva5AccelState *s = CVA5_ACCEL(dev);

    if (!s->model_path || !*s->model_path) {
        /* Not an error. The machine is useful without the accelerator, and
         * saying so once beats a guest that hangs on a status bit. */
        qemu_log_mask(LOG_UNIMP,
                      "cva5.accel: no model= given; the registers answer but "
                      "every inference returns zero\n");
        return;
    }

    s->dl = dlopen(s->model_path, RTLD_NOW | RTLD_LOCAL);
    if (!s->dl) {
        error_setg(errp, "cva5.accel: cannot load %s: %s",
                   s->model_path, dlerror());
        return;
    }
    s->infer = (cva5_infer_fn)dlsym(s->dl, "cva5_accel_infer");
    if (!s->infer) {
        error_setg(errp, "cva5.accel: %s has no cva5_accel_infer",
                   s->model_path);
        dlclose(s->dl);
        s->dl = NULL;
        return;
    }
}

static void cva5_accel_init(Object *obj)
{
    Cva5AccelState *s = CVA5_ACCEL(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &cva5_accel_ops, s,
                          TYPE_CVA5_ACCEL, 0x1000);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
}

/* No DEFINE_PROP_END_OF_LIST: it was removed when device_class_set_props
 * started taking the count from ARRAY_SIZE, which also made the array
 * const. */
static const Property cva5_accel_props[] = {
    DEFINE_PROP_UINT32("ram-base", Cva5AccelState, ram_base, 0x80000000),
    DEFINE_PROP_STRING("model", Cva5AccelState, model_path),
};

static const VMStateDescription vmstate_cva5_accel = {
    .name = TYPE_CVA5_ACCEL,
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (VMStateField[]) {
        VMSTATE_UINT32(dma_addr, Cva5AccelState),
        VMSTATE_UINT32(dma_len, Cva5AccelState),
        VMSTATE_UINT32(dma_ctrl, Cva5AccelState),
        VMSTATE_UINT32(result, Cva5AccelState),
        VMSTATE_UINT32(pad_seen, Cva5AccelState),
        VMSTATE_BOOL(result_valid, Cva5AccelState),
        VMSTATE_BOOL(ap_start, Cva5AccelState),
        VMSTATE_END_OF_LIST()
    }
};

static void cva5_accel_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = cva5_accel_realize;
    /* dc->reset went away with the Resettable conversion; this is the
     * shim for devices that have not been converted. */
    device_class_set_legacy_reset(dc, cva5_accel_reset);
    dc->vmsd = &vmstate_cva5_accel;
    device_class_set_props(dc, cva5_accel_props);
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);
}

static const TypeInfo cva5_accel_info = {
    .name = TYPE_CVA5_ACCEL,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(Cva5AccelState),
    .instance_init = cva5_accel_init,
    .class_init = cva5_accel_class_init,
};

static void cva5_accel_register_types(void)
{
    type_register_static(&cva5_accel_info);
}

type_init(cva5_accel_register_types)
