/*
 * cifar.c -- the demo. CIFAR-10, two classes, classified twice: once by the
 * accelerator and once by CVA5 running the same network in integer C, on the
 * same images, with both timed.
 *
 * accel.c proves the data path exists. This proves it computes the right
 * thing, which is a different claim and needs a reference to compare
 * against. The reference is software on the same core rather than a constant
 * baked in by the exporter: a number from the host says the model is good,
 * whereas software here says the hardware agrees with the model *as this
 * tree quantizes it*, which is the thing that can actually break.
 *
 * The image is not copied. IMAGES lives in .rodata, .rodata is in main
 * memory, and main memory is what the DMA reads -- so the driver hands the
 * accelerator the address of the constant array and touches no pixel. That
 * is the whole point of the second version: the first one spent 77% of an
 * inference storing 1,536 words into a FIFO by hand.
 *
 * Both paths read the same bytes under the same convention. A pixel byte v
 * is v/256: in hardware because the input type is ap_ufixed<8,0> and the
 * byte IS the fixed-point value, and in software because Q9 makes that
 * v << 1, exactly. Neither path rounds, so a disagreement between them is a
 * real disagreement and not a half-LSB.
 *
 * Needs headers from the trained model:
 *     make -C tools/nn_accel headers
 *     make -C examples/sw cifar
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include "soc.h"
#include "images.h"
#include "weights.h"

#define ACCEL(off) (*(volatile unsigned int *)(ACCEL_BASE + (off)))

/*
 * images.h and soc.h each describe the image, and they are generated and
 * written by different hands. If they disagree the DMA length and the array
 * stride disagree, the accelerator is fed a sliding window of the wrong
 * thing, and it answers confidently anyway. Fail the build instead.
 */
typedef char cifar_bytes_agree[(IMG_BYTES == (int)ACCEL_IMG_BYTES) ? 1 : -1];
typedef char cifar_pixels_agree[(IMG_PIXELS == (int)ACCEL_IMG_PIXELS) ? 1 : -1];

/* The network, as trained. 32x32x3 -> 8x8x4 -> 2x2x8 -> 2. */
#define DIM   32
#define C1    4
#define C2    8
#define P1    (DIM / 4)   /* 8 */
#define P2    (P1 / 4)    /* 2 */

static int32_t h1[C1][P1][P1];   /* conv1 -> relu -> pool, Q9 */
static int32_t h2[C2][P2][P2];   /* conv2 -> relu -> pool, Q9 */

#ifdef __riscv
/* -march=rv32im has not implied zicsr since binutils 2.36, and the Makefile
 * builds every target with the same ARCH. csrs.c enables it the same way. */
static unsigned read_cycles(void) {
    unsigned c;
    __asm__ volatile (".option push\n"
                      ".option arch, +zicsr\n"
                      "csrr %0, mcycle\n"
                      ".option pop"
                      : "=r" (c));
    return c;
}
#else
/* test_benches/sw/tb_cifar.c compiles this file on the host to check
 * sw_infer against an independent model. There is no mcycle there, and
 * nothing in that test reads a cycle count. */
static unsigned read_cycles(void) { return 0; }
#endif

static void putdec(unsigned v) {
    char b[11];
    int i = 10;
    b[10] = '\0';
    if (v == 0) { putstr("0"); return; }
    while (v && i) { b[--i] = (char)('0' + v % 10); v /= 10; }
    putstr(&b[i]);
}

/* Right-justified, so the columns line up without a printf. */
static void putdec_w(unsigned v, int width) {
    unsigned t = v;
    int n = 1;
    while (t >= 10) { t /= 10; n++; }
    while (n++ < width) putstr(" ");
    putdec(v);
}

static void putstr_w(const char *s, int width) {
    int n = 0;
    while (s[n]) n++;
    putstr(s);
    while (n++ < width) putstr(" ");
}

/*
 * Hardware. Writes an address, a length and a start bit; everything else is
 * the DMA's. Returns 0 on timeout.
 *
 * The accelerator is started before the DMA so the stream has somewhere to
 * go the moment it moves, and DMA_START carries bit 31 because aximm2s reads
 * the top byte's strobe -- a plain write clears the flags and starts
 * nothing, which looks exactly like a DMA that was never connected.
 */
static int hw_infer(const uint8_t *img, int *l0, int *l1, unsigned *cycles) {
    unsigned t0, t1, spins = 0, r;

    t0 = read_cycles();
    ACCEL(ACCEL_CTRL_OFF)  = ACCEL_CTRL_START;
    ACCEL(DMA_ADDRLO_OFF)  = ACCEL_RAM_OFF(img);
    ACCEL(DMA_LENLO_OFF)   = ACCEL_IMG_BYTES;
    ACCEL(DMA_CONTROL_OFF) = DMA_START;

    while (!(ACCEL(ACCEL_STATUS_OFF) & ACCEL_ST_RESULT)) {
        if (++spins > 2000000u)
            return 0;
    }
    t1 = read_cycles();

    /* One inference is one beat: two 16-bit logits, element zero in the low
     * half, which is the order hls4ml packs nnet::array in. */
    r = ACCEL(ACCEL_RESULT_OFF);
    *l0 = (int)(short)(r & 0xFFFFu);
    *l1 = (int)(short)(r >> 16);
    *cycles = t1 - t0;
    return 1;
}

/*
 * Software, the same network in Q9 integers.
 *
 * conv and pool are fused: every conv output belongs to exactly one pooling
 * window, so computing it inside the window loop costs nothing and saves the
 * 16 KB buffer a 32x32x4 intermediate would need. There is no room for that
 * buffer next to eight images of .rodata in 124 KB.
 *
 * Accumulators are Q18 (two Q9 operands multiplied) and the biases are
 * exported pre-scaled to Q18, so the inner loop has no shift in it. The
 * widest layer sums 36 terms of at most 512*512: about 9.4M, well inside
 * int32.
 */
static void sw_infer(const uint8_t *img, int *l0, int *l1) {
    int oc, ic, py, px, wy, wx, ky, kx, iy, ix, o, i;
    int32_t acc, v, best;

    for (oc = 0; oc < C1; oc++) {
        for (py = 0; py < P1; py++) {
            for (px = 0; px < P1; px++) {
                best = 0;
                for (wy = 0; wy < 4; wy++) {
                    for (wx = 0; wx < 4; wx++) {
                        int y = py * 4 + wy, x = px * 4 + wx;
                        acc = B1[oc];
                        for (ic = 0; ic < 3; ic++) {
                            for (ky = 0; ky < 3; ky++) {
                                iy = y + ky - 1;
                                if (iy < 0 || iy >= DIM) continue;
                                for (kx = 0; kx < 3; kx++) {
                                    ix = x + kx - 1;
                                    if (ix < 0 || ix >= DIM) continue;
                                    /* v/256 in Q9 is v<<1, exact. */
                                    acc += (int32_t)W1[((oc * 3 + ic) * 3 + ky) * 3 + kx]
                                         * (int32_t)(img[(iy * DIM + ix) * 4 + ic] << 1);
                                }
                            }
                        }
                        if (acc < 0) acc = 0;          /* relu, on Q18 */
                        v = acc >> Q_SHIFT;            /* back to Q9 */
                        if (v > best) best = v;        /* pool */
                    }
                }
                h1[oc][py][px] = best;
            }
        }
    }

    for (oc = 0; oc < C2; oc++) {
        for (py = 0; py < P2; py++) {
            for (px = 0; px < P2; px++) {
                best = 0;
                for (wy = 0; wy < 4; wy++) {
                    for (wx = 0; wx < 4; wx++) {
                        int y = py * 4 + wy, x = px * 4 + wx;
                        acc = B2[oc];
                        for (ic = 0; ic < C1; ic++) {
                            for (ky = 0; ky < 3; ky++) {
                                iy = y + ky - 1;
                                if (iy < 0 || iy >= P1) continue;
                                for (kx = 0; kx < 3; kx++) {
                                    ix = x + kx - 1;
                                    if (ix < 0 || ix >= P1) continue;
                                    acc += (int32_t)W2[((oc * C1 + ic) * 3 + ky) * 3 + kx]
                                         * h1[ic][iy][ix];
                                }
                            }
                        }
                        if (acc < 0) acc = 0;
                        v = acc >> Q_SHIFT;
                        if (v > best) best = v;
                    }
                }
                h2[oc][py][px] = best;
            }
        }
    }

    /* Flatten is channel-major: index c*4 + y*2 + x, which is what
     * nn.Flatten() does to an [8][2][2] tensor. */
    for (o = 0; o < 2; o++) {
        acc = B3[o];
        for (i = 0; i < C2 * P2 * P2; i++)
            acc += (int32_t)W3[o * (C2 * P2 * P2) + i]
                 * h2[i / (P2 * P2)][(i / P2) % P2][i % P2];
        if (o == 0) *l0 = (int)acc; else *l1 = (int)acc;
    }
}

int main(void) {
    unsigned hw_total = 0, sw_total = 0, hw_cyc, t0, t1, pad;
    int k, hw0, hw1, sw0, sw1, hw_class, sw_class;
    int agree = 0, hw_right = 0, sw_right = 0, fails = 0;

    puts("cifar: CIFAR-10 on the accelerator, against software on CVA5");
    putstr("  classes     ");
    putstr(CLASS_NAMES[0]); putstr(" / "); puts(CLASS_NAMES[1]);
    putstr("  images      "); putdec((unsigned)N_IMAGES);
    putstr(" x "); putdec((unsigned)IMG_BYTES); puts(" bytes, read in place by the DMA");
    puts("");
    puts("   #  label     hw        sw        hw cyc     sw cyc");

    for (k = 0; k < N_IMAGES; k++) {
        const uint8_t *img = IMAGES[k];

        if (!hw_infer(img, &hw0, &hw1, &hw_cyc)) {
            putstr("  "); putdec_w((unsigned)k, 2);
            puts("  FAIL no result from the accelerator");
            fails++;
            continue;
        }

        t0 = read_cycles();
        sw_infer(img, &sw0, &sw1);
        t1 = read_cycles();

        hw_class = (hw1 > hw0) ? 1 : 0;
        sw_class = (sw1 > sw0) ? 1 : 0;

        hw_total += hw_cyc;
        sw_total += t1 - t0;
        if (hw_class == sw_class) agree++;
        if (hw_class == (int)IMAGE_LABELS[k]) hw_right++;
        if (sw_class == (int)IMAGE_LABELS[k]) sw_right++;

        putstr("  "); putdec_w((unsigned)k, 2); putstr("  ");
        putstr_w(CLASS_NAMES[IMAGE_LABELS[k]], 9);
        putstr_w(CLASS_NAMES[hw_class], 9);
        putstr_w(CLASS_NAMES[sw_class], 9);
        putdec_w(hw_cyc, 8); putstr("  ");
        putdec_w(t1 - t0, 10);
        puts(hw_class == sw_class ? "" : "   <- disagree");
    }

    puts("");
    putstr("  agreement   "); putdec((unsigned)agree);
    putstr(" / "); putdec((unsigned)N_IMAGES); puts(" hardware vs software");
    putstr("  correct     hw "); putdec((unsigned)hw_right);
    putstr(", sw "); putdec((unsigned)sw_right);
    putstr(" of "); putdec((unsigned)N_IMAGES); puts(" against the labels");

    if (hw_total && N_IMAGES) {
        putstr("  mean cycles hw "); putdec(hw_total / (unsigned)N_IMAGES);
        putstr(", sw "); putdec(sw_total / (unsigned)N_IMAGES); puts("");
        /* One decimal, without floating point. */
        putstr("  speedup     ");
        putdec((sw_total / hw_total));
        putstr(".");
        putdec(((sw_total * 10u) / hw_total) % 10u);
        puts("x");
    }

    /* Every image here is 4 bytes a pixel, so this must still be zero. A
     * non-zero count means the exporter and the data path disagree about
     * the layout, which shifts the colours and quietly costs accuracy --
     * there is no other symptom. */
    pad = ACCEL(ACCEL_PADSEEN_OFF);
    putstr("  pad bytes   "); putdec(pad);
    puts(pad ? "  <- the images are not 4 bytes per pixel" : "  (clean)");
    if (pad) fails++;

    /* Agreement is the pass condition, not accuracy. The model is as good as
     * it is; what this checks is that the hardware computes what the
     * quantized model says it should. */
    if (agree != N_IMAGES) {
        puts("  FAIL hardware and software disagree");
        fails++;
    }

    if (fails) { putstr("FAIL cifar: "); putdec((unsigned)fails); puts(" problems"); }
    else       puts("PASS cifar");
    return 0;
}
