// Simulation-only stub for the Xilinx BSCANE2 primitive. The JTAG side is not
// exercised by tb_sys; this just lets the debug subsystem elaborate.
module BSCANE2 #(parameter DISABLE_JTAG = "FALSE", parameter integer JTAG_CHAIN = 1) (
    output CAPTURE, DRCK, RESET, RUNTEST, SEL, SHIFT, TCK, TDI, TMS, UPDATE, input TDO);
    assign {CAPTURE, DRCK, RESET, RUNTEST, SEL, SHIFT, TCK, TDI, TMS, UPDATE} = '0;
endmodule
