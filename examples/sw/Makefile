# ============================================================================
#  examples/sw/Makefile
#  Front-end for the CVA5 example software + the Verilator simulator.
#
#  Software targets (this makefile):
#    make / make program   build program.hex (sim image) from main.c
#    make mif              build mem.mif (FPGA block-RAM image) only
#    make run             build program.hex + sim, then run the sim
#    make clean           remove generated software files
#
#  Simulator targets (forwarded verbatim to tools/cva5.mak):
#    make sim             build the Verilator model
#    make lint            lint the RTL
#    make lint-full       lint the RTL with -Wall
#    make clean-cva5-sim  remove the simulator build directory
#
#  Override knobs on the command line, e.g.:
#    make mif APP=bench                     (build the NN accelerator benchmark
#                                            instead of the main.c demo)
#    make CROSS=riscv32-unknown-elf-        (toolchain prefix)
#    make PYTHON=python                     (interpreter; defaults to python3,
#                                            or python on Windows)
#    make sim TRACE_ENABLE=False            (no waveform, faster build)
#    make sim DETERMINISTIC=1               (deterministic AXI DDR)
#    make run TRACE=mytrace.fst
#
#  This file does NOT reimplement tools/cva5.mak; sim/lint/clean-cva5-sim are
#  delegated to it so there is a single source of truth for the RTL build.
# ============================================================================

# --- repo paths (this file lives in examples/sw) ---------------------------
CVA5_DIR  := $(abspath $(CURDIR)/../..)
SIM_DIR   := $(CVA5_DIR)/test_benches/verilator
SIM_BIN   := $(SIM_DIR)/build/cva5-sim
ELF2HW    := $(CVA5_DIR)/tools/elf-to-hw-init.py

# Relative form of SIM_BIN, used wherever it appears as a make target. An
# absolute Windows path (D:/...) in a target or prerequisite makes GNU make
# read the drive colon as the target/prereq separator and abort -- and it does
# so while parsing, so it breaks every target, not just the simulator ones.
SIM_BIN_REL := ../../test_benches/verilator/build/cva5-sim

# --- toolchain (the Ubuntu gcc-riscv64-unknown-elf package works) ----------
CROSS     ?= riscv64-unknown-elf-
CC        := $(CROSS)gcc

# Windows installs usually provide "python", not "python3".
ifeq ($(OS),Windows_NT)
PYTHON    ?= python
else
PYTHON    ?= python3
endif

# --- target memory ---------------------------------------------------------
# RAM_SIZE must equal WORDS * 4 from examples/xilinx/cva5_wrapper.sv and
# cva5_top.v, and LENGTH in link.ld. All four have to agree or the generated
# mem.mif is silently the wrong length. The Verilator sim is unaffected: its
# SimMem is a sparse map, not a fixed array.
BASE_ADDR ?= 0x80000000
RAM_SIZE  ?= 65536
ARCH      ?= rv32im
ABI       ?= ilp32

# --- build inputs ----------------------------------------------------------
# APP=main  (default) the hello-world demo
# APP=bench the CNN accelerator benchmark. Needs weights.h and images.h, which
#           tools/nn_accel/export_weights.py and export_images.py generate, and
#           printf.c for formatted output (puts.c alone is not enough).
APP       ?= main
SRCS      := crt0.S $(APP).c puts.c
ifeq ($(APP),bench)
SRCS      += printf.c
endif
LDSCRIPT  := link.ld
# --build-id=none: the Xilinx riscv32-xilinx-elf toolchain defaults to
# emitting an ALLOC+LOAD .note.gnu.build-id, which the linker places ahead of
# .text -- on CVA5's reset vector. link.ld also discards it; this stops it
# being produced at all.
CFLAGS    := -march=$(ARCH) -mabi=$(ABI) -Os -ffreestanding -nostdlib -I. \
             -Wl,--build-id=none

# --- sim run arguments (positional: log, signature, program, trace) --------
LOG       ?= program_log.txt
SIG       ?= signature.txt
TRACE     ?= trace.fst

# --- knobs forwarded to tools/cva5.mak (the canonical simulator build) ------
TRACE_ENABLE  ?= True
DETERMINISTIC ?= 0
# Single delegation command: runs the upstream sim makefile with everything it
# needs. Command-line values above override cva5.mak's own defaults.
CVA5_MAK = $(MAKE) -C $(CVA5_DIR) -f tools/cva5.mak \
           CVA5_DIR=$(CVA5_DIR) TRACE_ENABLE=$(TRACE_ENABLE) DETERMINISTIC=$(DETERMINISTIC)

.PHONY: all program mif sim run clean lint lint-full clean-cva5-sim
all: program
program: program.hex
mif: mem.mif       # FPGA block-RAM init only (no simulator)

main.elf: $(SRCS) $(LDSCRIPT)
	$(CC) $(CFLAGS) -T $(LDSCRIPT) $(SRCS) -lgcc -o $@

program.hex: main.elf
	$(PYTHON) $(ELF2HW) $(CROSS) $(BASE_ADDR) $(RAM_SIZE) $< program.hex program.sim

# FPGA block-RAM image. Same one-word-per-line format as program.hex; this is
# the file cva5_top loads via its LOCAL_MEM parameter. Overwrites the committed
# examples/sw/mem.mif in place (use git to revert if needed).
mem.mif: main.elf
	$(PYTHON) $(ELF2HW) $(CROSS) $(BASE_ADDR) $(RAM_SIZE) $< mem.mif mem.sim

# Build the Verilator model. tools/cva5.mak's default target is 'lint', so we
# must name the binary explicitly; CVA5_DIR is required by that makefile.
sim: $(SIM_BIN_REL)
$(SIM_BIN_REL):
	$(CVA5_MAK) $(SIM_BIN)

# Forward the upstream sim makefile's own targets verbatim (no duplication).
lint lint-full clean-cva5-sim:
	$(CVA5_MAK) $@

run: program.hex sim
	$(SIM_BIN) $(LOG) $(SIG) program.hex $(TRACE)

clean:
	rm -f main.elf program.hex program.sim mem.sim \
	      main.elf.rawbinary main.elf.dissasembled \
		  trace.fst.hier \
	      $(LOG) $(SIG) $(TRACE)
# Note: mem.mif is intentionally NOT removed here — it is a committed source
# file. `make mif` overwrites it; use git to restore the original if needed.
