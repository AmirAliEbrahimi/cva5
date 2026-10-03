/*
 * dm_sba_axil -- bridges the riscv-dbg System Bus Access master port
 * (OBI-like: req held until gnt, then one r_valid per transaction, reads and
 * writes alike, one outstanding) to an AXI4-Lite master.
 *
 * Licensed under the Apache License, Version 2.0.
 */
module dm_sba_axil (
    input  logic        clk,
    input  logic        rst_n,          // synchronous, active low

    // riscv-dbg SBA master side
    input  logic        req_i,
    input  logic [31:0] addr_i,
    input  logic        we_i,
    input  logic [31:0] wdata_i,
    input  logic [3:0]  be_i,
    output logic        gnt_o,
    output logic        r_valid_o,
    output logic        r_err_o,
    output logic [31:0] r_rdata_o,

    // AXI4-Lite master
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

    typedef enum logic [2:0] {IDLE, WR, WR_RESP, RD, RD_RESP} state_t;
    state_t      state;
    logic        aw_done, w_done;
    logic [31:0] addr_q, wdata_q;
    logic [3:0]  be_q;

    // Accept a request only when idle; dm_sba advances on this single-cycle grant.
    assign gnt_o = (state == IDLE) & req_i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= IDLE;
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
            r_valid_o <= 1'b0;
            r_err_o   <= 1'b0;
            r_rdata_o <= '0;
        end else begin
            r_valid_o <= 1'b0;
            unique case (state)
                IDLE: if (req_i) begin
                    addr_q  <= addr_i;
                    wdata_q <= wdata_i;
                    be_q    <= be_i;
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;
                    state   <= we_i ? WR : RD;
                end
                WR: begin
                    if (m_axi_awvalid & m_axi_awready) aw_done <= 1'b1;
                    if (m_axi_wvalid  & m_axi_wready)  w_done  <= 1'b1;
                    if ((aw_done | m_axi_awready) & (w_done | m_axi_wready))
                        state <= WR_RESP;
                end
                WR_RESP: if (m_axi_bvalid) begin
                    r_valid_o <= 1'b1;
                    r_err_o   <= m_axi_bresp[1];
                    r_rdata_o <= '0;
                    state     <= IDLE;
                end
                RD: if (m_axi_arready) state <= RD_RESP;
                RD_RESP: if (m_axi_rvalid) begin
                    r_valid_o <= 1'b1;
                    r_err_o   <= m_axi_rresp[1];
                    r_rdata_o <= m_axi_rdata;
                    state     <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    assign m_axi_awaddr  = addr_q;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awvalid = (state == WR) & ~aw_done;
    assign m_axi_wdata   = wdata_q;
    assign m_axi_wstrb   = be_q;
    assign m_axi_wvalid  = (state == WR) & ~w_done;
    assign m_axi_bready  = (state == WR_RESP);
    assign m_axi_araddr  = addr_q;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arvalid = (state == RD);
    assign m_axi_rready  = (state == RD_RESP);

endmodule
