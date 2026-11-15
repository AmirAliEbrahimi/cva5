# ============================================================================
#  tools/nn_accel/Makefile
#  End-to-end build for the CNN accelerator: venv, training, HLS, IP export,
#  headers, bitstream.
#
#  From the repository root:
#    make -C tools/nn_accel all        everything, clean clone to bitstream
#    make -C tools/nn_accel            same (all is the default)
#
#  Individual stages, each depending on the previous one:
#    venv        create .venv and install pinned requirements
#    train       train the network            -> model_$(CLASS_A)_$(CLASS_B).pt
#    precision   report the precision sweep   (informational)
#    ip          generate + export accelerator IP
#    headers     weights.h + images.h         -> examples/sw/
#    mif         build bench.c                -> examples/sw/mem.mif
#    bitstream   package CVA5 as IP + build the SoC
#    baseline    build the stock SoC with no accelerator (diagnostic)
#
#  Knobs:
#    make all CLASS_A=3 CLASS_B=5      different CIFAR pair (cat vs dog)
#    make all N_IMAGES=4               fewer test images (less .rodata)
#    make all PRECISION=12,5 RF=8      different accelerator operating point
#    make all JOBS=8                   Vivado parallelism
#    make bitstream BUILD=0            block design only, no implementation
#    make CROSS=riscv-none-elf-        different toolchain prefix
#
#  On Windows see docs/nn_accelerator/README.md -- the toolchain spans WSL and
#  native Windows, and the two halves can be run separately.
#
#  Nothing here needs to run as a prerequisite for the rest of the repo: the
#  original `make -C examples/sw run` demo is untouched.
# ============================================================================

# Relative, deliberately. An absolute Windows path (D:/...) breaks GNU make
# three ways: the colon in a target is parsed as the target/prereq separator,
# cmd.exe mishandles forward slashes in executable paths, and plain `cd` does
# not change drive. Relative paths sidestep all three and work in both shells.
REPO      := ../..
SW        := ../../examples/sw

# --- what to build ---------------------------------------------------------
CLASS_A   ?= 6
CLASS_B   ?= 8
N_IMAGES  ?= 8
PRECISION ?= 14,5
RF        ?= 4
JOBS      ?= 4
BUILD     ?= 1

comma     := ,
MODEL     := model_$(CLASS_A)_$(CLASS_B).pt
# sweep.py names its output directory after the precision with commas turned
# into underscores: ap_fixed<14,5> at RF 4 -> sw_14_5_rf4
IPDIR     := sw_$(subst $(comma),_,$(PRECISION))_rf$(RF)

# --- python ----------------------------------------------------------------
# A venv keeps the pinned hls4ml away from the system interpreter. hls4ml's
# generated C++ is sensitive to its own version and to the Vitis HLS version,
# and every measured result in docs/nn_accelerator was produced with 1.3.0.
VENV      := .venv
ifeq ($(OS),Windows_NT)
  PY      := $(VENV)\Scripts\python.exe
  VENVPY  := python
else
  PY      := $(VENV)/bin/python
  VENVPY  := python3
endif

# Always "python -m pip", never the pip executable: on Windows pip cannot
# replace its own .exe while it is running, so `pip install --upgrade pip`
# fails outright.
PIP       := $(PY) -m pip

# The stamp is what "the venv is ready" actually means. Using the interpreter
# itself as the target is wrong: `venv` creates it before the requirements are
# installed, so any later failure leaves a target that looks complete and the
# next make run skips the install.
STAMP     := $(VENV)/.requirements-installed

# --- Xilinx tools ----------------------------------------------------------
# Expected on PATH. Override if they are not:
#   make VIVADO=/opt/Xilinx/2025.1/Vivado/bin/vivado
VIVADO    ?= vivado
VITIS_RUN ?= vitis-run

# --- RISC-V toolchain ------------------------------------------------------
# Passed through to examples/sw/Makefile. The Ubuntu package is
# riscv64-unknown-elf-; the xPack Windows build is riscv-none-elf-.
CROSS     ?= riscv64-unknown-elf-

.PHONY: all venv train precision ip headers mif bitstream baseline clean distclean help

all: mif bitstream
	@echo
	@echo "Done. Program examples/sw/... bitstream and open the serial"
	@echo "terminal at 9600 8N1. Expect ~50x speedup, hw and sw agreeing."

# --- 0. environment --------------------------------------------------------
# If a previous run left a half-built venv, `make distclean` removes it. The
# cleanup targets deliberately use the system interpreter, not $(PY), so they
# still work when the venv is broken.
$(STAMP): requirements.txt
	@echo [nn] creating $(VENV)
	$(VENVPY) -m venv $(VENV)
	$(PIP) install --quiet --upgrade pip
	$(PIP) install --quiet -r requirements.txt
	@$(PY) -c "open(r'$(STAMP)','w').close()"
	@echo [nn] $(VENV) ready

venv: $(STAMP)

# --- 1. train --------------------------------------------------------------
$(MODEL): $(STAMP) train.py
	@echo [nn] training classes $(CLASS_A) vs $(CLASS_B)
	$(PY) train.py --classes $(CLASS_A) $(CLASS_B) --out $(MODEL)

train: $(MODEL)

# --- 2. precision (informational) -----------------------------------------
# Reports how accuracy varies with precision, measured from the trained
# model's actual dynamic range. Does not gate the build; change PRECISION if
# the table says the default is wrong for your network.
precision: $(MODEL)
	$(PY) evaluate.py $(MODEL) $(CLASS_A) $(CLASS_B)

# --- 3. accelerator IP -----------------------------------------------------
$(IPDIR)/cnn_prj/solution1/impl/ip/component.xml: $(MODEL) sweep.py
	@echo [nn] generating HLS project, precision $(PRECISION) reuse $(RF)
	$(PY) sweep.py generate --model $(MODEL) --precision "$(PRECISION)" --rf $(RF)
	@echo [nn] synthesising and exporting IP, a few minutes
	cd $(IPDIR) && $(VITIS_RUN) --mode hls --tcl build_prj.tcl
	@$(VENVPY) -c "import sys,os;sys.exit(0 if os.path.isfile(sys.argv[1]) else print('IP export failed, missing:',sys.argv[1]) or 1)" $@

ip: $(IPDIR)/cnn_prj/solution1/impl/ip/component.xml

# --- 4. C headers ----------------------------------------------------------
# Phony rather than file targets: the output paths are outside this directory,
# and on Windows an absolute path in a target breaks make (see above).
# Regenerating costs a second, so there is nothing to gain from incrementality.
headers: $(MODEL) export_weights.py export_images.py
	$(PY) export_weights.py $(MODEL) --out $(SW)/weights.h
	$(PY) export_images.py --n $(N_IMAGES) --classes $(CLASS_A) $(CLASS_B) \
	    --model $(MODEL) --out $(SW)/images.h

# --- 5. software -----------------------------------------------------------
# NOT PORTED YET. examples/sw/bench.c, the APP= knob and the mif target all
# live on the cnn-accel branch and are written against the old SoC: an
# axi_uartlite at 0x6000_0000, an AXI GPIO for ap_start, and a stream FIFO
# that the driver stores 1,536 words into by hand. On this branch the UART,
# the interrupt controller and the whole peripheral bus are different, and
# the FIFO is being replaced by a DMA, so porting it is a rewrite of the
# driver rather than a merge. Until then this fails here, loudly, instead of
# failing three layers down in a cross-compile.
mif:
	@echo "[nn] 'mif' is not available on this branch yet."
	@echo "     examples/sw/bench.c is still written against the old SoC"
	@echo "     (axi_uartlite, AXI GPIO, axi_fifo_mm_s). It is ported after"
	@echo "     the DMA lands. 'make headers' works and is what you want in"
	@echo "     the meantime."
	@exit 1

# --- 6. hardware -----------------------------------------------------------
# package_as_ip_pynq_z2.tcl packages CVA5 itself; pynq_z2_nn_sys.tcl builds the
# SoC around it and the accelerator. Both run from the repo root because their
# paths are relative to it.
# NOT PORTED YET, for the same reason and one more: pynq_z2_nn_sys.tcl builds
# a block design out of IPs this branch has spent its whole life removing --
# axi_uartlite, an AXI Interconnect from apply_bd_automation, axi_gpio,
# xlconcat, xlconstant -- around a peripheral map at 0x6000_0000 that no
# longer exists. It is rewritten against pynq_z2_sys.tcl, not merged into it.
bitstream:
	@echo "[nn] 'bitstream' is not available on this branch yet."
	@echo "     pynq_z2_nn_sys.tcl targets the old SoC and is rewritten"
	@echo "     against examples/xilinx/pynq_z2_sys.tcl once the DMA and the"
	@echo "     lane select exist. 'make ip' works and is the step that"
	@echo "     matters now -- it reports the accelerator's stream width."
	@exit 1

# --- diagnostic ------------------------------------------------------------
# Builds the stock CVA5 SoC with no accelerator, using whatever IP and mem.mif
# are currently packaged. Same tools, same image, same board -- only the block
# design differs from `make bitstream`. Isolates a block-design fault from an
# environment one.
baseline:
	@echo "[nn] 'baseline' is not available on this branch yet."
	@echo "     Its job -- a CVA5 SoC with no accelerator, same tools and"
	@echo "     same image, to tell a block-design fault from an environment"
	@echo "     one -- is now just the main build:"
	@echo "       source ./examples/xilinx/pynq_z2_sys.tcl"
	@exit 1

# --- housekeeping ----------------------------------------------------------
# Cleanup goes through Python rather than rm: cmd.exe has no rm, and which
# shell GNU make picks on Windows depends on whether an sh.exe is on PATH.
RMTREE = $(VENVPY) -c "import shutil,sys,glob;[shutil.rmtree(p,ignore_errors=True) for a in sys.argv[1:] for p in glob.glob(a)]"
RMFILE = $(VENVPY) -c "import os,sys,glob;[os.remove(p) for a in sys.argv[1:] for p in glob.glob(a) if os.path.isfile(p)]"

clean:
	-$(RMTREE) "sw_*" "p_*" __pycache__
	-$(RMFILE) run_all.bat "$(SW)/weights.h" "$(SW)/images.h"

distclean: clean
	-$(RMTREE) $(VENV) data
	-$(RMFILE) "*.pt"
	-$(RMTREE) "$(REPO)/vivado"

help:
	@sed -n '2,32p' $(firstword $(MAKEFILE_LIST)) | sed 's/^#\s\?//'
