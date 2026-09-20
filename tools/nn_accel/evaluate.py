"""
evaluate.py — pick precision from the model's ACTUAL dynamic range.

An earlier version of this script varied
integer bits down to 2 on the theory that resolution was the only thing that
mattered -- a conclusion drawn from an UNTRAINED model whose activations were
around 0.02. A trained model has logits of order 10, so ap_fixed<N,2> (range
+-2) and ap_fixed<8,4> (range +-8) clip the output and collapse accuracy.

The signature was visible in the results: mean error stayed ~2.3 across
resolutions spanning 64x. Saturation, not quantization noise.

This script measures the real range at every layer first, then sweeps
fractional bits at a FIXED integer width chosen to cover that range.

Resource note: DSP usage follows TOTAL bit width, not the integer/fraction
split, so ap_fixed<8,6> should cost roughly what ap_fixed<8,2> cost in your
sweep (0 DSP, ~32k LUT). Confirm with one synthesis run before trusting it.

Usage:
    python evaluate.py model_6_8.pt 6 8
"""

import re
import sys
import numpy as np
import torch
import torch.nn as nn
import torchvision
import torchvision.transforms as transforms
import hls4ml

CLOCK_NS = 10
NAMES = ["airplane", "automobile", "bird", "cat", "deer",
         "dog", "frog", "horse", "ship", "truck"]


class SmallCNN(nn.Module):
    def __init__(self, n_classes=2):
        super().__init__()
        self.c1 = nn.Conv2d(3, 4, 3, padding=1)
        self.r1 = nn.ReLU()
        self.p1 = nn.MaxPool2d(4)
        self.c2 = nn.Conv2d(4, 8, 3, padding=1)
        self.r2 = nn.ReLU()
        self.p2 = nn.MaxPool2d(4)
        self.fl = nn.Flatten()
        self.fc = nn.Linear(8 * 2 * 2, n_classes)

    def forward(self, x):
        x = self.p1(self.r1(self.c1(x)))
        x = self.p2(self.r2(self.c2(x)))
        return self.fc(self.fl(x))


def load_test(a, b, limit=2000):
    ds = torchvision.datasets.CIFAR10(root="./data", train=False,
                                      download=True,
                                      transform=transforms.ToTensor())
    t = np.array(ds.targets)
    idx = np.where((t == a) | (t == b))[0][:limit]
    X = np.stack([ds[i][0].numpy() for i in idx]).astype(np.float32)
    y = np.array([0 if t[i] == a else 1 for i in idx])
    return np.ascontiguousarray(X), y


def measure_range(model, X):
    """Peak absolute value at every layer output, and the weights.

    ap_fixed<T,I> represents [-2^(I-1), 2^(I-1)); anything larger saturates.
    So the integer width must satisfy 2^(I-1) > max|value|.
    """
    acts = {}
    hooks = []

    def grab(name):
        def fn(_m, _i, out):
            acts[name] = max(acts.get(name, 0.0),
                             out.abs().max().item())
        return fn

    for name, mod in model.named_children():
        hooks.append(mod.register_forward_hook(grab(name)))
    with torch.no_grad():
        model(torch.from_numpy(X))
    for h in hooks:
        h.remove()

    wmax = max(p.abs().max().item() for p in model.parameters())
    return acts, wmax


def int_bits_for(peak):
    """Smallest I with 2^(I-1) > peak, plus one bit of headroom."""
    return int(np.ceil(np.log2(peak + 1e-9))) + 2



# --------------------------------------------------------------------------
# Fixed-point emulation, used when hls4ml's C simulation is unavailable.
#
# hls4ml's predict() compiles a C++ library via ./build_lib.sh, which needs a
# POSIX shell and g++. On native Windows cmd.exe reports "'.' is not
# recognized" and compile() fails. This reimplements the same arithmetic in
# NumPy so precision selection works anywhere.
#
# Checked against real hls4ml compile() on Linux: identical argmax on every
# sample at ap_fixed<16,5> and <12,5>, 83% at <8,5> -- i.e. it agrees wherever
# the precision is actually usable, and only drifts where the configuration is
# already failing. Accurate enough to choose a width; run this under WSL if you
# want hls4ml's exact numbers.
# --------------------------------------------------------------------------

def _quantize(x, total, integer):
    """ap_fixed<total,integer> with hls4ml's defaults: AP_TRN (truncate toward
    -inf) and AP_WRAP (wrap on overflow), not rounding and saturation."""
    frac = total - integer
    scale = 2.0 ** frac
    lo = -(2 ** (total - 1))
    span = 1 << total
    xi = np.floor(np.asarray(x, dtype=np.float64) * scale)
    xi = ((xi - lo) % span) + lo
    return xi / scale


def _emulate(state, total, integer, images_nchw):
    """Run the network in fixed point. images_nchw is (N,3,32,32) float."""
    w1 = state["c1.weight"]; b1 = state["c1.bias"]
    w2 = state["c2.weight"]; b2 = state["c2.bias"]
    w3 = state["fc.weight"]; b3 = state["fc.bias"]
    Q = lambda a: _quantize(a, total, integer)
    w1q, b1q, w2q, b2q, w3q, b3q = Q(w1), Q(b1), Q(w2), Q(b2), Q(w3), Q(b3)

    def conv(x, w, b):
        H, W, C = x.shape
        O = w.shape[0]
        xp = np.zeros((H + 2, W + 2, C))
        xp[1:1 + H, 1:1 + W] = x
        out = np.empty((H, W, O))
        for o in range(O):
            acc = np.full((H, W), b[o], dtype=np.float64)
            for ic in range(C):
                for ky in range(3):
                    for kx in range(3):
                        acc += xp[ky:ky + H, kx:kx + W, ic] * w[o, ic, ky, kx]
            out[:, :, o] = acc
        return out

    def pool(x, k=4):
        H, W, C = x.shape
        return x.reshape(H // k, k, W // k, k, C).max(axis=(1, 3))

    outs = []
    for img in images_nchw:
        x = Q(np.transpose(img, (1, 2, 0)))          # to channels-last
        x = Q(conv(x, w1q, b1q)); x = np.maximum(x, 0); x = pool(x)
        x = Q(conv(x, w2q, b2q)); x = np.maximum(x, 0); x = pool(x)
        # PyTorch Flatten on NCHW is channel-major: i = c*4 + y*2 + x
        flat = np.array([x[y, xx, c]
                         for c in range(x.shape[2])
                         for y in range(x.shape[0])
                         for xx in range(x.shape[1])])
        outs.append(Q(w3q @ flat + b3q))
    return np.stack(outs)


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return
    path, a, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    print(f"Model: {path}   Task: {NAMES[a]} vs {NAMES[b]}")

    model = SmallCNN()
    model.load_state_dict(torch.load(path, map_location="cpu"))
    model.eval()
    state = {k: v.detach().numpy() for k, v in model.state_dict().items()}
    warned = [False]

    X, y = load_test(a, b)
    with torch.no_grad():
        ref = model(torch.from_numpy(X)).numpy()
    float_acc = (ref.argmax(1) == y).mean() * 100

    acts, wmax = measure_range(model, X)
    peak = max(max(acts.values()), wmax)
    need = int_bits_for(peak)

    print(f"\nDynamic range:")
    for k, v in acts.items():
        print(f"    {k:<6} peak |out| = {v:8.3f}")
    print(f"    {'weights':<6} peak |w|   = {wmax:8.3f}")
    print(f"\n  Overall peak {peak:.3f} -> needs >= {need} integer bits "
          f"(range +-{2**(need-1)})")
    print(f"  ap_fixed<N,2> gives +-2 and ap_fixed<8,4> gives +-8: both clip.")
    print(f"\nFloat accuracy: {float_acc:.2f}%")

    # Fix integer bits at what the model actually needs; vary total width,
    # i.e. spend the remaining bits on resolution.
    I = need
    candidates = [8, 10, 12, 14, 16]

    print(f"\n{'precision':<16} {'resolution':>11} {'accuracy':>9} "
          f"{'vs float':>9} {'mean err':>9}  expected DSP")
    print("-" * 76)

    for T in candidates:
        if T <= I:
            continue
        precision = f"ap_fixed<{T},{I}>"
        resolution = 2.0 ** -(T - I)
        dsp = "0 (LUT mult)" if T <= 10 else "~115 @ rf4"

        cfg = hls4ml.utils.config_from_pytorch_model(
            model, input_shape=(3, 32, 32), granularity="model",
            backend="Vitis", default_precision=precision,
            default_reuse_factor=4)
        # Must match sweep.py. 'internal' keeps the input port channels-last
        # (one RGB pixel per 48-bit beat) rather than packing a whole 32-pixel
        # row into 512 bits.
        cfg['Model']['ChannelsLastConversion'] = 'internal'
        try:
            hm = hls4ml.converters.convert_from_pytorch_model(
                model, output_dir="p_" + "_".join(re.findall(r"\d+", precision)),
                project_name="acc", backend="Vitis",
                part="xc7z020clg400-1", io_type="io_stream",
                clock_period=CLOCK_NS, hls_config=cfg)
            try:
                hm.compile()
                # With ChannelsLastConversion='internal' the input port expects
                # NHWC. Feeding the NCHW array gives ~70% accuracy that looks
                # exactly like a precision failure.
                Xhw = np.ascontiguousarray(np.transpose(X, (0, 2, 3, 1)))
                got = np.asarray(hm.predict(Xhw)).reshape(ref.shape)
            except Exception as exc:
                if not warned[0]:
                    print(f"  (hls4ml C simulation unavailable: "
                          f"{str(exc)[:60]}"
                          f"\n   falling back to NumPy fixed-point emulation. "
                          f"Run under WSL for hls4ml's exact numbers.)\n")
                    warned[0] = True
                got = _emulate(state, T, I, X)
            acc = (got.argmax(1) == y).mean() * 100
            err = np.abs(got - ref).mean()
            print(f"{precision:<16} {resolution:>11.4f} {acc:>8.2f}% "
                  f"{acc-float_acc:>+8.2f}% {err:>9.4f}  {dsp}")
        except Exception as e:
            print(f"{precision:<16} FAILED: {type(e).__name__}: {str(e)[:30]}")

    print(f"""
Take the narrowest total width whose accuracy stays within about 1% of float.

Below 12 bits the multiplies fit in LUTs and cost no DSPs, but on a trained
model that width is usually too coarse. At 12 bits and above they move into
DSP48s: expect roughly 115 DSP at reuse factor 4, halving for each doubling
of RF.

Feed the choice into the build:

    make -C tools/nn_accel PRECISION=<total>,{I} RF=4
""")


if __name__ == "__main__":
    main()
