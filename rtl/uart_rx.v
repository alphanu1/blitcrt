//=============================================================================
// uart_rx.v -- 8N1 UART receiver, CRT1 byte source
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// A bring-up alternative to ft245_rx: receive CRT1 packet bytes over a
// plain USB-serial cable (FTDI/CP2102/CH340) instead of an FT2232H FIFO.
// Produces the IDENTICAL byte_data/byte_valid interface, so it drops
// straight into crt1_ft245 with nothing downstream changed.
//
// 8 data bits, no parity, 1 stop bit (8N1). Oversamples the incoming
// line at 16x and samples each bit at its centre. Default 3,000,000 baud
// at 50MHz (divisor 50e6/3e6 = ~16.67 -> use CLKS_PER_BIT); override the
// parameter for slower rates (e.g. 921600, 115200).
//
//   CLKS_PER_BIT = clk_freq / baud.  50MHz / 3Mbaud = 16 (nearest int).
//   50MHz / 921600 = 54.  50MHz / 115200 = 434.
//
// Only rx is needed to receive commands; a matching uart_tx can be added
// later for the reply path (mirrors ft245_tx's role) if serial replies
// are wanted during bring-up.
//=============================================================================
module uart_rx #(
    parameter integer CLKS_PER_BIT = 16      // 50MHz / 3,000,000 baud
) (
    input  wire       clk,        // 50MHz
    input  wire       rst_n,

    input  wire       rx,         // async serial in (idle high)

    output reg  [7:0] byte_data,
    output reg        byte_valid  // 1-cycle strobe when a byte completes
);

    // 2FF synchronizer on the async rx line
    reg [1:0] rx_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_sync <= 2'b11;
        else        rx_sync <= {rx_sync[0], rx};
    end
    wire rx_s = rx_sync[1];

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shreg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            clk_cnt    <= 16'd0;
            bit_idx    <= 3'd0;
            shreg      <= 8'd0;
            byte_data  <= 8'd0;
            byte_valid <= 1'b0;
        end else begin
            byte_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (!rx_s) begin              // start bit (falling edge)
                        state <= S_START;
                    end
                end

                // sample the middle of the start bit to confirm it's real
                S_START: begin
                    if (clk_cnt == (CLKS_PER_BIT/2)) begin
                        if (!rx_s) begin          // still low -> valid start
                            clk_cnt <= 16'd0;
                            state   <= S_DATA;
                        end else
                            state <= S_IDLE;      // glitch, abort
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                // sample each data bit at its centre (LSB first)
                S_DATA: begin
                    if (clk_cnt == (CLKS_PER_BIT-1)) begin
                        clk_cnt        <= 16'd0;
                        shreg[bit_idx] <= rx_s;
                        if (bit_idx == 3'd7) begin
                            bit_idx <= 3'd0;
                            state   <= S_STOP;
                        end else
                            bit_idx <= bit_idx + 3'd1;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                // stop bit: emit the byte, return to idle
                S_STOP: begin
                    if (clk_cnt == (CLKS_PER_BIT-1)) begin
                        byte_data  <= shreg;
                        byte_valid <= 1'b1;       // rx_s should be high here
                        clk_cnt    <= 16'd0;
                        state      <= S_IDLE;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
