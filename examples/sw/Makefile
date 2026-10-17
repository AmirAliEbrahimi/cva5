# ============================================================================
#  examples/sw/Makefile
#  Front-end for the CVA5 example software + the Verilator simulator.
#
#  Software targets (this makefile):
#    make / make program   build program.hex (sim image) from main.c
#    make ram              build ram.mif, the image the bitstream preloads
#    make app              build app.elf, linked for main RAM at 0x8000_0000
#    make load             build app.elf and load it onto the board over JTAG
#                          (no bitstream rebuild; see examples/xilinx/openocd)
#    make memtest          build and run the main RAM test on the board. The
#                          only thing that addresses all 128 KB; the result
#                          appears on the serial console, not here.
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
SRCS      := crt0.S trap.S main.c puts.c
MEMTEST_SRCS := crt0.S trap.S memtest.c puts.c
LDSCRIPT  := link.ld
CFLAGS    := -march=$(ARCH) -mabi=$(ABI) -Os -g -ffreestanding -nostdlib -I. -Wl,--build-id=none

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

# --- FPGA: main RAM image and the application ------------------------------
# Main memory is 128 KB of block RAM inside the core at 0x8000_0000. The reset
# vector points 0x40 above its base -- crt0.S puts the trap handler in those
# first 64 bytes, because the Debug Module now sits at address zero and a trap
# can no longer be left to go there. fpga_link.ld asserts the layout.
#
# ram.mif is the image the bitstream preloads, so a freshly programmed board
# runs something without a debugger attached. `make load` then writes a
# different program over JTAG and never needs a Vivado rebuild -- the preload
# only decides what runs before the first load.
RAM_WORDS   ?= 32768
APP_BASE    ?= 0x80000000
APP_LDSCRIPT := fpga_link.ld
ELF2TCL     := $(CVA5_DIR)/tools/elf-to-load-tcl.py
OPENOCD     ?= openocd
OCD_DIR     := $(CVA5_DIR)/examples/xilinx/openocd

.PHONY: all program ram app load memtest sim run clean lint lint-full clean-cva5-sim
all: program
program: program.hex

# The sim image is a different SoC: its UART sits in the peripheral range that
# upstream's EXAMPLE_CONFIG declares, not at the board's address. soc.h keeps
# both and CVA5_SIM picks. See the note in soc.h.
main.elf: $(SRCS) $(LDSCRIPT)
	$(CC) $(CFLAGS) -DCVA5_SIM -T $(LDSCRIPT) $(SRCS) -lgcc -o $@

program.hex: main.elf
	python3 $(ELF2HW) $(CROSS) $(BASE_ADDR) $(RAM_SIZE) $< program.hex program.sim

ram: ram.mif
app: app.elf

# The preload parks in a loop and prints nothing, so a board that has just been
# programmed is silent and the UART carries only what you load. Point this at
# another program if you want the board to come up doing something.
IDLE_SRCS := idle.S trap.S

idle.elf: $(IDLE_SRCS) $(APP_LDSCRIPT)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -Wl,--build-id=none \
	      -T $(APP_LDSCRIPT) $(IDLE_SRCS) -o $@

ram.mif: idle.elf
	python3 $(ELF2HW) $(CROSS) $(APP_BASE) $$(( $(RAM_WORDS) * 4 )) $< ram.mif ram.sim

app.elf: $(SRCS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(SRCS) -lgcc -o $@

load.tcl: app.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

# Hold the CPU, write the image over System Bus Access, verify, release.
load: load.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f load.tcl -c "init; load_program; shutdown"

# Main RAM test. Same flow as 'load', different image: the test runs on the
# CPU once the debugger releases it, so the pass or fail line comes out on the
# serial console and this target only reports the load.
memtest.elf: $(MEMTEST_SRCS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(MEMTEST_SRCS) -lgcc -o $@

memtest.tcl: memtest.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

memtest: memtest.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f memtest.tcl -c "init; load_program; shutdown"

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
	      app.elf app.elf.bin load.tcl idle.elf ram.sim \
	      memtest.elf memtest.tcl \
	      main.elf.rawbinary main.elf.dissasembled \
		  trace.fst.hier \
	      $(LOG) $(SIG) $(TRACE)
# Note: ram.mif is NOT removed here — the bitstream is built from it, so
# losing it would mean a Vivado rebuild. `make ram` regenerates it.
