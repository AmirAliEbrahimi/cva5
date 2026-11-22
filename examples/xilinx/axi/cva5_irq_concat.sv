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
 * Three inputs: the UART's receive interrupt, the SPI's end-of-transfer, and
 * the accelerator's result-ready. The third is optional, because the
 * accelerator is -- pynq_z2_sys.tcl only instantiates it when the hls4ml IP
 * has been generated -- and HAS_SRC3 is how that is said.
 *
 * The parameter zeroes the BIT rather than removing the PORT, which is the
 * part worth explaining. A block design connects nets, and the only way to
 * hold a pin low without a net is Xilinx's xlconstant, which is the kind of
 * IP this tree exists to remove. So irq_srcs is three bits either way, the
 * PLIC is always built with NUM_SOURCES 3, and with HAS_SRC3 0 the zero comes
 * from in here where it costs nothing. The src3 pin is then ignored, and the
 * block design ties it to a real net so that nothing floats -- an unconnected
 * input is a synthesis warning, and this tree does not carry those.
 *
 * Keep examples/sw/soc.h's PLIC_SRC_* in step with the order here. Two
 * sources swapped is invisible in synthesis, costs nothing in area or timing,
 * and shows up on hardware as a device whose interrupt is attributed to
 * another one -- test_benches/axi/tb_irq_concat.sv drives this block into a
 * real PLIC and claims each source by number for that reason.
 *
 * Combinational and clockless on purpose. There is no state, so there is
 * nothing for ndmreset to hold down on a path the debugger uses, and the
 * device interrupts reach the PLIC in the same cycle they are raised.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_irq_concat #(
    //1 when the accelerator is in the design and src3 is its interrupt.
    //0 when it is not: src3 is ignored and irq_srcs[2] is held low.
    parameter bit HAS_SRC3 = 1'b0
) (
    input  logic       src1,      //PLIC source 1 -- irq_srcs[0]
    input  logic       src2,      //PLIC source 2 -- irq_srcs[1]
    input  logic       src3,      //PLIC source 3 -- irq_srcs[2], if HAS_SRC3
    output logic [2:0] irq_srcs
);

    assign irq_srcs = {HAS_SRC3 ? src3 : 1'b0, src2, src1};

endmodule
