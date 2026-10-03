`timescale 1ns/1ps
//=============================================================================
// tb_jtag -- CVA5 + debug module driven by a real debugger in simulation.
//
// OpenOCD connects over riscv-dbg's remote-bitbang bridge (SimJTAG) to the
// external TAP, so the whole flow -- transport, DM, SBA, and later halt/resume
// -- can be exercised on a workstation instead of on the board.
//
// The board build uses the BSCANE2 DTM; this harness compiles riscv-dbg's
// dmi_jtag_tap in its place (both define the same module name), which is why
// the JTAG pins are brought out of cva5_wrapper.
//
// Memory map matches the PYNQ-Z2 system:
//   0x4000_0000  128 KB RAM      (CPU cached path m_axi_mem, debugger SBA)
//   0x6000_0000  UART Lite-like  (CPU peripheral bus m_axi, debugger SBA)
//   0x8000_0000  boot ROM        (inside cva5_wrapper, loaded from boot.mif)
//
// Build and run with test_benches/debug/run_jtag.sh.
//=============================================================================
module tb_jtag;

    localparam int unsigned RAM_WORDS = 32768;      // 128 KB
    localparam logic [31:0] RAM_BASE  = 32'h40000000;

    logic clk = 0;
    always #5 clk = ~clk;                            // 100 MHz
    logic rstn = 0;

    // ---- shared memory -----------------------------------------------------
    logic [31:0] ram [RAM_WORDS];
    int nlines = 0;

    function automatic bit in_ram(input logic [31:0] a);
        return (a >= RAM_BASE) && (a < RAM_BASE + 4*RAM_WORDS);
    endfunction
    function automatic int unsigned ram_idx(input logic [31:0] a);
        return (a - RAM_BASE) >> 2;
    endfunction

    // ---- JTAG (SimJTAG <-> OpenOCD remote bitbang) -------------------------
    logic jtag_tck, jtag_tms, jtag_tdi, jtag_trstn, jtag_tdo;
    logic [31:0] jtag_exit;

    // Listens on TCP 9999; OpenOCD connects with remote_bitbang.
    SimJTAG #(.TICK_DELAY(10), .PORT(9999)) sim_jtag (
        .clock           (clk),
        .reset           (~rstn),
        .enable          (1'b1),
        .init_done       (rstn),
        .jtag_TCK        (jtag_tck),
        .jtag_TMS        (jtag_tms),
        .jtag_TDI        (jtag_tdi),
        .jtag_TRSTn      (jtag_trstn),
        .jtag_TDO_data   (jtag_tdo),
        .jtag_TDO_driven (1'b1),
        .exit            (jtag_exit)
    );

    // ---- DUT ---------------------------------------------------------------
    // peripheral bus (m_axi): UART
    logic p_arready, p_arvalid, p_rready, p_rvalid, p_awready, p_awvalid;
    logic p_wready, p_wvalid, p_bready, p_bvalid;
    logic [31:0] p_araddr, p_rdata, p_awaddr, p_wdata;
    logic [3:0]  p_wstrb;
    logic [1:0]  p_rresp, p_bresp;

    // cached memory path (m_axi_mem): RAM, with bursts
    logic m_arready, m_arvalid, m_rready, m_rvalid, m_rlast;
    logic m_awready, m_awvalid, m_wready, m_wvalid, m_wlast, m_bready, m_bvalid;
    logic [31:0] m_araddr, m_rdata, m_awaddr, m_wdata;
    logic [7:0]  m_arlen, m_awlen;
    logic [2:0]  m_arsize, m_awsize;
    logic [1:0]  m_arburst, m_awburst, m_rresp, m_bresp;
    logic [3:0]  m_arcache, m_awcache, m_wstrb;
    logic [5:0]  m_arid, m_awid, m_rid, m_bid;

    // debugger SBA (m_axi_dbg): RAM and UART, AXI4-Lite
    logic d_arready, d_arvalid, d_rready, d_rvalid, d_awready, d_awvalid;
    logic d_wready, d_wvalid, d_bready, d_bvalid;
    logic [31:0] d_araddr, d_rdata, d_awaddr, d_wdata;
    logic [3:0]  d_wstrb;
    logic [2:0]  d_arprot, d_awprot;
    logic [1:0]  d_rresp, d_bresp;

    logic ndmreset;

    cva5_wrapper #(.LOCAL_MEM("boot.mif"), .WORDS(256)) dut (
        .clk (clk), .rstn (rstn),

        .m_axi_arready(p_arready), .m_axi_arvalid(p_arvalid), .m_axi_araddr(p_araddr),
        .m_axi_rready(p_rready), .m_axi_rvalid(p_rvalid), .m_axi_rdata(p_rdata), .m_axi_rresp(p_rresp),
        .m_axi_awready(p_awready), .m_axi_awvalid(p_awvalid), .m_axi_awaddr(p_awaddr),
        .m_axi_wready(p_wready), .m_axi_wvalid(p_wvalid), .m_axi_wdata(p_wdata), .m_axi_wstrb(p_wstrb),
        .m_axi_bready(p_bready), .m_axi_bvalid(p_bvalid), .m_axi_bresp(p_bresp),

        .m_axi_mem_arready(m_arready), .m_axi_mem_arvalid(m_arvalid), .m_axi_mem_araddr(m_araddr),
        .m_axi_mem_arlen(m_arlen), .m_axi_mem_arsize(m_arsize), .m_axi_mem_arburst(m_arburst),
        .m_axi_mem_arcache(m_arcache), .m_axi_mem_arid(m_arid),
        .m_axi_mem_rready(m_rready), .m_axi_mem_rvalid(m_rvalid), .m_axi_mem_rdata(m_rdata),
        .m_axi_mem_rresp(m_rresp), .m_axi_mem_rlast(m_rlast), .m_axi_mem_rid(m_rid),
        .m_axi_mem_awready(m_awready), .m_axi_mem_awvalid(m_awvalid), .m_axi_mem_awaddr(m_awaddr),
        .m_axi_mem_awlen(m_awlen), .m_axi_mem_awsize(m_awsize), .m_axi_mem_awburst(m_awburst),
        .m_axi_mem_awcache(m_awcache), .m_axi_mem_awid(m_awid),
        .m_axi_mem_wready(m_wready), .m_axi_mem_wvalid(m_wvalid), .m_axi_mem_wdata(m_wdata),
        .m_axi_mem_wstrb(m_wstrb), .m_axi_mem_wlast(m_wlast),
        .m_axi_mem_bready(m_bready), .m_axi_mem_bvalid(m_bvalid), .m_axi_mem_bresp(m_bresp),
        .m_axi_mem_bid(m_bid),

        .m_axi_dbg_arready(d_arready), .m_axi_dbg_arvalid(d_arvalid), .m_axi_dbg_araddr(d_araddr),
        .m_axi_dbg_arprot(d_arprot),
        .m_axi_dbg_rready(d_rready), .m_axi_dbg_rvalid(d_rvalid), .m_axi_dbg_rdata(d_rdata),
        .m_axi_dbg_rresp(d_rresp),
        .m_axi_dbg_awready(d_awready), .m_axi_dbg_awvalid(d_awvalid), .m_axi_dbg_awaddr(d_awaddr),
        .m_axi_dbg_awprot(d_awprot),
        .m_axi_dbg_wready(d_wready), .m_axi_dbg_wvalid(d_wvalid), .m_axi_dbg_wdata(d_wdata),
        .m_axi_dbg_wstrb(d_wstrb),
        .m_axi_dbg_bready(d_bready), .m_axi_dbg_bvalid(d_bvalid), .m_axi_dbg_bresp(d_bresp),

        .ndmreset (ndmreset),
        .jtag_tck (jtag_tck), .jtag_tms (jtag_tms), .jtag_trst_n (jtag_trstn),
        .jtag_tdi (jtag_tdi), .jtag_tdo (jtag_tdo)
    );

    // ---- UART Lite-like slave on the peripheral bus -------------------------
    // 0x04 = Tx FIFO (prints), 0x08 = status (Tx never full).
    assign p_awready = p_awvalid & p_wvalid & ~p_bvalid;
    assign p_wready  = p_awvalid & p_wvalid & ~p_bvalid;
    assign p_arready = ~p_rvalid;
    assign p_rresp = 2'b00;
    assign p_bresp = 2'b00;
    always_ff @(posedge clk) begin
        if (!rstn) begin
            p_bvalid <= 0; p_rvalid <= 0;
        end else begin
            if (p_awvalid & p_awready) begin
                p_bvalid <= 1;
                if (p_awaddr[3:0] == 4'h4) begin
                    $write("%c", p_wdata[7:0]);
                    if (p_wdata[7:0] == 8'h0a) nlines++;
                end
            end else if (p_bvalid & p_bready) p_bvalid <= 0;
            if (p_arvalid & p_arready) begin p_rvalid <= 1; p_rdata <= 32'h0; end
            else if (p_rvalid & p_rready) p_rvalid <= 0;
        end
    end

    // ---- RAM slave on the cached path (AXI4 with INCR bursts) --------------
    typedef enum logic [1:0] {R_IDLE, R_DATA} rstate_t;
    rstate_t rstate;
    logic [31:0] r_addr;
    logic [8:0]  r_beats;

    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
    wstate_t wstate;
    logic [31:0] w_addr;

    assign m_arready = (rstate == R_IDLE);
    assign m_awready = (wstate == W_IDLE);
    assign m_wready  = (wstate == W_DATA);
    assign m_rresp = 2'b00;
    assign m_bresp = 2'b00;
    // Responses must carry the ID captured at the address handshake: the
    // adapter hands out a new ID as soon as an address is accepted, and routes
    // each response by the ID it comes back with.
    logic [5:0] r_id, w_id;
    assign m_rid = r_id;
    assign m_bid = w_id;

    always_ff @(posedge clk) begin
        if (!rstn) begin
            rstate <= R_IDLE; wstate <= W_IDLE;
            m_rvalid <= 0; m_rlast <= 0; m_bvalid <= 0;
        end else begin
            // reads
            case (rstate)
                R_IDLE: if (m_arvalid) begin
                    r_id    <= m_arid;
                    r_addr  <= m_araddr;
                    r_beats <= m_arlen + 1;
                    rstate  <= R_DATA;
                end
                R_DATA: if (!m_rvalid || m_rready) begin
                    m_rdata  <= in_ram(r_addr) ? ram[ram_idx(r_addr)] : 32'hdeadbeef;
                    m_rvalid <= 1;
                    m_rlast  <= (r_beats == 1);
                    r_addr   <= r_addr + 4;
                    r_beats  <= r_beats - 1;
                    if (r_beats == 1) rstate <= R_IDLE;
                end
            endcase
            if (m_rvalid & m_rready & m_rlast) begin m_rvalid <= 0; m_rlast <= 0; end

            // writes
            case (wstate)
                W_IDLE: if (m_awvalid) begin w_id <= m_awid; w_addr <= m_awaddr; wstate <= W_DATA; end
                W_DATA: if (m_wvalid) begin
                    if (in_ram(w_addr)) begin
                        automatic int unsigned idx = ram_idx(w_addr);
                        automatic logic [31:0] word = ram[idx];
                        for (int b = 0; b < 4; b++)
                            if (m_wstrb[b]) word[8*b +: 8] = m_wdata[8*b +: 8];
                        ram[idx] <= word;
                    end
                    w_addr <= w_addr + 4;
                    if (m_wlast) begin m_bvalid <= 1; wstate <= W_RESP; end
                end
                W_RESP: if (m_bready) begin m_bvalid <= 0; wstate <= W_IDLE; end
            endcase
        end
    end

    // ---- SBA slave: RAM and UART, AXI4-Lite --------------------------------
    assign d_awready = d_awvalid & d_wvalid & ~d_bvalid;
    assign d_wready  = d_awvalid & d_wvalid & ~d_bvalid;
    assign d_arready = ~d_rvalid;
    assign d_rresp = 2'b00;
    assign d_bresp = 2'b00;
    always_ff @(posedge clk) begin
        if (!rstn) begin
            d_bvalid <= 0; d_rvalid <= 0;
        end else begin
            if (d_awvalid & d_awready) begin
                d_bvalid <= 1;
                if (in_ram(d_awaddr)) begin
                    automatic int unsigned idx = ram_idx(d_awaddr);
                    automatic logic [31:0] word = ram[idx];
                    for (int b = 0; b < 4; b++)
                        if (d_wstrb[b]) word[8*b +: 8] = d_wdata[8*b +: 8];
                    ram[idx] <= word;
                end
                else if (d_awaddr[31:16] == 16'h6000 && d_awaddr[3:0] == 4'h4) begin
                    $write("%c", d_wdata[7:0]);
                    if (d_wdata[7:0] == 8'h0a) nlines++;
                end
            end else if (d_bvalid & d_bready) d_bvalid <= 0;

            if (d_arvalid & d_arready) begin
                d_rvalid <= 1;
                d_rdata  <= in_ram(d_araddr) ? ram[ram_idx(d_araddr)] : 32'h0;
            end else if (d_rvalid & d_rready) d_rvalid <= 0;
        end
    end

    // ---- optional debug trace (+define+DEBUG_TRACE) --------------------------
`ifdef DEBUG_TRACE
    logic prev_req, prev_mode;
    always_ff @(posedge clk) begin
        prev_req  <= dut.debug_req;
        prev_mode <= dut.cpu.debug_mode;
        if (dut.debug_req != prev_req)
            $display("[trace %0t] debug_req=%0b", $time, dut.debug_req);
        if (dut.cpu.debug_mode != prev_mode)
            $display("[trace %0t] debug_mode=%0b dpc=%h", $time, dut.cpu.debug_mode, dut.cpu.dpc);
        if (dut.cpu.gc_unit_block.state != dut.cpu.gc_unit_block.next_state)
            $display("[trace %0t] gc %0d -> %0d (debug_pending=%0b issue_valid=%0b possible_exc=%0b)", $time,
                     dut.cpu.gc_unit_block.state, dut.cpu.gc_unit_block.next_state,
                     dut.cpu.gc_unit_block.debug_pending, dut.cpu.issue.stage_valid,
                     dut.cpu.gc_unit_block.possible_exception);
        if (dut.cpu.instruction_issued)
            $display("[trace %0t] ISSUE pc=%h instr=%h", $time, dut.cpu.issue.pc, dut.cpu.issue.instruction);
        if (dut.cpu.gc.exception.valid)
            $display("[trace %0t] EXC code=%0d pc=%h tval=%h", $time, dut.cpu.gc.exception.code, dut.cpu.gc.exception.pc, dut.cpu.gc.exception.tval);
        if (m_rvalid & m_rready & ($time < 1500000))
            $display("[trace %0t] MEM R data=%h last=%0b id=%0d", $time, m_rdata, m_rlast, m_rid);
        if (m_arvalid & m_arready)
            $display("[trace %0t] MEM AR addr=%h len=%0d", $time, m_araddr, m_arlen);
        if (dut.instruction_bram.en)
            $display("[trace %0t] ROM fetch addr=%h", $time, {dut.instruction_bram.addr, 2'b00});
        if (dut.dm_req)
            $display("[trace %0t] DM %s addr=%h wdata=%h", $time, dut.dm_we ? "WR" : "RD", dut.dm_addr, dut.dm_wdata);
        if (dut.dm_port.if_ack)
            $display("[trace %0t] DM fetch -> %h", $time, dut.dm_port.if_dat_r);
    end
`endif

    // ---- run ---------------------------------------------------------------
    initial begin
        for (int i = 0; i < RAM_WORDS; i++) ram[i] = 32'h0;
        $readmemh("boot.mif", dut.local_mem.mem, 0);
        // Program in RAM: app.mif if present, otherwise a counting loop that
        // gives the debugger something observable (x1 increments forever):
        //   40000000: addi x1, x0, 0
        //   40000004: addi x1, x1, 1
        //   40000008: j    40000004
        begin
            int fd = $fopen("app.mif", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("app.mif", ram, 0);
                $display("[tb] RAM preloaded from app.mif");
            end else begin
                ram[0] = 32'h00000093;
                ram[1] = 32'h00108093;
                ram[2] = 32'hffdff06f;
                $display("[tb] RAM preloaded with a counting loop (x1++)");
            end
        end
        repeat (10) @(posedge clk);
        rstn = 1;
        $display("[tb] running: connect with openocd -f test_benches/debug/cva5-sim.cfg");
        forever begin
            @(posedge clk);
            if (jtag_exit != 0) begin
                $display("\n[tb] SimJTAG exit %0d", jtag_exit);
                $finish;
            end
        end
    end

endmodule
