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
# Vivado asks for 10 ns (100 MHz); HLS is told 8. HLS schedules right up to
# its own budget -- target minus the 27% uncertainty -- so asking for 10 gave a
# 7.279 ns estimate with 21 ps to spare, leaving 2.72 ns for routing. That
# closed at +0.139 ns once and at -1.01 ns on a rebuild of the identical
# netlist: same design, different placement, no real margin either way.
#
# Asking for 8 gives a 5.834 ns estimate and 4.17 ns of routing headroom, and
# closes at +0.309 ns. It cost nothing -- still 6947 cycles, still 69.5 us on
# the board at 100 MHz, because HLS absorbed it in scheduling rather than
# extra pipeline stages.
CLOCK_NS       = 8     # what HLS schedules against
BOARD_CLOCK_NS = 10    # what the hardware runs at, for latency reporting
INPUT_SHAPE = (3, 32, 32)
MODEL_PATH = "model_6_8.pt"   # Makefile passes --model explicitly

# Sweep points. Precision first -- it is the stronger lever and matches the
# quantized-inference premise.
PRECISIONS = ["ap_fixed<14,5>"]   # chosen operating point

# The INPUT layer's precision, overridden away from the model default.
#
# This is what makes the accelerator's input port 24 bits wide instead of 48,
# and it is the one precision in the network that can be changed without
# re-opening the accuracy question. GOTCHAS #3 is about saturation in the
# logits, which reach +-7.3; the input is pixel data in [0,1], because
# train.py uses ToTensor() alone and no mean/std normalisation. Zero integer
# bits is therefore not a compromise, it is the range.
#
# ap_ufixed<8,0> represents k/256 for k in 0..255, so all 256 distinct source
# levels survive. The source IS 8-bit: CIFAR pixels are uint8.
#
# Why it changes the port width: hls4ml packs io_stream channels into one AXI
# beat and pads each element to a byte boundary. 3 x ap_fixed<14,5> pads 14 to
# 16 and gives the 48 bits the old design converted down from. 3 x 8 pads to
# nothing and gives 24. With the image stored 4 bytes per pixel, the DMA's
# 32-bit beat then carries exactly one pixel and the path from memory to the
# accelerator is a lane select, not a width converter.
#
# The convention everywhere is now v/256, not v/255. The hardware gets that
# for free from ap_ufixed<8,0>; examples/sw/bench.c's Q9 conversion becomes
# v << 1, exact rather than round(v/255*512); and the host reference below
# matches. One convention in three places beats a 255/256 correction folded
# into conv1's weights, which would have put the exported weights and the
# hls4ml model out of step with each other.
INPUT_PRECISION = "ap_ufixed<8,0>"

# hls4ml names a PyTorch input layer after the FX placeholder node, which for
# `def forward(self, x)` is "x" -- the same name the block design connects to
# as cnn_0/x. Overriding LayerName on a granularity="model" config is
# supported: HLSConfig.get_layer_config_value looks in LayerName first and
# falls through to Model, so every other layer keeps default_precision and
# nothing else about the sweep changes.
INPUT_LAYER = "x"
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


def check_input_type(out_dir):
    """Read back the input type hls4ml actually generated, and say how wide
    the AXI-Stream port will be.

    The override above is a dictionary key. A wrong layer name is not an
    error in hls4ml -- it is silently ignored, the input keeps
    default_precision, and the first sign is a 48-bit port in Vivado an hour
    later. So this reads firmware/defines.h, which is the artifact that
    decides the port, and refuses to continue if the override did not take.
    """
    defines = os.path.join(out_dir, "firmware", "defines.h")
    with open(defines) as f:
        src = f.read()

    # typedef nnet::array<ap_fixed<14,5>, 3*1> input_t;
    #
    # Greedy on the precision, because it contains a comma of its own. The
    # tail is constrained to an arithmetic expression so the backtracking
    # lands on the right comma. "input_t" and not some other name: hls4ml
    # calls the first input layer's type input_t and numbers the rest.
    m = re.search(r"typedef\s+nnet::array<(.+),\s*([\d\s*/]+)>\s+input_t", src)
    if not m:
        raise SystemExit(f"[!] {defines}: no input_t typedef found -- hls4ml's "
                         f"generated layout has changed, and the port width "
                         f"below can no longer be derived from it")

    elem, count = m.group(1).strip(), m.group(2).strip()
    if elem != INPUT_PRECISION:
        raise SystemExit(
            f"[!] {defines}: input element is {elem}, expected "
            f"{INPUT_PRECISION}.\n"
            f"    The LayerName override did not take. hls4ml ignores an "
            f"unknown layer name silently,\n"
            f"    so INPUT_LAYER ({INPUT_LAYER!r}) is probably not what this "
            f"model's input is called.")

    # Element bits padded up to a byte, times the channel count. This is the
    # rule that gave 48 for 3 x ap_fixed<14,5>; see INPUT_PRECISION above.
    bits = re.search(r"<\s*(\d+)", elem)
    chans = re.search(r"(\d+)", count)
    if bits and chans:
        width = -(-int(bits.group(1)) // 8) * 8 * int(chans.group(1))
        print(f"    input_t = {elem} x {count}  ->  {width}-bit stream port")
        if width != 24:
            print(f"    NOTE: expected 24. The lane select in the block "
                  f"design assumes one pixel per 32-bit word.")


def tag(precision, rf):
    bits = precision.replace("ap_fixed<", "").replace(">", "").replace(",", "_")
    return f"sw_{bits}_rf{rf}"


def patch_tcl(out_dir):
    """Fix two hls4ml defaults that this toolchain and device need.

    -maximum_size is the stale Vivado HLS spelling; 2025.1 wants
    -complete_threshold, and hls4ml wraps it in catch{} so it fails silently.
    enable_dsp_full_reg=false leaves the DSP48 output unregistered."""
    p = os.path.join(out_dir, "build_prj.tcl")
    s = open(p).read()
    s = s.replace("config_array_partition -maximum_size",
                  "config_array_partition -complete_threshold")
    # hls4ml writes enable_dsp_full_reg=false, leaving the DSP48 output
    # register unused -- a combinational multiply then feeds a CARRY4 chain,
    # 3.863 ns of a 9.84 ns path. Registering it is nearly free at 17% FF use.
    s = s.replace("config_schedule -enable_dsp_full_reg=false",
                  "config_schedule -enable_dsp_full_reg=true")
    open(p, "w").write(s)


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

            cfg.setdefault('LayerName', {})[INPUT_LAYER] = {
                'Precision': {'result': INPUT_PRECISION}}

            hls_model = hls4ml.converters.convert_from_pytorch_model(
                model, output_dir=out_dir, project_name="cnn", backend="Vitis",
                part=PART, io_type="io_stream", clock_period=CLOCK_NS,
                hls_config=cfg)
            hls_model.write()
            check_input_type(out_dir)
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
        lat_us = f"{r['latency'] * BOARD_CLOCK_NS / 1000:.1f}us" if r["latency"] else ""
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
    ap.add_argument("--input-precision", default=None,
                    help="precision for the input layer alone, e.g. "
                         "ap_ufixed<8,0>. Decides the AXI-Stream port width; "
                         "see INPUT_PRECISION above.")
    ap.add_argument("--rf", type=int, default=None,
                    help="reuse factor -- overrides REUSE_FACTORS")
    return ap.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    MODEL_PATH = args.model
    if args.input_precision:
        INPUT_PRECISION = args.input_precision
    if args.precision:
        PRECISIONS = [f"ap_fixed<{args.precision}>"]
    if args.rf is not None:
        REUSE_FACTORS = [args.rf]

    if args.command == "generate":
        generate()
    else:
        report()
