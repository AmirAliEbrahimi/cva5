"""
sweep.py — reuse_factor x precision sweep for the CNN on xc7z020

Which (reuse_factor, precision) combinations fit alongside CVA5. For scale:
an early ap_fixed<16,6> point at RF=1 needed 337 DSP, 153% of a 7020.

Budget assumption: CVA5 + AXI DMA + interconnect + UART need headroom, so the
accelerator target is ~35k LUT and ~150 DSP, not the full device. Adjust
BUDGET below once you know your actual CVA5 utilisation.

IMPORTANT: this loads the TRAINED weights. Earlier versions built
SmallCNN() fresh and synthesised randomly-initialised weights, which produces
IP whose output barely depends on its input -- logits clustered near zero and
chance accuracy on hardware, with nothing in the toolchain to flag it.

Usage:
    python sweep.py generate     # write all project dirs + run_all.bat
    run_all.bat                  # synthesise each (unattended, ~1h)
    python sweep.py report       # parse every csynth.rpt into a table

VERIFIED: generation and report parsing executed locally against hls4ml 1.3.0.
NOT VERIFIED: the synthesis numbers -- that is what the sweep produces.
"""

import argparse
import os
import re
import sys
import glob

import torch
import torch.nn as nn
import hls4ml

PART = "xc7z020clg400-1"
CLOCK_NS = 10
INPUT_SHAPE = (3, 32, 32)
MODEL_PATH = "model_6_8.pt"   # Makefile passes --model explicitly

# Sweep points. Precision first -- it is the stronger lever and matches the
# quantized-inference premise.
PRECISIONS = ["ap_fixed<14,5>"]   # chosen operating point
REUSE_FACTORS = [4]

# 7020 device totals, and the share the accelerator can realistically claim.
DEVICE = {"BRAM_18K": 280, "DSP": 220, "FF": 106400, "LUT": 53200}
# CVA5 measured at 3020 LUT / 4 DSP post-implementation; the rest of the
# budget leaves room for the stream FIFO, width converter, GPIO and
# interconnect, and keeps occupancy where the 7020 still routes.
BUDGET = {"DSP": 200, "LUT": 42000}


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


def load_model():
    """Load the trained weights, and refuse to proceed without them.

    The check on weight range catches the failure that actually happened: a
    state_dict that never loaded leaves PyTorch's default init, which for
    Conv2d(3,4,3) is uniform over +-1/sqrt(27) = +-0.192. Synthesising that
    gives working hardware computing a random function.
    """
    model = SmallCNN()
    if not os.path.exists(MODEL_PATH):
        raise SystemExit(f"[!] {MODEL_PATH} not found -- train it first "
                         f"(train.py / pair_search.py --final)")
    model.load_state_dict(torch.load(MODEL_PATH, map_location="cpu"))
    model.eval()

    peak = max(p.abs().max().item() for p in model.parameters())
    print(f"[+] loaded {MODEL_PATH}, peak |param| = {peak:.4f}")
    if peak < 0.193:
        raise SystemExit("[!] weights look untrained (inside PyTorch default "
                         "init range) -- refusing to synthesise")
    return model


def tag(precision, rf):
    bits = precision.replace("ap_fixed<", "").replace(">", "").replace(",", "_")
    return f"sw_{bits}_rf{rf}"


def patch_tcl(out_dir):
    """-maximum_size is the stale Vivado HLS spelling; 2025.1 wants
    -complete_threshold. hls4ml wraps it in catch{} so it fails silently."""
    p = os.path.join(out_dir, "build_prj.tcl")
    s = open(p).read()
    if "-maximum_size" in s:
        open(p, "w").write(
            s.replace("config_array_partition -maximum_size",
                      "config_array_partition -complete_threshold"))


def set_build_opts(out_dir):
    with open(os.path.join(out_dir, "build_opt.tcl"), "w") as f:
        f.write("array set opt {\n    reset      1\n    csim       0\n"
                "    synth      1\n    cosim      0\n    validation 0\n"
                "    export     1\n    vsynth     0\n    fifo_opt   0\n}\n")
    # export on: costs ~90s per config and leaves packaged IP in
    # <dir>/cnn_prj/solution1/impl/ip/ ready for the Vivado IP repo.


def generate():
    model = load_model()
    dirs = []

    for precision in PRECISIONS:
        for rf in REUSE_FACTORS:
            out_dir = tag(precision, rf)
            cfg = hls4ml.utils.config_from_pytorch_model(
                model, input_shape=INPUT_SHAPE, granularity="model",
                backend="Vitis", default_precision=precision,
                default_reuse_factor=rf)

            # 'internal' keeps the input port channels-last: one RGB pixel
            # (3 x 16 bits = 48) per AXI beat instead of a whole 32-pixel row
            # (512 bits). Saves ~8.8k LUT and ~43k FF at no latency cost, and
            # the driver must feed pixels in raster order to match.
            cfg['Model']['ChannelsLastConversion'] = 'internal'

            hls_model = hls4ml.converters.convert_from_pytorch_model(
                model, output_dir=out_dir, project_name="cnn", backend="Vitis",
                part=PART, io_type="io_stream", clock_period=CLOCK_NS,
                hls_config=cfg)
            hls_model.write()
            patch_tcl(out_dir)
            set_build_opts(out_dir)
            dirs.append(out_dir)
            print(f"[+] {out_dir}")

    with open("run_all.bat", "w") as f:
        f.write("@echo off\n")
        for d in dirs:
            f.write(f"echo === {d} ===\n")
            f.write(f"pushd {d}\n")
            f.write("call vitis-run --mode hls --tcl build_prj.tcl\n")
            f.write("popd\n")
    print(f"\n[+] run_all.bat written ({len(dirs)} configurations)")
    print("    Run it, then: python sweep.py report")


def parse_report(path):
    """Pull the utilisation Total row out of a csynth report."""
    txt = open(path, errors="ignore").read()
    m = re.search(r"\|Total\s*\|([^\n]+)\|", txt)
    if not m:
        return None
    cells = [c.strip() for c in m.group(1).split("|")]
    try:
        bram, dsp, ff, lut = (int(cells[i]) for i in range(4))
    except (ValueError, IndexError):
        return None

    lat = re.search(r"\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*[\d.]+ ns", txt)
    return {"BRAM_18K": bram, "DSP": dsp, "FF": ff, "LUT": lut,
            "latency": int(lat.group(2)) if lat else None}


def report():
    rows = []
    for rpt in sorted(glob.glob("sw_*/cnn_prj/solution1/syn/report/cnn_csynth.rpt")):
        name = rpt.split(os.sep)[0]
        r = parse_report(rpt)
        if r:
            rows.append((name, r))

    if not rows:
        print("No reports found. Run run_all.bat first.")
        return

    print(f"\n{'config':<20} {'DSP':>6} {'LUT':>7} {'FF':>7} {'BRAM':>5} "
          f"{'cycles':>8}  fits?")
    print("-" * 70)
    for name, r in rows:
        fits = r["DSP"] <= BUDGET["DSP"] and r["LUT"] <= BUDGET["LUT"]
        cyc = r["latency"] if r["latency"] else "?"
        lat_us = f"{r['latency'] * CLOCK_NS / 1000:.1f}us" if r["latency"] else ""
        print(f"{name:<20} {r['DSP']:>6} {r['LUT']:>7} {r['FF']:>7} "
              f"{r['BRAM_18K']:>5} {cyc:>8}  {'YES ' + lat_us if fits else 'no'}")

    print(f"\nBudget: DSP<={BUDGET['DSP']}, LUT<={BUDGET['LUT']} "
          f"(leaving room for CVA5 + DMA + interconnect)")
    print(f"Device: DSP={DEVICE['DSP']}, LUT={DEVICE['LUT']}, "
          f"FF={DEVICE['FF']}, BRAM_18K={DEVICE['BRAM_18K']}")
    print("\nPick the cheapest config that fits, then re-run it with "
          "export=1 in build_opt.tcl to get the IP.")


def _parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command", nargs="?", default="generate",
                    choices=["generate", "report"])
    ap.add_argument("--model", default=MODEL_PATH,
                    help="trained state_dict to synthesise")
    ap.add_argument("--precision", default=None,
                    help='e.g. "14,5" -- overrides PRECISIONS')
    ap.add_argument("--rf", type=int, default=None,
                    help="reuse factor -- overrides REUSE_FACTORS")
    return ap.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    MODEL_PATH = args.model
    if args.precision:
        PRECISIONS = [f"ap_fixed<{args.precision}>"]
    if args.rf is not None:
        REUSE_FACTORS = [args.rf]

    if args.command == "generate":
        generate()
    else:
        report()
