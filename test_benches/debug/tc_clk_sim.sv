// Simulation stand-ins for the two tech_cells_generic clock cells that
// riscv-dbg's dmi_jtag_tap instantiates. The board build uses the BSCANE2 DTM
// and never needs these, so vendoring the whole tech_cells_generic repo for
// two behavioural cells would be overkill.
module tc_clk_inverter (input logic clk_i, output logic clk_o);
    assign clk_o = ~clk_i;
endmodule

module tc_clk_mux2 (input logic clk0_i, input logic clk1_i, input logic clk_sel_i, output logic clk_o);
    assign clk_o = clk_sel_i ? clk1_i : clk0_i;
endmodule
