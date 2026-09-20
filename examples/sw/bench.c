/*
 * bench.c — CVA5 benchmark: FPGA accelerator vs software inference.
 *
 * Both paths run on the same CVA5 core at the same clock over the same
 * images in a single binary, so the comparison has no cross-run variance.
 *
 * INTEGER ONLY. CVA5 is RV32IM with no FPU; soft-float would dominate the
 * software path and make the comparison meaningless. Everything is Q9 fixed
 * point (1.0 == 512), matching the accelerator's ap_fixed<14,5> so the two
 * paths produce directly comparable logits.
 *
 * Software structure: conv -> relu -> maxpool is FUSED. MaxPool2d(4) has
 * stride 4, so pooling windows never overlap and each pool output needs only
 * a 4x4 window of conv output. Nothing is recomputed -- same MAC count as
 * the unfused version -- but conv1's 32x32x4 intermediate (16 KB as int32)
 * never exists. Peak intermediate storage is 1 KB.
 *
 * relu and max commute (relu is monotone nondecreasing), so max is taken
 * first and relu applied once per pool output.
 *
 * Hardware wire format (all three fail silently if wrong):
 *   - pixels raster order, channels-last, RGB per beat
 *   - byte-aligned packing: each 14-bit value in its own 16-bit lane
 *   - chunks a multiple of 3 words (2 pixels = 3 words; FIFO depth 512 is not)
 *
 * VERIFIED on the host: the software inference was compiled and compared
 * against PyTorch float output on random weights and images.
 */

#include <stdint.h>
#include <stdio.h>
#include "images.h"
#include "weights.h"

/* ------------------------------------------------------------------ addrs */

#define GPIO_BASE        0x60010000u
#define FIFO_BASE        0x60020000u

#define GPIO_DATA        (GPIO_BASE + 0x00)
#define GPIO_TRI         (GPIO_BASE + 0x04)
#define GPIO2_DATA       (GPIO_BASE + 0x08)
#define GPIO2_TRI        (GPIO_BASE + 0x0C)

#define AP_DONE_BIT      (1u << 0)
#define AP_IDLE_BIT      (1u << 1)

#define FIFO_TDFR        (FIFO_BASE + 0x08)
#define FIFO_TDFV        (FIFO_BASE + 0x0C)
#define FIFO_TDFD        (FIFO_BASE + 0x10)
#define FIFO_TLR         (FIFO_BASE + 0x14)
#define FIFO_RDFR        (FIFO_BASE + 0x18)
#define FIFO_RDFO        (FIFO_BASE + 0x1C)
#define FIFO_RDFD        (FIFO_BASE + 0x20)
#define FIFO_RLR         (FIFO_BASE + 0x24)
#define FIFO_RESET_KEY   0x000000A5u

/* ------------------------------------------------------------------ model */

#define IMG_W  32
#define IMG_H  32
#define IMG_C  3
#define N_PIXELS (IMG_W * IMG_H)

#define C1_OUT 4
#define P1_W   8                  /* 32 / 4 */
#define C2_OUT 8
#define P2_W   2                  /* 8 / 4  */
#define FC_IN  (C2_OUT * P2_W * P2_W)   /* 32 */
#define N_CLASSES 2

#define FIXED_W  14
#define CHUNK_WORDS     384
#define PAIRS_PER_CHUNK (CHUNK_WORDS / 3)
#define N_CHUNKS        (N_PIXELS / 2 / PAIRS_PER_CHUNK)
#define TOTAL_WORDS     (N_PIXELS / 2 * 3)

#define CPU_MHZ 100

/* ------------------------------------------------------------------- regs */

static inline void wr(uint32_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
static inline uint32_t rd(uint32_t a)         { return *(volatile uint32_t *)a; }

static inline uint32_t rdcycle32(void) {
    uint32_t c;
    asm volatile("rdcycle %0" : "=r"(c));
    return c;
}

/* --------------------------------------------------------------- fixed pt */

/* uint8 -> Q9. Training used ToTensor(): v/255. round(v/255*512). */
static inline int32_t px_to_q9(uint8_t v) {
    return (int32_t)(((uint32_t)v * Q_ONE + 127u) / 255u);
}

static int32_t lane_to_int(uint16_t raw) {
    int32_t v = raw & 0x3FFF;
    if (v & (1 << (FIXED_W - 1)))
        v -= (1 << FIXED_W);
    return v;
}

static void print_q9(int32_t v) {
    int neg = v < 0;
    if (neg) v = -v;
    printf("%s%d.%03d", neg ? "-" : "",
           (int)(v >> Q_SHIFT),
           (int)(((v & (Q_ONE - 1)) * 1000) >> Q_SHIFT));
}

/* ---------------------------------------------------------- software path */

static int32_t in_q9[N_PIXELS * IMG_C];        /* 12 KB */
static int32_t p1[P1_W * P1_W * C1_OUT];       /*  1 KB */
static int32_t p2[P2_W * P2_W * C2_OUT];       /* 128 B */

/*
 * conv1 + relu + maxpool(4), fused.
 * in_q9 is HWC Q9; p1 is HWC Q9.
 */
static void layer1(void) {
    for (int py = 0; py < P1_W; py++) {
        for (int px = 0; px < P1_W; px++) {
            for (int oc = 0; oc < C1_OUT; oc++) {
                int32_t best = -0x7FFFFFFF;

                for (int dy = 0; dy < 4; dy++) {
                    int y = py * 4 + dy;
                    for (int dx = 0; dx < 4; dx++) {
                        int x = px * 4 + dx;
                        int32_t acc = B1[oc];          /* Q18 */

                        for (int ky = 0; ky < 3; ky++) {
                            int iy = y + ky - 1;
                            if (iy < 0 || iy >= IMG_H) continue;
                            for (int kx = 0; kx < 3; kx++) {
                                int ix = x + kx - 1;
                                if (ix < 0 || ix >= IMG_W) continue;
                                const int32_t *pix = &in_q9[(iy * IMG_W + ix) * IMG_C];
                                const int16_t *w = &W1[((oc * IMG_C) * 3 + ky) * 3 + kx];
                                /* stride between input channels in W1 is 9 */
                                acc += pix[0] * (int32_t)w[0];
                                acc += pix[1] * (int32_t)w[9];
                                acc += pix[2] * (int32_t)w[18];
                            }
                        }
                        if (acc > best) best = acc;     /* max before relu */
                    }
                }
                if (best < 0) best = 0;                 /* relu */
                p1[(py * P1_W + px) * C1_OUT + oc] = best >> Q_SHIFT;
            }
        }
    }
}

/* conv2 + relu + maxpool(4), fused. p1 -> p2, both HWC Q9. */
static void layer2(void) {
    for (int py = 0; py < P2_W; py++) {
        for (int px = 0; px < P2_W; px++) {
            for (int oc = 0; oc < C2_OUT; oc++) {
                int32_t best = -0x7FFFFFFF;

                for (int dy = 0; dy < 4; dy++) {
                    int y = py * 4 + dy;
                    for (int dx = 0; dx < 4; dx++) {
                        int x = px * 4 + dx;
                        int32_t acc = B2[oc];

                        for (int ky = 0; ky < 3; ky++) {
                            int iy = y + ky - 1;
                            if (iy < 0 || iy >= P1_W) continue;
                            for (int kx = 0; kx < 3; kx++) {
                                int ix = x + kx - 1;
                                if (ix < 0 || ix >= P1_W) continue;
                                const int32_t *src = &p1[(iy * P1_W + ix) * C1_OUT];
                                const int16_t *w = &W2[((oc * C1_OUT) * 3 + ky) * 3 + kx];
                                for (int ic = 0; ic < C1_OUT; ic++)
                                    acc += src[ic] * (int32_t)w[ic * 9];
                            }
                        }
                        if (acc > best) best = acc;
                    }
                }
                if (best < 0) best = 0;
                p2[(py * P2_W + px) * C2_OUT + oc] = best >> Q_SHIFT;
            }
        }
    }
}

/*
 * Flatten + fc.
 *
 * PyTorch Flatten on an NCHW tensor (N,8,2,2) walks channel-major:
 * index = c*4 + y*2 + x. p2 is stored HWC, so the gather is explicit --
 * getting this backwards is a silent accuracy failure, not an error.
 */
static void layer3(int32_t *logits) {
    for (int o = 0; o < N_CLASSES; o++) {
        int32_t acc = B3[o];
        for (int c = 0; c < C2_OUT; c++) {
            for (int y = 0; y < P2_W; y++) {
                for (int x = 0; x < P2_W; x++) {
                    int i = c * (P2_W * P2_W) + y * P2_W + x;
                    acc += p2[(y * P2_W + x) * C2_OUT + c] * (int32_t)W3[o * FC_IN + i];
                }
            }
        }
        logits[o] = acc >> Q_SHIFT;
    }
}

static uint32_t infer_sw(const uint8_t *img, int32_t *logits) {
    uint32_t t0 = rdcycle32();
    for (int i = 0; i < N_PIXELS * IMG_C; i++)
        in_q9[i] = px_to_q9(img[i]);
    layer1();
    layer2();
    layer3(logits);
    return rdcycle32() - t0;
}

/* ---------------------------------------------------------- hardware path */

static void accel_reset(void) {
    wr(FIFO_TDFR, FIFO_RESET_KEY);
    wr(FIFO_RDFR, FIFO_RESET_KEY);
    /* AXI GPIO TRI resets to all-inputs even when configured "All Outputs" --
     * the Default Tri State field greys out but still resets high. */
    wr(GPIO_TRI,  0x00000000u);
    wr(GPIO2_TRI, 0xFFFFFFFFu);
    wr(GPIO_DATA, 0);
}

static uint32_t infer_hw(const uint8_t *img, int32_t *logits) {
    /* Flush both FIFOs: residue from the previous image would be prepended to
     * this one and every inference would compute on a misaligned mixture. */
    wr(FIFO_TDFR, FIFO_RESET_KEY);
    wr(FIFO_RDFR, FIFO_RESET_KEY);

    int wg = 100000;
    while (!(rd(GPIO2_DATA) & AP_IDLE_BIT) && --wg > 0) { }

    uint32_t t0 = rdcycle32();

    wr(GPIO_DATA, 1);                      /* ap_start pulse */
    wr(GPIO_DATA, 0);

    const uint8_t *p = img;
    for (int c = 0; c < N_CHUNKS; c++) {
        int g = 1000000;
        while ((int)rd(FIFO_TDFV) < CHUNK_WORDS && --g > 0) { }
        if (g <= 0) { printf("  [!] TX timeout\n"); return 0; }

        for (int k = 0; k < PAIRS_PER_CHUNK; k++) {
            uint32_t r0 = px_to_q9(p[0]), g0 = px_to_q9(p[1]), b0 = px_to_q9(p[2]);
            uint32_t r1 = px_to_q9(p[3]), g1 = px_to_q9(p[4]), b1 = px_to_q9(p[5]);
            p += 6;
            wr(FIFO_TDFD, r0 | (g0 << 16));
            wr(FIFO_TDFD, b0 | (r1 << 16));
            wr(FIFO_TDFD, g1 | (b1 << 16));
        }
        wr(FIFO_TLR, CHUNK_WORDS * 4);
    }

    int g = 10000000;
    while (rd(FIFO_RDFO) == 0 && --g > 0) { }
    if (g <= 0) { printf("  [!] RX timeout\n"); return 0; }

    (void)rd(FIFO_RLR);
    uint32_t res = rd(FIFO_RDFD);
    uint32_t t1 = rdcycle32();

    logits[0] = lane_to_int((uint16_t)(res & 0xFFFF));
    logits[1] = lane_to_int((uint16_t)(res >> 16));
    return t1 - t0;
}

/* ------------------------------------------------------------------- main */

int main(void) {
    printf("\nCVA5: FPGA accelerator vs software inference\n");
    printf("  %s vs %s, %d images\n\n", CLASS_NAMES[0], CLASS_NAMES[1], N_IMAGES);

    accel_reset();
    uint32_t st = rd(GPIO2_DATA);
    printf("accelerator: idle=%d\n", !!(st & AP_IDLE_BIT));
    if (!(st & AP_IDLE_BIT))
        printf("[!] not idle -- check ap_rst_n polarity\n");
    printf("\n");

    int hw_ok = 0, sw_ok = 0, agree = 0, ran = 0;
    uint32_t hw_total = 0, sw_total = 0;

    printf("img  truth  hw pred / logits          sw pred / logits          cycles hw/sw\n");
    printf("---------------------------------------------------------------------------\n");

    for (int k = 0; k < N_IMAGES; k++) {
        int32_t lh[2], ls[2];
        uint32_t ch = infer_hw(IMAGES[k], lh);
        uint32_t cs = infer_sw(IMAGES[k], ls);
        if (ch == 0) { printf("%3d  hw failed\n", k); continue; }

        int ph = (lh[1] > lh[0]) ? 1 : 0;
        int ps = (ls[1] > ls[0]) ? 1 : 0;
        hw_ok += (ph == IMAGE_LABELS[k]);
        sw_ok += (ps == IMAGE_LABELS[k]);
        agree += (ph == ps);
        ran++;
        hw_total += ch;
        sw_total += cs;

        printf("%3d  %-6s %-4s ", k, CLASS_NAMES[IMAGE_LABELS[k]], CLASS_NAMES[ph]);
        print_q9(lh[0]); printf("/"); print_q9(lh[1]);
        printf("   %-4s ", CLASS_NAMES[ps]);
        print_q9(ls[0]); printf("/"); print_q9(ls[1]);
        printf("   %u/%u\n", (unsigned)ch, (unsigned)cs);
    }

    if (ran == 0) { printf("\nnothing completed\n"); return 1; }

    uint32_t hw = hw_total / ran, sw = sw_total / ran;

    printf("\n");
    printf("accuracy      hw %d/%d   sw %d/%d   agree %d/%d\n",
           hw_ok, ran, sw_ok, ran, agree, ran);
    printf("hardware      %8u cycles  %6u us\n", (unsigned)hw, (unsigned)(hw / CPU_MHZ));
    printf("software      %8u cycles  %6u us\n", (unsigned)sw, (unsigned)(sw / CPU_MHZ));
    printf("speedup       %8u.%02ux\n",
           (unsigned)(sw / hw), (unsigned)((100u * (sw % hw)) / hw));
    printf("\n");
    printf("hardware breakdown (compute 6947 cycles from HLS):\n");
    uint32_t move = (hw > 6947) ? hw - 6947 : 0;
    printf("  compute     %8u cycles  %6u us  %u%%\n",
           6947u, 6947u / CPU_MHZ, (unsigned)(100u * 6947u / hw));
    printf("  data move   %8u cycles  %6u us  %u%%\n",
           (unsigned)move, (unsigned)(move / CPU_MHZ),
           (unsigned)(100u * move / hw));
    printf("  speedup vs sw if transfer were free: %ux\n",
           (unsigned)(sw / 6947u));

    return 0;
}
