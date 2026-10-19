/*
 * cva5_uart -- lowRISC's UART behind an AXI4-Lite slave port.
 *
 * Replaces Xilinx's axi_uartlite. The register map is axi_uartlite's, so
 * examples/sw and the QEMU machine are unchanged by the swap:
 *
 *   +0x00  RX    read pops a byte from the receive FIFO
 *   +0x04  TX    write pushes a byte into the transmit FIFO
 *   +0x08  STAT  bit 0 RX has data, 1 RX full, 2 TX empty, 3 TX full
 *
 * Offsets above 0x08 read as zero and writes to them are dropped; the
 * crossbar is what decides the window, and an address outside it never
 * arrives here.
 *
 * The UART's own bus is the ibex-demo-system device interface: a request
 * pulse, and read data one cycle later with no way to stall. So this is a
 * protocol adapter rather than a register file -- one transaction at a time,
 * which for a 9600-baud UART is not a constraint worth engineering away.
 *
 * Writes take priority over reads, so a program spinning on STAT cannot
 * starve its own output.
 *
 * BAUD_RATE is a parameter rather than an IP setting, and the default matches
 * what axi_uartlite was configured for, so no terminal settings change. At
 * 100 MHz, 9600 baud is 10416 clocks per bit.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_uart #(
    parameter int unsigned CLOCK_FREQUENCY = 100_000_000,
    parameter int unsigned BAUD_RATE       = 9_600,
    parameter int unsigned RX_FIFO_DEPTH   = 32,
    parameter int unsigned TX_FIFO_DEPTH   = 32,

    //Width of the slave's address bus, and so the size of the window the
    //block design gives it: 12 bits is the 4 KB this UART decodes.
    //
    //This is not cosmetic. Vivado infers a packaged IP's address block from
    //the width of its AXI address port, so a 32-bit port here produces a 4 GB
    //aperture, and a 4 GB aperture can only be placed at zero -- the address
    //editor then refuses the offset with BD 41-70 ("must fit an available
    //aperture"). cva5_clint_axi's 16-bit port gets its 64 KB block the same
    //way. Master ports obey the opposite rule; see CLAUDE.md.
    parameter int unsigned ADDR_WIDTH      = 12
) (
    input logic clk,
    input logic rstn,

    //AXI4-Lite slave. Vivado infers the interface from these names.
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [2:0]  s_axi_awprot,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [2:0]  s_axi_arprot,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    //Serial, and the receive interrupt (unconnected on this board, as it was
    //with axi_uartlite)
    input  logic rx,
    output logic tx,
    output logic irq
);

    ////////////////////////////////////////////////////
    //Device bus into the UART
    logic        dev_req, dev_we;
    logic [31:0] dev_addr, dev_wdata;
    logic [3:0]  dev_be;
    logic        dev_rvalid;
    logic [31:0] dev_rdata;

    typedef enum logic [2:0] {
        IDLE,
        WAIT_W,   //write issued, waiting for the device to acknowledge
        RESP_W,   //holding BVALID
        WAIT_R,   //read issued, waiting for data
        RESP_R    //holding RVALID
    } state_t;
    state_t state;

    logic grant_w, grant_r;
    assign grant_w = (state == IDLE) & s_axi_awvalid & s_axi_wvalid;
    assign grant_r = (state == IDLE) & ~(s_axi_awvalid & s_axi_wvalid) & s_axi_arvalid;

    //Single-cycle accept: ready asserts in the same cycle as valid, and the
    //state machine leaves IDLE, so it cannot be taken twice.
    assign s_axi_awready = grant_w;
    assign s_axi_wready = grant_w;
    assign s_axi_arready = grant_r;

    assign dev_req = grant_w | grant_r;
    assign dev_we = grant_w;
    //Zero-extended to the UART's 32-bit address port; it looks at the low
    //12 bits and ties the rest off.
    assign dev_addr = grant_w ? 32'(s_axi_awaddr) : 32'(s_axi_araddr);
    assign dev_wdata = s_axi_wdata;
    //The UART decodes a read only when byte lane 0 is enabled, and a read has
    //no strobes of its own, so they are forced for reads.
    assign dev_be = grant_w ? s_axi_wstrb : 4'hF;

    //Nothing here can fail: an offset the UART does not decode reads as zero
    //rather than erroring, and the crossbar has already decided the address is
    //in this window.
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    logic [31:0] rdata_q;
    assign s_axi_rdata = rdata_q;

    //Asynchronous active-low, matching the vendored UART and fifo_v3, which
    //both reset that way. Driving the same net synchronously here and
    //asynchronously there is the mixed usage Verilator's SYNCASYNCNET flags,
    //and the inconsistency is the bug rather than either convention: rstn
    //comes from proc_sys_reset's peripheral_aresetn, already synchronised to
    //this clock, so the asynchronous form costs nothing.
    always_ff @(posedge clk or negedge rstn) begin
        if (~rstn) begin
            state <= IDLE;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
        end
        else begin
            unique case (state)
                IDLE: if (dev_req)
                    state <= grant_w ? WAIT_W : WAIT_R;
                WAIT_W: if (dev_rvalid) begin
                    s_axi_bvalid <= 1'b1;
                    state <= RESP_W;
                end
                RESP_W: if (s_axi_bready) begin
                    s_axi_bvalid <= 1'b0;
                    state <= IDLE;
                end
                WAIT_R: if (dev_rvalid) begin
                    rdata_q <= dev_rdata;
                    s_axi_rvalid <= 1'b1;
                    state <= RESP_R;
                end
                RESP_R: if (s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    ////////////////////////////////////////////////////
    //The UART itself
    uart #(
        .ClockFrequency (CLOCK_FREQUENCY),
        .BaudRate (BAUD_RATE),
        .RxFifoDepth (RX_FIFO_DEPTH),
        .TxFifoDepth (TX_FIFO_DEPTH),
        .AddrWidth (32),
        .DataWidth (32),
        .RegAddr (12)
    ) uart_inst (
        .clk_i (clk),
        .rst_ni (rstn),

        .device_req_i (dev_req),
        .device_addr_i (dev_addr),
        .device_we_i (dev_we),
        .device_be_i (dev_be),
        .device_wdata_i (dev_wdata),
        .device_rvalid_o (dev_rvalid),
        .device_rdata_o (dev_rdata),

        .uart_rx_i (rx),
        .uart_irq_o (irq),
        .uart_tx_o (tx)
    );

endmodule
