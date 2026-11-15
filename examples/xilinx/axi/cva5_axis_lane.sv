/*
 * cva5_axis_lane -- the low lanes of a wider AXI-Stream, and nothing else.
 *
 * Between the DMA and the accelerator. The DMA reads main memory and so its
 * stream is as wide as the bus, 32 bits; the accelerator's input port is 24,
 * because hls4ml packs one RGB pixel of ap_ufixed<8,0> into one beat and pads
 * each element to a byte. Three lanes of eight bits is 24.
 *
 * This is NOT a width converter. Converting 32 to 24 in general means two
 * beats spanning three, a gearbox with state, and a rule that every transfer
 * is a multiple of three words -- which is what the first version of this
 * design had, with a Xilinx axis_dwidth_converter doing it. The rule here is
 * different and is set by how the image is stored: four bytes per pixel, R,
 * G, B and a zero. One pixel is then exactly one 32-bit word, the DMA's beat
 * and the accelerator's beat are 1:1, and all this has to do is drop the pad
 * byte. No state, no FIFO, no chunking rule.
 *
 * Little-endian puts the pad byte in the top lane: a word is
 * {8'h00, B, G, R} and the accelerator wants {B, G, R}, element zero in the
 * least significant bits, which is how hls4ml packs nnet::array. So the
 * conversion really is tdata[M_WIDTH-1:0].
 *
 * The dropped lanes are watched rather than ignored: pad_seen counts beats
 * whose discarded bits were not zero. Nothing downstream can tell a stream
 * fed from 3-byte pixels from one fed correctly -- the colours just come out
 * shifted and the classifier quietly gets worse -- so the count is brought
 * out to be read over the bus. It is the one symptom this module can offer
 * for the mistake it exists to make impossible.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_axis_lane #(
    //Incoming beat width. The DMA's stream, so the AXI data width.
    parameter int unsigned S_WIDTH = 32,

    //Outgoing beat width, the accelerator's input port. Must be narrower:
    //a wider output would be a gearbox, which this is deliberately not.
    parameter int unsigned M_WIDTH = 24
) (
    input  logic                clk,
    input  logic                rstn,

    input  logic [S_WIDTH-1:0]  s_axis_tdata,
    input  logic                s_axis_tvalid,
    output logic                s_axis_tready,
    input  logic                s_axis_tlast,

    output logic [M_WIDTH-1:0]  m_axis_tdata,
    output logic                m_axis_tvalid,
    input  logic                m_axis_tready,
    output logic                m_axis_tlast,

    //Beats whose dropped lanes were not zero, since reset. Saturates rather
    //than wrapping: "a lot" and "a lot plus one" say the same thing, and a
    //counter that wraps to zero reports success.
    output logic [15:0]         pad_seen
);

    initial begin
        if (M_WIDTH >= S_WIDTH)
            $error({"cva5_axis_lane: M_WIDTH must be narrower than S_WIDTH; ",
                    "widening is a gearbox, not a lane select (instance %m)"});
    end

    //Wires. The handshake is untouched in both directions, so this adds no
    //latency and cannot deadlock: there is nothing here to deadlock.
    assign m_axis_tdata  = s_axis_tdata[M_WIDTH-1:0];
    assign m_axis_tvalid = s_axis_tvalid;
    assign m_axis_tlast  = s_axis_tlast;
    assign s_axis_tready = m_axis_tready;

    logic dropped_nonzero;
    assign dropped_nonzero = |s_axis_tdata[S_WIDTH-1:M_WIDTH];

    always_ff @(posedge clk) begin
        if (~rstn)
            pad_seen <= '0;
        else if (s_axis_tvalid & s_axis_tready & dropped_nonzero
                 & ~(&pad_seen))
            pad_seen <= pad_seen + 1'b1;
    end

endmodule
