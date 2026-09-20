/*
 * cva5_debug_subsys -- RISC-V External Debug Support (spec 0.13.2) for CVA5
 * using pulp-platform/riscv-dbg:
 *   dmi_jtag (DTM, BSCANE2 USER3/USER4 variant) -> dm_top (DM) -> SBA -> AXI4-Lite
 *
 * P1: the core is not yet debug-capable, so HART_AVAILABLE=0 marks hart 0
 *     unavailable and debug_req/the slave port are left for P2. What works in
 *     P1: DMI transport, ndmreset (holds the CPU in reset) and System Bus Access.
 *
 * Licensed under the Apache License, Version 2.0.
 */
module cva5_debug_subsys #(
    parameter int unsigned DM_BASE_ADDR   = 32'h5000_0000,
    parameter bit          HART_AVAILABLE = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,          // power-on / board reset, NOT ndmreset

    output logic        ndmreset,       // resets CPU (and optionally peripherals)
    output logic        debug_req,      // to CPU (P2)

    // DM memory slave: debug ROM, program buffer, abstract data (P2)
    input  logic        dm_req,
    input  logic        dm_we,
    input  logic [31:0] dm_addr,
    input  logic [3:0]  dm_be,
    input  logic [31:0] dm_wdata,
    output logic [31:0] dm_rdata,

    // System Bus Access, AXI4-Lite master
    output logic [31:0] m_axi_awaddr,
    output logic [2:0]  m_axi_awprot,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [31:0] m_axi_araddr,
    output logic [2:0]  m_axi_arprot,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready
);

    ////////////////////////////////////////////////////
    // DTM: JTAG via the FPGA's own TAP (BSCANE2), CDC'd into clk
    dm::dmi_req_t  dmi_req;
    dm::dmi_resp_t dmi_resp;
    logic dmi_req_valid, dmi_req_ready, dmi_resp_valid, dmi_resp_ready, dmi_rst_n;

    dmi_jtag i_dmi_jtag (
        .clk_i            (clk),
        .rst_ni           (rst_n),
        .testmode_i       (1'b0),
        .dmi_rst_no       (dmi_rst_n),
        .dmi_req_o        (dmi_req),
        .dmi_req_valid_o  (dmi_req_valid),
        .dmi_req_ready_i  (dmi_req_ready),
        .dmi_resp_i       (dmi_resp),
        .dmi_resp_ready_o (dmi_resp_ready),
        .dmi_resp_valid_i (dmi_resp_valid),
        // Unused with dmi_bscane_tap: the TAP comes from BSCANE2
        .tck_i            (1'b0),
        .tms_i            (1'b0),
        .trst_ni          (1'b1),
        .td_i             (1'b0),
        .td_o             (),
        .tdo_oe_o         ()
    );

    ////////////////////////////////////////////////////
    // Debug Module
    localparam dm::hartinfo_t HARTINFO = '{
        zero1      : '0,
        nscratch   : 4'd2,               // dscratch0/1 (needed for non-zero DM base)
        zero0      : '0,
        dataaccess : 1'b1,
        datasize   : dm::DataCount,
        dataaddr   : dm::DataAddr
    };

    logic        sba_req, sba_we, sba_gnt, sba_rvalid, sba_rerr;
    logic [31:0] sba_addr, sba_wdata, sba_rdata;
    logic [3:0]  sba_be;
    logic        ndmreset_q;

    dm_top #(
        .NrHarts       (1),
        .BusWidth      (32),
        .DmBaseAddress (DM_BASE_ADDR)
    ) i_dm_top (
        .clk_i                (clk),
        .rst_ni               (rst_n),
        .next_dm_addr_i       (32'h0),
        .testmode_i           (1'b0),
        .ndmreset_o           (ndmreset),
        .ndmreset_ack_i       (ndmreset_q & ~ndmreset), // pulse when ndmreset releases
        .dmactive_o           (),
        .debug_req_o          (debug_req),
        .unavailable_i        (~HART_AVAILABLE),
        .hartinfo_i           (HARTINFO),

        .slave_req_i          (dm_req),
        .slave_we_i           (dm_we),
        .slave_addr_i         (dm_addr),
        .slave_be_i           (dm_be),
        .slave_wdata_i        (dm_wdata),
        .slave_rdata_o        (dm_rdata),

        .master_req_o         (sba_req),
        .master_add_o         (sba_addr),
        .master_we_o          (sba_we),
        .master_wdata_o       (sba_wdata),
        .master_be_o          (sba_be),
        .master_gnt_i         (sba_gnt),
        .master_r_valid_i     (sba_rvalid),
        .master_r_err_i       (sba_rerr),
        .master_r_other_err_i (1'b0),
        .master_r_rdata_i     (sba_rdata),

        .dmi_rst_ni           (dmi_rst_n),
        .dmi_req_valid_i      (dmi_req_valid),
        .dmi_req_ready_o      (dmi_req_ready),
        .dmi_req_i            (dmi_req),
        .dmi_resp_valid_o     (dmi_resp_valid),
        .dmi_resp_ready_i     (dmi_resp_ready),
        .dmi_resp_o           (dmi_resp)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) ndmreset_q <= 1'b0;
        else        ndmreset_q <= ndmreset;
    end

    ////////////////////////////////////////////////////
    // SBA -> AXI4-Lite
    dm_sba_axil i_sba_axil (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_i     (sba_req),
        .addr_i    (sba_addr),
        .we_i      (sba_we),
        .wdata_i   (sba_wdata),
        .be_i      (sba_be),
        .gnt_o     (sba_gnt),
        .r_valid_o (sba_rvalid),
        .r_err_o   (sba_rerr),
        .r_rdata_o (sba_rdata),
        .*
    );

endmodule
