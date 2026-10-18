// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
//----------------------------------------------------------------------------
// Vendored by hand from lowRISC/ibex-demo-system rtl/system/uart.sv at
// d37beb753e19482eb054aefac73a27289bf72e47. Two changes, both deliberate:
//
//   1. The RX and TX FIFOs are fifo_v3 from pulp-platform's common_cells
//      instead of OpenTitan's prim_fifo_sync. fifo_v3 is already vendored and
//      packaged in this tree -- riscv-dbg uses it in the same bitstream --
//      where prim_fifo_sync would bring prim_fifo_sync_cnt, prim_util_pkg and
//      prim_assert.sv with its four .svh macro headers, and those headers need
//      include directories that a Vivado packaged IP flattens away.
//
//      prim_fifo_sync holds wready_o and rvalid_o low for one cycle after
//      reset (its `under_rst` flag); fifo_v3 has no such gate. For a UART that
//      is not observable: nothing can present a byte that soon.
//
//   2. The status register reports axi_uartlite's bit assignment rather than
//      lowRISC's own, because this UART replaces an axi_uartlite and QEMU
//      models that device. Keeping the bits means examples/sw and the QEMU
//      machine need no change and no per-target #ifdef:
//
//          bit 0   RX has data        (lowRISC: RX empty, inverted)
//          bit 1   RX FIFO full       (lowRISC: absent)
//          bit 2   TX FIFO empty      (lowRISC: absent)
//          bit 3   TX FIFO full       (lowRISC: bit 1)
//
//      Software written against lowRISC's map would need adjusting; software
//      written against axi_uartlite, which is what this tree has, does not.
//
// The RX/TX datapath, baud generation, oversampling and state machines are
// upstream's and unmodified.
//----------------------------------------------------------------------------

module uart #(
  parameter int unsigned ClockFrequency = 50_000_000,
  parameter int unsigned BaudRate       = 115_200,
  parameter int unsigned RxFifoDepth    = 128,
  parameter int unsigned TxFifoDepth    = 128,
  parameter int unsigned AddrWidth      = 32,
  parameter int unsigned DataWidth      = 32,
  parameter int unsigned RegAddr        = 12
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                 device_req_i,
  input  logic [AddrWidth-1:0] device_addr_i,
  input  logic                 device_we_i,
  input  logic [3:0]           device_be_i,
  input  logic [DataWidth-1:0] device_wdata_i,
  output logic                 device_rvalid_o,
  output logic [DataWidth-1:0] device_rdata_o,

  input  logic uart_rx_i,
  output logic uart_irq_o,
  output logic uart_tx_o
);

  localparam int unsigned ClocksPerBaud      = ClockFrequency / BaudRate;
  localparam bit [RegAddr-1:0] UartRxReg     = RegAddr'('h0);
  localparam bit [RegAddr-1:0] UartTxReg     = RegAddr'('h4);
  localparam bit [RegAddr-1:0] UartStatusReg = RegAddr'('h8);

  typedef enum logic[1:0] {
    IDLE,
    START,
    PROC,
    STOP
  } uart_state_t;

  logic [DataWidth-1:0] device_rdata_d, device_rdata_q;
  logic                 device_rvalid_d, device_rvalid_q;

  logic [RegAddr-1:0] reg_addr;

  logic [$clog2(ClocksPerBaud)-1:0] rx_baud_counter_q, rx_baud_counter_d;
  logic                             rx_baud_tick;

  uart_state_t rx_state_q, rx_state_d;
  logic [2:0]  rx_bit_counter_q, rx_bit_counter_d;
  logic [7:0]  rx_current_byte_q, rx_current_byte_d;
  logic [2:0]  rx_q;
  logic        rx_start, rx_valid;

  logic        rx_fifo_wvalid;
  logic        rx_fifo_rready;
  logic [7:0]  rx_fifo_rdata;
  logic        rx_fifo_empty;
  logic        rx_fifo_full;

  logic [$clog2(ClocksPerBaud)-1:0] tx_baud_counter_q, tx_baud_counter_d;
  logic                             tx_baud_tick;

  logic write_req;

  uart_state_t tx_state_q, tx_state_d;
  logic [2:0]  tx_bit_counter_q, tx_bit_counter_d;
  logic [7:0]  tx_current_byte_q, tx_current_byte_d;
  logic        tx_next_byte;

  logic       tx_fifo_wvalid;
  logic       tx_fifo_rvalid, tx_fifo_rready;
  logic [7:0] tx_fifo_rdata;
  logic       tx_fifo_full;
  logic       tx_fifo_empty;

  assign reg_addr = device_addr_i[RegAddr-1:0];

  always_comb begin
    device_rdata_d  = '0;
    device_rvalid_d = 1'b0;
    rx_fifo_rready  = 1'b0;

    if (device_req_i) begin
      device_rvalid_d = 1'b1;

      if (device_be_i[0] & ~device_we_i) begin
        case (reg_addr)
          UartRxReg: begin
            device_rdata_d = {(DataWidth-8)'('0), rx_fifo_rdata};
            rx_fifo_rready = 1'b1;
          end
          UartTxReg: begin
            device_rdata_d = '0;
          end
          UartStatusReg: begin
            // axi_uartlite's bit assignment; see the note at the top.
            device_rdata_d = {(DataWidth-4)'('0),
                              tx_fifo_full, tx_fifo_empty,
                              rx_fifo_full, ~rx_fifo_empty};
          end
          default: begin
            device_rdata_d = '0;
          end
        endcase
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      device_rdata_q  <= '0;
      device_rvalid_q <= 1'b0;
    end else begin
      device_rdata_q  <= device_rdata_d;
      device_rvalid_q <= device_rvalid_d;
    end
  end

  assign device_rdata_o  = device_rdata_q;
  assign device_rvalid_o = device_rvalid_q;

  assign rx_fifo_wvalid = rx_baud_tick & rx_valid;

  // Set the rx_baud_counter half-way on rx_start to ensure sampling the bits 'in the middle'
  assign rx_baud_counter_d = rx_baud_tick ? '0                                            :
                             rx_start     ? $bits(rx_baud_counter_q)'(ClocksPerBaud >> 1) :
                                            rx_baud_counter_q + 1'b1;

  assign rx_baud_tick = rx_baud_counter_q == $bits(rx_baud_counter_q)'(ClocksPerBaud - 1);

  // fifo_v3 in place of prim_fifo_sync; see the note at the top. fifo_v3 has
  // no wready_o, so the full and empty conditions are qualified at the call
  // site. They are belt and braces rather than load bearing: fifo_v3 already
  // guards internally (`if (push_i && ~full_o)`), so a push into a full FIFO
  // drops the byte either way -- which is what prim_fifo_sync did too, since
  // this caller never looked at its wready_o. What the guards buy is silence
  // from fifo_v3's own `full_write` and `empty_read` concurrent assertions,
  // which fire in a simulator that evaluates them. Removing them is a
  // behaviourally equivalent mutation and the testbench does not catch it.
  fifo_v3 #(
    .FALL_THROUGH ( 1'b0        ),
    .DATA_WIDTH   ( 8           ),
    .DEPTH        ( RxFifoDepth )
  ) u_rx_fifo (
    .clk_i,
    .rst_ni,
    .flush_i    (1'b0),
    .testmode_i (1'b0),

    .full_o  (rx_fifo_full),
    .empty_o (rx_fifo_empty),
    .usage_o (),

    .data_i  (rx_current_byte_q),
    .push_i  (rx_fifo_wvalid & ~rx_fifo_full),

    .data_o  (rx_fifo_rdata),
    .pop_i   (rx_fifo_rready & ~rx_fifo_empty)
  );

  assign uart_irq_o = !rx_fifo_empty;

  //  Synchronize RX and derive rx_start signal
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_q <= '0;
    end else begin
      rx_q <= {rx_q[1:0], uart_rx_i};
    end
  end

  assign rx_start = !rx_q[1] & rx_q[2] & (rx_state_q == IDLE);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_baud_counter_q <= '0;
    end else begin
      rx_baud_counter_q <= rx_baud_counter_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_state_q        <= IDLE;
      rx_bit_counter_q  <= '0;
      rx_current_byte_q <= '0;
    // Transition the rx state on both rx_start and an rx_baud_tick
    end else if (rx_start || rx_baud_tick) begin
      rx_state_q        <= rx_state_d;
      rx_bit_counter_q  <= rx_bit_counter_d;
      rx_current_byte_q <= rx_current_byte_d;
    end
  end

  always_comb begin
    rx_valid          = 0;
    rx_bit_counter_d  = rx_bit_counter_q;
    rx_current_byte_d = rx_current_byte_q;
    rx_state_d        = rx_state_q;

    case (rx_state_q)
      IDLE: begin

        if (rx_start) begin
          rx_state_d = START;
        end
      end
      START: begin
        rx_current_byte_d = '0;
        rx_bit_counter_d  = '0;

        if (!rx_q[2]) begin
          rx_state_d = PROC;
        end else begin
          rx_state_d = IDLE;
        end
      end
      PROC: begin
        rx_current_byte_d = {rx_q[2], rx_current_byte_q[7:1]};

        if (rx_bit_counter_q == 3'd7) begin
          rx_state_d = STOP;
        end else begin
          rx_bit_counter_d = rx_bit_counter_q + 3'd1;
        end
      end
      STOP: begin
        if (rx_q[2]) begin
          rx_valid = 1;
        end
        rx_state_d = IDLE;
      end
    endcase
  end

  assign write_req = (device_req_i & device_be_i[0] & device_we_i);

  assign tx_fifo_wvalid = (reg_addr == UartTxReg) & write_req;
  assign tx_fifo_rready = tx_baud_tick & tx_next_byte;

  assign tx_baud_counter_d = tx_baud_tick ? '0 : tx_baud_counter_q + 1'b1;
  assign tx_baud_tick      = tx_baud_counter_q == $bits(tx_baud_counter_q)'(ClocksPerBaud - 1);

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0        ),
    .DATA_WIDTH   ( 8           ),
    .DEPTH        ( TxFifoDepth )
  ) u_tx_fifo (
    .clk_i,
    .rst_ni,
    .flush_i    (1'b0),
    .testmode_i (1'b0),

    .full_o  (tx_fifo_full),
    .empty_o (tx_fifo_empty),
    .usage_o (),

    .data_i  (device_wdata_i[7:0]),
    .push_i  (tx_fifo_wvalid & ~tx_fifo_full),

    .data_o  (tx_fifo_rdata),
    .pop_i   (tx_fifo_rready & ~tx_fifo_empty)
  );

  assign tx_fifo_rvalid = ~tx_fifo_empty;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_baud_counter_q <= '0;
    end else begin
      tx_baud_counter_q <= tx_baud_counter_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_state_q        <= IDLE;
      tx_bit_counter_q  <= '0;
      tx_current_byte_q <= '0;
    end else if (tx_baud_tick) begin
      tx_state_q        <= tx_state_d;
      tx_bit_counter_q  <= tx_bit_counter_d;
      tx_current_byte_q <= tx_current_byte_d;
    end
  end

  always_comb begin
    uart_tx_o         = 1'b0;
    tx_bit_counter_d  = tx_bit_counter_q;
    tx_current_byte_d = tx_current_byte_q;
    tx_next_byte      = 1'b0;
    tx_state_d        = tx_state_q;

    case (tx_state_q)
      IDLE: begin
        uart_tx_o = 1'b1;

        if (tx_fifo_rvalid) begin
          tx_state_d = START;
        end
      end
      START: begin
        uart_tx_o         = 1'b0;
        tx_state_d        = PROC;
        tx_bit_counter_d  = 3'd0;
        tx_current_byte_d = tx_fifo_rdata;
        tx_next_byte      = 1'b1;
      end
      PROC: begin
        uart_tx_o = tx_current_byte_q[0];

        tx_current_byte_d = {1'b0, tx_current_byte_q[7:1]};
        if (tx_bit_counter_q == 3'd7) begin
          tx_state_d = STOP;
        end else begin
          tx_bit_counter_d = tx_bit_counter_q + 3'd1;
        end
      end
      STOP: begin
        uart_tx_o = 1'b1;
        if (tx_fifo_rvalid) begin
          tx_state_d = START;
        end else begin
          tx_state_d = IDLE;
        end
      end
    endcase
  end

  // Unused signals.
  logic [AddrWidth-1-RegAddr:0] unused_device_addr;
  logic [3:1]                   unused_device_be;
  logic [DataWidth-1-8:0]       unused_device_wdata;

  assign unused_device_addr  = device_addr_i[AddrWidth-1:RegAddr];
  assign unused_device_be    = device_be_i[3:1];
  assign unused_device_wdata = device_wdata_i[DataWidth-1:8];

endmodule
