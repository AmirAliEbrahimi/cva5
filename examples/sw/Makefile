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
TIMER_SRCS := crt0.S trap.S timer.c puts.c
CSRS_SRCS := crt0.S trap.S csrs.c puts.c
PLIC_SRCS := crt0.S trap.S plic.c puts.c
SPI_SRCS  := crt0.S trap.S spi.c puts.c
I2C_SRCS  := crt0.S trap.S i2c.c puts.c
# Headers, as prerequisites. soc.h carries the memory map and the PLIC source
# numbers, so an image built against a stale copy of it talks to the wrong
# address or attributes an interrupt to the wrong device -- and nothing about
# the result says it was built before the header changed.
HDRS      := soc.h stdio.h mip.h mbox.h
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
ELF2C       := $(CVA5_DIR)/tools/elf-to-c-array.py
PS_DIR      := $(CVA5_DIR)/examples/ps
# Which program the Zynq PS's loader carries. Any of the examples works:
# they all link at APP_BASE as one contiguous image.
PS_APP      ?= timer.elf
# MBOX=1 tees every character puts.c writes into the mailbox in the top of
# main memory as well as to the UART, so the Zynq PS can print CVA5's output
# on the PS console. The board has one USB-UART and it belongs to the PS;
# without this, seeing CVA5's output needs an FTDI adapter on PMOD JA. It is a
# -D and nothing else -- the producer is static inlines in mbox.h, which
# puts.c includes, so no target's source list changes.
MBOX        ?=
ifeq ($(MBOX),1)
CFLAGS      += -DCVA5_MBOX
endif
OPENOCD     ?= openocd
OCD_DIR     := $(CVA5_DIR)/examples/xilinx/openocd

.PHONY: all program ram app load memtest timer csrs run-csrs plic spi sim run clean lint lint-full clean-cva5-sim ps-image
all: program
program: program.hex

# The sim image is a different SoC: its UART sits in the peripheral range that
# upstream's EXAMPLE_CONFIG declares, not at the board's address. soc.h keeps
# both and CVA5_SIM picks. See the note in soc.h.
main.elf: $(SRCS) $(HDRS) $(LDSCRIPT)
	$(CC) $(CFLAGS) -DCVA5_SIM -T $(LDSCRIPT) $(SRCS) -lgcc -o $@

program.hex: main.elf
	python3 $(ELF2HW) $(CROSS) $(BASE_ADDR) $(RAM_SIZE) $< program.hex program.sim

ram: ram.mif
app: app.elf

# The preload parks in a loop and prints nothing, so a board that has just been
# programmed is silent and the UART carries only what you load. Point this at
# another program if you want the board to come up doing something.
IDLE_SRCS := idle.S trap.S

idle.elf: $(IDLE_SRCS) $(HDRS) $(APP_LDSCRIPT)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -Wl,--build-id=none \
	      -T $(APP_LDSCRIPT) $(IDLE_SRCS) -o $@

ram.mif: idle.elf
	python3 $(ELF2HW) $(CROSS) $(APP_BASE) $$(( $(RAM_WORDS) * 4 )) $< ram.mif ram.sim

app.elf: $(SRCS) $(HDRS) $(APP_LDSCRIPT)
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
memtest.elf: $(MEMTEST_SRCS) $(HDRS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(MEMTEST_SRCS) -lgcc -o $@

memtest.tcl: memtest.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

memtest: memtest.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f memtest.tcl -c "init; load_program; shutdown"

# The CLINT check: mtime's tick rate, mtimecmp -> mtip, and msip. Polled, so it
# needs no interrupt handler; prints on the serial console like memtest.
timer.elf: $(TIMER_SRCS) $(HDRS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(TIMER_SRCS) -lgcc -o $@

timer.tcl: timer.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

timer: timer.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f timer.tcl -c "init; load_program; shutdown"

# Which of Zicntr's counters this core implements: cycle and instret from the
# core, time/timeh trapping because the count lives in the CLINT. Brings its
# own trap handler, since trap.S's parks by design. Prints on the serial
# console like memtest. Fails under QEMU on purpose -- see csrs.c.
csrs.elf: $(CSRS_SRCS) $(HDRS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(CSRS_SRCS) -lgcc -o $@

csrs.tcl: csrs.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

csrs: csrs.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f csrs.tcl -c "init; load_program; shutdown"

# The PLIC on hardware. Interactive: it waits for a keypress on the serial
# console, because the UART's receive interrupt is the only source wired and
# nothing in software can raise it.
plic.elf: $(PLIC_SRCS) $(HDRS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(PLIC_SRCS) -lgcc -o $@

plic.tcl: plic.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

plic: plic.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f plic.tcl -c "init; load_program; shutdown"

# The SPI on hardware. The register checks need nothing attached; the loopback
# part needs MOSI jumpered to MISO on the ICSP header, and says so.
spi.elf: $(SPI_SRCS) $(HDRS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(SPI_SRCS) -lgcc -o $@

spi.tcl: spi.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

spi: spi.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f spi.tcl -c "init; load_program; shutdown"

# The I2C on hardware. The register checks need nothing attached; the bus scan
# is the only part that proves the pins, and it needs a device on the Arduino
# header's SCL/SDA. It says so when it finds nothing.
i2c.elf: $(I2C_SRCS) $(HDRS) $(APP_LDSCRIPT)
	$(CC) $(CFLAGS) -T $(APP_LDSCRIPT) $(I2C_SRCS) -lgcc -o $@

i2c.tcl: i2c.elf
	python3 $(ELF2TCL) $(CROSS) $(APP_BASE) $< $@

i2c: i2c.tcl
	$(OPENOCD) -f $(OCD_DIR)/pynq-z2-jtag.cfg -f $(OCD_DIR)/cva5-pynq-z2-p1.cfg \
	           -f i2c.tcl -c "init; load_program; shutdown"

# The same test in the Verilator core sim, which is the only place the core's
# CSR behaviour can be checked without a bitstream -- and the only place both
# polarities of INCLUDE_TIME_CSR can be run, since the sim takes upstream's
# EXAMPLE_CONFIG. With that bit set, "rdtime traps" is expected to FAIL: the
# sim drives mtime and the CSR is implemented there. Clear it in
# core/types_and_interfaces/cva5_config.sv and every check passes.
csrs_sim.elf: $(CSRS_SRCS) $(HDRS) $(LDSCRIPT)
	$(CC) $(CFLAGS) -DCVA5_SIM -T $(LDSCRIPT) $(CSRS_SRCS) -lgcc -o $@

csrs.hex: csrs_sim.elf
	python3 $(ELF2HW) $(CROSS) $(BASE_ADDR) $(RAM_SIZE) $< csrs.hex csrs.sim

run-csrs: csrs.hex sim
	$(SIM_BIN) csrs_log.txt csrs_sig.txt csrs.hex csrs_trace.fst

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

# The image examples/ps/cva5_load.c carries, as a C word array. The PS writes
# it into main memory over M_AXI_GP1 -- the same thing 'make load' does over
# JTAG, from the other side of the board.
ps-image: $(PS_APP)
	python3 $(ELF2C) $(CROSS) $< $(PS_DIR)/cva5_image.c

clean:
	rm -f main.elf program.hex program.sim \
	      app.elf load.tcl idle.elf ram.sim \
	      *.elf.bin \
	      memtest.elf memtest.tcl \
	      timer.elf timer.tcl \
	      csrs.elf csrs.tcl csrs_sim.elf csrs.hex csrs.sim csrs_log.txt csrs_sig.txt csrs_trace.fst \
	      plic.elf plic.tcl spi.elf spi.tcl i2c.elf i2c.tcl \
	      main.elf.rawbinary main.elf.dissasembled \
	      idle.elf.rawbinary idle.elf.dissasembled \
		  trace.fst.hier \
	      $(LOG) $(SIG) $(TRACE) $(PS_DIR)/cva5_image.c
# Note: ram.mif is NOT removed here — the bitstream is built from it, so
# losing it would mean a Vivado rebuild. `make ram` regenerates it.
