# ============================================================================
#  examples/sw/Makefile
#  Front-end for the CVA5 example software + the Verilator simulator.
#
#  Software targets (this makefile):
#    make / make program   build program.hex (sim image) from main.c
#    make boot             build boot.mif, the FPGA boot ROM image
#    make app              build app.elf, linked for main RAM at 0x4000_0000
#    make load             build app.elf and load it onto the board over JTAG
#                          (no bitstream rebuild; see examples/xilinx/openocd)
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
#    make CROSS=riscv32-unknown-elf-        (toolchain prefix)
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

# --- toolchain (the Ubuntu gcc-riscv64-unknown-elf package works) ----------
CROSS     ?= riscv64-unknown-elf-
CC        := $(CROSS)gcc

# --- target memory: must match the sim (SimMem/AXIMem STARTING_ADDR, 4 KB) --
BASE_ADDR ?= 0x80000000
RAM_SIZE  ?= 4096
ARCH      ?= rv32im
ABI       ?= ilp32

# --- build inputs ----------------------------------------------------------
SRCS      := crt0.S main.c puts.c
LDSCRIPT  := link.ld
CFLAGS    := -march=$(ARCH) -mabi=$(ABI) -Os -ffreestanding -nostdlib -I. -Wl,--build-id=none

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

# --- FPGA: boot ROM + application in main RAM ------------------------------
# The boot ROM is baked into the bitstream and only jumps to the application.
# The application lives in AXI BRAM and is loaded by the debugger over SBA, so
# changing software never needs a Vivado rebuild.
BOOT_BASE   ?= 0x80000000
BOOT_SIZE   ?= 1024
APP_BASE    ?= 0x40000000
APP_LDSCRIPT := fpga_link.ld
ELF2TCL     := $(CVA5_DIR)/tools/elf-to-load-tcl.py
OPENOCD     ?= openocd
OCD_DIR     := $(CVA5_DIR)/examples/xilinx/openocd

.PHONY: all program boot app load sim run clean lint lint-full clean-cva5-sim
all: program
program: program.hex

main.elf: $(SRCS) $(LDSCRIPT)
	$(CC) $(CFLAGS) -T $(LDSCRIPT) $(SRCS) -lgcc -o $@

program.hex: main.elf
	python3 $(ELF2HW) $(CROSS) $(BASE_ADDR) $(RAM_SIZE) $< program.hex program.sim

boot: boot.mif
app: app.elf

boot.elf: boot.S boot_link.ld
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -Wl,--build-id=none -T boot_link.ld boot.S -o $@

boot.mif: boot.elf
	python3 $(ELF2HW) $(CROSS) $(BOOT_BASE) $(BOOT_SIZE) $< boot.mif boot.sim

app.elf: $(SRCS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(SRCS) -lgcc -o $@

load.tcl: app.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

# Hold the CPU, write the image over System Bus Access, verify, release.
load: load.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f load.tcl -c "init; load_program; shutdown"

# Build the Verilator model. tools/cva5.mak's default target is 'lint', so we
# must name the binary explicitly; CVA5_DIR is required by that makefile.
sim: $(SIM_BIN)
$(SIM_BIN):
	$(CVA5_MAK) $(SIM_BIN)

# Forward the upstream sim makefile's own targets verbatim (no duplication).
lint lint-full clean-cva5-sim:
	$(CVA5_MAK) $@

run: program.hex sim
	$(SIM_BIN) $(LOG) $(SIG) program.hex $(TRACE)

clean:
	rm -f main.elf program.hex program.sim \
	      app.elf app.elf.bin load.tcl boot.elf boot.sim \
	      main.elf.rawbinary main.elf.dissasembled \
		  trace.fst.hier \
	      $(LOG) $(SIG) $(TRACE)
# Note: boot.mif is NOT removed here — the bitstream is built from it, so
# losing it would mean a Vivado rebuild. `make boot` regenerates it.
