"""
ref_const.py — host reference for the driver's constant-image self test.

The driver runs a constant image (every pixel 64,128,192) before the real
images. Because every AXI beat carries identical data, pixel ordering and
chunk alignment cannot affect the result -- so if the board's self-test
matches this script, the bit packing and fixed-point conversion are correct
and any remaining error is ordering or alignment.

Prints the expected logits in both float and 1/512 units (ap_fixed<14,5>),
which is what the driver's print_fixed shows.

Usage:
    python ref_const.py model_6_8.pt
    python ref_const.py model_6_8.pt --rgb 64 128 192
"""

import argparse
import numpy as np
import torch
import torch.nn as nn


class SmallCNN(nn.Module):
    """Must match train.py / sweep.py / examples/sw/bench.c."""

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--rgb", nargs=3, type=int, default=[64, 128, 192],
                    help="constant pixel value, 0-255 (must match examples/sw/bench.c)")
    args = ap.parse_args()

    model = SmallCNN()
    model.load_state_dict(torch.load(args.model, map_location="cpu"))
    model.eval()

    # Weight range is a quick check that these are trained, not random.
    # PyTorch default init for Conv2d(3,4,3) is uniform +-1/sqrt(27) = +-0.192,
    # so weights sitting neatly inside that range mean the state_dict never
    # loaded -- which is exactly how the first synthesized IP came out wrong.
    w = model.c1.weight.detach().numpy()
    print(f"c1 weight range: [{w.min():+.4f}, {w.max():+.4f}]")
    if abs(w).max() < 0.193:
        print("  WARNING: inside PyTorch's default init range -- these may be "
              "untrained weights")
    print()

    r, g, b = args.rgb
    X = np.zeros((1, 3, 32, 32), dtype=np.float32)
    X[0, 0, :, :] = r / 255.0
    X[0, 1, :, :] = g / 255.0
    X[0, 2, :, :] = b / 255.0

    with torch.no_grad():
        out = model(torch.from_numpy(X)).numpy()[0]

    print(f"constant image ({r},{g},{b}) -> ({r/255:.3f},{g/255:.3f},{b/255:.3f})")
    print()
    print(f"  float logits   {out[0]:+.6f} / {out[1]:+.6f}")
    print(f"  x512 (raw)     {int(round(out[0]*512)):+d} / "
          f"{int(round(out[1]*512)):+d}")
    print(f"  as print_fixed {out[0]:+.3f} / {out[1]:+.3f}")
    print()
    print(f"  prediction     {'frog' if out[0] > out[1] else 'ship'}"
          f"   margin {abs(out[0]-out[1]):.3f}")
    print()
    print("Compare against the board's 'selftest' line. Agreement to within a\n"
          "few thousandths means packing and conversion are correct. A margin\n"
          "near zero here means the constant image is genuinely ambiguous to\n"
          "the model and is a weak test -- try --rgb 20 60 200 (ship-like) or\n"
          "--rgb 40 120 40 (frog-like) for something with a clearer answer.")


if __name__ == "__main__":
    main()
