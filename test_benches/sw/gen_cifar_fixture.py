"""
Fixture and reference for test_benches/sw/tb_cifar.c.

Writes images.h, weights.h and expected.h into a build directory. The first
two are what examples/sw/cifar.c expects from the exporters; the third is
this file's own answer, computed here from the PyTorch semantics rather than
from cifar.c's loops, so that agreement between them means two independently
written index expressions pick the same numbers.

Two things are deliberate about how that answer is computed.

It uses nothing but the standard library. The accelerator toolchain's venv
holds torch and NumPy, but this test checks 200 lines of integer C and has
to be runnable in a clone where none of that has been built yet -- a test
that needs the thing it is testing to be set up first does not get run.

And it is written the other way round from the C wherever there is a choice.
cifar.c fuses convolution with pooling and skips out-of-range taps with a
bounds test; this pads the input with zeros once, convolves the whole map,
and pools in a second pass. A reference that transliterates the code it
checks only proves the code was copied correctly.

Deterministic: a fixed seed, so a failure is reproducible and a pass is not
luck.

Usage: python3 test_benches/sw/gen_cifar_fixture.py <outdir>
"""

import os
import random
import sys

Q = 9
ONE = 1 << Q
N_IMAGES = 6
DIM = 32
C1, C2 = 4, 8


def conv_relu(x, w, b, cin, cout, n):
    """Q9 in, Q9 out. 3x3, padding 1, relu on the Q18 accumulator.

    Zero-padded rather than bounds-tested: cifar.c skips taps that fall off
    the edge with an `if`, and padding is the other way to write the same
    thing. The two disagree if either gets an edge wrong, which is the point.
    """
    pad = [[[0] * (n + 2) for _ in range(n + 2)] for _ in range(cin)]
    for ic in range(cin):
        for y in range(n):
            src = x[ic][y]
            dst = pad[ic][y + 1]
            for xx in range(n):
                dst[xx + 1] = src[xx]

    out = [[[0] * n for _ in range(n)] for _ in range(cout)]
    for oc in range(cout):
        bias = b[oc]
        for y in range(n):
            orow = out[oc][y]
            for xx in range(n):
                acc = bias
                for ic in range(cin):
                    wk = w[oc][ic]
                    for ky in range(3):
                        prow = pad[ic][y + ky]
                        wrow = wk[ky]
                        acc += (wrow[0] * prow[xx]
                                + wrow[1] * prow[xx + 1]
                                + wrow[2] * prow[xx + 2])
                if acc < 0:
                    acc = 0
                orow[xx] = acc >> Q
    return out


def maxpool(x, cout, n, k=4):
    m = n // k
    return [[[max(x[c][y * k + dy][xx * k + dx]
                  for dy in range(k) for dx in range(k))
              for xx in range(m)] for y in range(m)] for c in range(cout)]


def q(v, scale):
    """Round half away from zero, which is what numpy.round-then-cast did
    here and what the exporter does."""
    return int(v * scale + (0.5 if v >= 0 else -0.5))


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    rnd = random.Random(20261121)

    # Weights in the range a trained model of this size actually produces:
    # export_weights.py refuses to export a peak |param| below 0.193.
    def w4(co, ci, sd):
        return [[[[q(rnd.gauss(0, sd), ONE) for _ in range(3)]
                  for _ in range(3)] for _ in range(ci)] for _ in range(co)]

    W1 = w4(C1, 3, 0.15)
    B1 = [q(rnd.gauss(0, 0.05), ONE * ONE) for _ in range(C1)]
    W2 = w4(C2, C1, 0.15)
    B2 = [q(rnd.gauss(0, 0.05), ONE * ONE) for _ in range(C2)]
    W3 = [[q(rnd.gauss(0, 0.20), ONE) for _ in range(C2 * 2 * 2)]
          for _ in range(2)]

    # Images: RGBA with a zero pad byte, the layout the DMA reads. Smooth
    # gradients plus noise rather than uniform noise -- a convolution over
    # pure noise averages to nothing and every logit comes out the bias.
    imgs = []
    for k in range(N_IMAGES):
        im = [[[0, 0, 0, 0] for _ in range(DIM)] for _ in range(DIM)]
        for y in range(DIM):
            for x in range(DIM):
                for c in range(3):
                    base = (y * (3 + c + k) + x * (5 - c + k)) % 256
                    v = base + rnd.randrange(0, 48)
                    im[y][x][c] = 255 if v > 255 else v
        imgs.append(im)

    def logits_for(k):
        # A pixel byte v is v/256; in Q9 that is v<<1, exactly. Channels-last
        # in memory, channels-first for the convolution.
        im = imgs[k]
        x = [[[im[y][xx][c] << 1 for xx in range(DIM)] for y in range(DIM)]
             for c in range(3)]
        h1 = maxpool(conv_relu(x, W1, B1, 3, C1, DIM), C1, DIM)
        h2 = maxpool(conv_relu(h1, W2, B2, C1, C2, DIM // 4), C2, DIM // 4)
        # Flatten is channel-major: c*4 + y*2 + x, what nn.Flatten() does.
        flat = [h2[c][y][xx] for c in range(C2) for y in range(2)
                for xx in range(2)]
        return [sum(W3[o][i] * flat[i] for i in range(len(flat)))
                for o in range(2)]

    # Random weights classify everything the same way, and a fixture whose
    # argmax never changes checks the argmax not at all. Offset the second
    # logit by the median gap so the decision lands on both sides -- the
    # point is to exercise the comparison, not to be a plausible model.
    raw = [logits_for(k) for k in range(N_IMAGES)]
    gaps = sorted(r[0] - r[1] for r in raw)
    shift = gaps[len(gaps) // 2]
    B3 = [0, shift]

    expected = [[r[0], r[1] + shift] for r in raw]
    labels = [1 if e[1] > e[0] else 0 for e in expected]
    if len(set(labels)) < 2:
        raise SystemExit("fixture: every image lands in one class -- the "
                         "argmax checks in tb_cifar would be vacuous")

    def flatten(a):
        if isinstance(a, list):
            out = []
            for v in a:
                out.extend(flatten(v))
            return out
        return [a]

    def carr(f, ctype, name, a, per_line=12):
        flat = flatten(a)
        f.write(f"static const {ctype} {name}[{len(flat)}] = {{\n")
        for i in range(0, len(flat), per_line):
            f.write("    " + ", ".join(f"{v:8d}"
                                       for v in flat[i:i + per_line]) + ",\n")
        f.write("};\n")

    with open(os.path.join(outdir, "weights.h"), "w") as f:
        f.write("/* Generated by gen_cifar_fixture.py -- not a trained model. */\n")
        f.write("#ifndef WEIGHTS_H\n#define WEIGHTS_H\n#include <stdint.h>\n")
        f.write(f"#define Q_SHIFT {Q}\n#define Q_ONE   {ONE}\n")
        for ctype, name, a in [("int16_t", "W1", W1), ("int32_t", "B1", B1),
                               ("int16_t", "W2", W2), ("int32_t", "B2", B2),
                               ("int16_t", "W3", W3), ("int32_t", "B3", B3)]:
            carr(f, ctype, name, a)
        f.write("#endif /* WEIGHTS_H */\n")

    with open(os.path.join(outdir, "images.h"), "w") as f:
        f.write("/* Generated by gen_cifar_fixture.py -- not CIFAR. */\n")
        f.write("#ifndef IMAGES_H\n#define IMAGES_H\n#include <stdint.h>\n")
        f.write(f"#define N_IMAGES {N_IMAGES}\n")
        f.write(f"#define IMG_BYTES {DIM * DIM * 4}\n")
        f.write(f"#define IMG_PIXELS {DIM * DIM}\n")
        f.write('static const char *const CLASS_NAMES[2] = {"alpha", "beta"};\n')
        f.write("static const uint8_t IMAGE_LABELS[N_IMAGES] = {"
                + ", ".join(str(v) for v in labels) + "};\n")
        f.write("static const uint8_t __attribute__((aligned(4)))\n"
                "IMAGES[N_IMAGES][IMG_BYTES] = {\n")
        for k in range(N_IMAGES):
            flat = flatten(imgs[k])
            f.write("  {\n")
            for i in range(0, len(flat), 24):
                f.write("    " + ",".join(f"{v:3d}"
                                          for v in flat[i:i + 24]) + ",\n")
            f.write("  },\n")
        f.write("};\n#endif /* IMAGES_H */\n")

    with open(os.path.join(outdir, "expected.h"), "w") as f:
        f.write("/* Generated by gen_cifar_fixture.py: the reference answer. */\n")
        f.write("#ifndef EXPECTED_H\n#define EXPECTED_H\n")
        f.write(f"static const int EXPECTED[{N_IMAGES}][2] = {{\n")
        for e in expected:
            f.write(f"    {{ {e[0]:12d}, {e[1]:12d} }},\n")
        f.write("};\n#endif /* EXPECTED_H */\n")

    spread = max(abs(e[0] - e[1]) for e in expected)
    print(f"fixture: {N_IMAGES} images, labels {labels}, "
          f"widest logit margin {spread}")


if __name__ == "__main__":
    main()
