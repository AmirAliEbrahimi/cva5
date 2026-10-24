/*
 * cva5_irq_concat -- separate interrupt lines into the vector a PLIC takes.
 *
 * This exists for one reason. A block design connects a net to a whole pin, so
 * two devices' irq outputs cannot be attached to two bits of cva5_plic_axi's
 * irq_srcs; Vivado's answer is xlconcat, and removing Xilinx IPs is the point
 * of the exercise. This is the same thing, in one assignment, as an IP of our
 * own.
 *
 * Ports are named by PLIC source number rather than by bit index, because the
 * source number is what software uses and the two differ: RISC-V reserves
 * source 0 for "no interrupt", so irq_srcs[0] is source 1. cva5_plic_axi's own
 * header says the same thing from the other side.
 *
 * Keep examples/sw/soc.h's PLIC_SRC_* in step with the order here. Two sources
 * swapped is invisible in synthesis, costs nothing in area or timing, and
 * shows up on hardware as a device whose interrupt is attributed to another
 * one -- test_benches/axi/tb_irq_concat.sv drives this block into a real PLIC
 * and claims each source by number for that reason.
 *
 * Fixed at two inputs, which is what the board has: the UART's receive
 * interrupt and the SPI's end-of-transfer. A third device means a port here, a
 * line in the block design and NUM_SOURCES 3 on the PLIC -- cheaper than a
 * parameter whose unused inputs a block design would have to tie off, which on
 * a block design means a Xilinx constant block.
 *
 * Combinational and clockless on purpose. There is no state, so there is
 * nothing for ndmreset to hold down on a path the debugger uses, and the two
 * device interrupts reach the PLIC in the same cycle they are raised.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_irq_concat (
    input  logic       src1,      //PLIC source 1 -- irq_srcs[0]
    input  logic       src2,      //PLIC source 2 -- irq_srcs[1]
    output logic [1:0] irq_srcs
);

    assign irq_srcs = {src2, src1};

endmodule
