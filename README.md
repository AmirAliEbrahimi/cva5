# CVA5

CVA5 is a 32-bit RISC-V processor designed for FPGAs, supporting the Multiply/Divide,
Atomic, and Floating-Point extensions (**RV32IMAFD**). It is written in SystemVerilog and
designed to be both highly extensible and highly configurable. The pipeline supports
parallel, variable-latency execution units and is structured to make adding new execution
units straightforward.

CVA5 is derived from the Taiga Project from Simon Fraser University.

Below is the complete architecture of **CVA5**; configurable components are highlighted with
red dashed rectangles. For more details, see the [FCCM presentation](docs/FCCM_Presentation)
in the `docs` directory.

<img src="docs/FCCM_Presentation/CVA5.png"/>

> **About this fork:** this fork tracks upstream
> [`openhwgroup/cva5`](https://github.com/openhwgroup/cva5) and adds a self-contained build
> wrapper for the Verilator simulator and the example software, so you can go from a clean
> clone to a running simulation with a couple of `make` targets. See
> [Quick Start: Simulation](#quick-start-simulation) below and
> [`examples/sw/README.build.md`](examples/sw/README.build.md).

## Quick Start: Simulation

This builds the Verilator model of CVA5, compiles the example C program, and runs it on
the simulator.

### Prerequisites (Ubuntu / WSL)

```bash
sudo apt-get install -y verilator zlib1g-dev gcc-riscv64-unknown-elf
```

- **verilator** + **zlib1g-dev** — to build the simulator. The zlib development *headers*
  are required because waveform tracing is enabled (`--trace-fst` pulls in GTKWave's
  `fstapi.h`, which `#include`s `<zlib.h>`).
- **gcc-riscv64-unknown-elf** — bare-metal RISC-V GCC. This package ships without a C
  library, so the example is built freestanding with its own startup and `puts`.

### Build and run

```bash
cd examples/sw
make sim     # build the simulator -> test_benches/verilator/build/cva5-sim
make run     # compile main.c, convert to a memory image, and run it on the sim
```

`make run` launches the simulator with the four positional arguments it requires:

```
cva5-sim <log_file> <signature_file> <program_file> <trace_file>
```

It produces `program_log.txt` (a capture of the UART console output), `signature.txt`, and
`trace.fst` (open with GTKWave or Surfer). The example prints `Hello World!` in a loop.

### How the pieces fit

- The program is built for **RV32IM** and linked at **`0x80000000`**, the base address the
  simulator's memory model (`SimMem`/`AXIMem`) loads from, with a **4 KB** memory.
- The simulation stops when the core retires `0x00a00013` (`addi x0,x0,10`), the
  "success termination" instruction the testbench watches for. The example's startup
  (`crt0.S`) executes it after `main()` returns; without it the run never ends and the
  buffered log is never flushed.
- The example loops forever with a one-second busy-wait between prints. At RTL-simulation
  speed (slower still with tracing on) that is a long wait between lines — to iterate
  faster, shrink the delay in `main.c` or make the loop finite so the run terminates.

Full details, target descriptions, and customization (e.g. a different toolchain prefix via
`make CROSS=...`) are in [`examples/sw/README.build.md`](examples/sw/README.build.md).

### Linting only

The RTL can be linted without building the simulator or any software:

```bash
make -f tools/cva5.mak CVA5_DIR="$PWD" lint        # quick lint
make -f tools/cva5.mak CVA5_DIR="$PWD" lint-full   # lint with -Wall
```

## Documentation and Project Setup

For up-to-date upstream documentation and an automated build environment (toolchain,
test suites, and more), refer to the [Taiga Project](https://gitlab.com/sfu-rcl/taiga-project).
The Quick Start above is a lightweight alternative for building and running the bundled
Verilator simulation directly.

## License

CVA5 is licensed under the Solderpad License, Version 2.1
(http://solderpad.org/licenses/SHL-2.1/). Solderpad is an extension of the Apache License,
and many contributions to CVA5 were made under Apache Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0).

## Examples

A script to package CVA5 as an IP is available and can be run in Vivado with
`source ./examples/xilinx/package_as_ip.tcl`. A companion script can then create a system
running a small hello-world application from block memory on the Nexys A7 FPGA.

For detailed instructions on executing the hello-world application from block memory on the PYNQ-Z2 FPGA, please review `examples\xilinx\README.pynq_z2.md`. Tested with Vivado 2025.1

## Publications

C. Keilbart, Y. Gao, M. Chua, E. Matthews, S. J. Wilton, and L. Shannon, "Designing an
IEEE-Compliant FPU that Supports Configurable Precision for Soft Processors," ACM Trans.
Reconfigurable Technol. Syst., vol. 17, no. 2, Apr. 2024.
doi: [https://doi.org/10.1145/3650036](https://doi.org/10.1145/3650036)

E. Matthews, A. Lu, Z. Fang and L. Shannon, "Rethinking Integer Divider Design for
FPGA-Based Soft-Processors," 2019 IEEE 27th Annual International Symposium on
Field-Programmable Custom Computing Machines (FCCM), San Diego, CA, USA, 2019, pp. 289-297.
doi: [https://doi.org/10.1109/FCCM.2019.00046](https://doi.org/10.1109/FCCM.2019.00046)

E. Matthews, Z. Aguila and L. Shannon, "Evaluating the Performance Efficiency of a
Soft-Processor, Variable-Length, Parallel-Execution-Unit Architecture for FPGAs Using the
RISC-V ISA," 2018 IEEE 26th Annual International Symposium on Field-Programmable Custom
Computing Machines (FCCM), Boulder, CO, 2018, pp. 1-8.
doi: [https://doi.org/10.1109/FCCM.2018.00010](https://doi.org/10.1109/FCCM.2018.00010)

E. Matthews and L. Shannon, "TAIGA: A new RISC-V soft-processor framework enabling high
performance CPU architectural features," 2017 27th International Conference on Field
Programmable Logic and Applications (FPL), Ghent, Belgium, 2017.
doi: [https://doi.org/10.23919/FPL.2017.8056766](https://doi.org/10.23919/FPL.2017.8056766)
