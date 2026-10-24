// Simulation model of the Xilinx IOBUF primitive, so that a Verilator bench
// can elaborate RTL that instantiates one.
//
// Unlike test_benches/debug/BSCANE2_stub.v, which ties its outputs off because
// nothing exercises them, this one is a real model and has to be: the whole
// point of cva5_i2c_axi's buffers is the released state, and a stub that drove
// the line would hide exactly the bug the explicit IOBUF exists to prevent.
//
// The behaviour is the primitive's, from UG953: T high releases the pin and
// the output follows whatever else is driving it, T low drives I onto it, and
// O always follows the pin.
//
// Keeping the buffer in the design rather than behind a simulation-only branch
// is what lets tb_i2c test the same structure synthesis builds. It does not
// check that Vivado keeps the real IOBUF -- the packaging log does that, by not
// reporting Synth 8-5799.
//
// SPDX-License-Identifier: Apache-2.0

module IOBUF #(
    parameter integer DRIVE = 12,
    parameter IBUF_LOW_PWR = "TRUE",
    parameter IOSTANDARD = "DEFAULT",
    parameter SLEW = "SLOW"
) (
    output O,
    inout  IO,
    input  I,
    input  T
);

    assign IO = T ? 1'bz : I;
    assign O  = IO;

endmodule
