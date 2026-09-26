/*
 * dm_mem_port -- gives CVA5 both instruction and data access to the riscv-dbg
 * Debug Module's memory (debug ROM, program buffer, abstract data, flags).
 *
 * The core fetches the debug ROM and program buffer over its instruction bus
 * (Wishbone) and reads/writes the DM's data registers over its peripheral bus
 * (the AXI master, already split off by address in cva5_wrapper). The DM has a
 * single slave port with one cycle of read latency, so the two are arbitrated:
 * writes first, then reads, then instruction fetches. One access is in flight
 * at a time; debug-mode code is short and never performance critical.
 *
 * The Wishbone address is a word address, as the interface declares, so it is
 * shifted up by two here. The DM decodes only its low 12 bits.
 *
 * Licensed under the Apache License, Version 2.0.
 */
module dm_mem_port (
    input  logic        clk,
    input  logic        rst,

    // Instruction fetch (Wishbone, from the core's instruction bus)
    input  logic [29:0] if_adr,   // word address
    input  logic        if_cyc,
    input  logic        if_stb,
    output logic        if_ack,
    output logic [31:0] if_dat_r,

    // Load/store (the core's AXI master, DM address range only)
    input  logic        ar_valid,
    input  logic [31:0] ar_addr,
    output logic        ar_ready,
    output logic        r_valid,
    output logic [31:0] r_data,

    input  logic        aw_valid,
    input  logic [31:0] aw_addr,
    output logic        aw_ready,
    input  logic        w_valid,
    input  logic [31:0] w_data,
    input  logic [3:0]  w_strb,
    output logic        w_ready,
    output logic        b_valid,

    // Debug Module slave port (read data valid one cycle after req)
    output logic        dm_req,
    output logic        dm_we,
    output logic [31:0] dm_addr,
    output logic [3:0]  dm_be,
    output logic [31:0] dm_wdata,
    input  logic [31:0] dm_rdata
);

    typedef enum logic [1:0] {IDLE, WAIT_DATA, RESPOND} state_t;
    typedef enum logic [1:0] {SRC_W, SRC_R, SRC_I} src_t;
    state_t state;
    src_t   src;

    logic want_w, want_r, want_i;
    logic grant_w, grant_r, grant_i;

    assign want_w = aw_valid & w_valid;
    assign want_r = ar_valid;
    assign want_i = if_cyc & if_stb & ~if_ack;

    assign grant_w = (state == IDLE) & want_w;
    assign grant_r = (state == IDLE) & ~want_w & want_r;
    assign grant_i = (state == IDLE) & ~want_w & ~want_r & want_i;

    assign dm_req   = grant_w | grant_r | grant_i;
    assign dm_we    = grant_w;
    assign dm_addr  = grant_w ? aw_addr : grant_r ? ar_addr : {if_adr, 2'b00};
    assign dm_be    = grant_w ? w_strb : 4'hF;
    assign dm_wdata = w_data;

    assign aw_ready = grant_w;
    assign w_ready  = grant_w;
    assign ar_ready = grant_r;

    logic [31:0] rsp_data;
    assign r_data   = rsp_data;
    assign if_dat_r = rsp_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= IDLE;
            r_valid <= 0;
            b_valid <= 0;
            if_ack  <= 0;
        end else begin
            r_valid <= 0;
            b_valid <= 0;
            if_ack  <= 0;
            unique case (state)
                IDLE: if (dm_req) begin
                    src   <= grant_w ? SRC_W : grant_r ? SRC_R : SRC_I;
                    state <= WAIT_DATA;
                end
                WAIT_DATA: begin                      // DM read data valid this cycle
                    rsp_data <= dm_rdata;
                    r_valid  <= (src == SRC_R);
                    b_valid  <= (src == SRC_W);
                    if_ack   <= (src == SRC_I);
                    state    <= RESPOND;
                end
                RESPOND: state <= IDLE;               // response presented this cycle
                default: state <= IDLE;
            endcase
        end
    end

endmodule
