//=============================================================================
// ft245_tx.v -- FT245-style async FIFO write engine (transmit only)
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// The TX mirror of ft245_rx. Works with FT2232H/FT232H channel in async
// FIFO mode. At 50MHz (20ns/cycle):
//
//   Wait for TXE# low (FTDI's TX buffer has room), then present data and
//   pulse WR# low for 4 cycles (80ns; datasheet min WR# pulse 50ns, data
//   setup 20ns before WR# rising, hold 0ns). FTDI latches on WR# rising.
//   After the write, TXE# may go briefly high; a 2FF synchronizer plus a
//   guard count prevents a stale-low TXE# from double-writing.
//
// Interface to the packet engine is simple ready/valid:
//   tx_valid  (in)  : engine has a byte to send
//   tx_data   (in)  : the byte
//   tx_ready  (out) : this engine can accept a byte THIS cycle
//
// The bidirectional FT245 data bus is handled in the top level: this
// module drives ft_data_out + ft_oe (output-enable) and the top muxes
// the inout pad between ft245_rx (input) and ft245_tx (output). Because
// RX and TX share the bus, the top must never enable the pad output
// while a read is in progress -- see fb_top_v2 arbitration.
//
// Async-mode throughput ~1MB/s (matches the RX ceiling). Sync-FIFO mode
// (~40MB/s) replaces both rx and tx engines, keeping these interfaces.
//=============================================================================
module ft245_tx (
    input  wire       clk,          // 50MHz
    input  wire       rst_n,

    input  wire       txe_n_raw,    // async from FTDI (TX buffer has room when low)
    output reg  [7:0] ft_data_out,  // to the shared data bus (via top mux)
    output reg        ft_oe,        // 1 = drive the bus (this module owns it)
    output reg        wr_n,

    input  wire [7:0] tx_data,      // byte from packet engine
    input  wire       tx_valid,     // engine has a byte
    output reg        tx_ready      // 1-cycle: byte accepted this cycle
);

    // 2FF synchronizer on TXE#
    reg [1:0] txe_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) txe_sync <= 2'b11;
        else        txe_sync <= {txe_sync[0], txe_n_raw};
    end
    wire txe_n = txe_sync[1];

    localparam [1:0] S_IDLE    = 2'd0,
                     S_WR_LOW  = 2'd1,
                     S_WR_HIGH = 2'd2;

    reg [1:0] state;
    reg [2:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            wr_n        <= 1'b1;
            ft_oe       <= 1'b0;
            ft_data_out <= 8'd0;
            cnt         <= 3'd0;
            tx_ready    <= 1'b0;
        end else begin
            tx_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    wr_n  <= 1'b1;
                    ft_oe <= 1'b0;
                    if (tx_valid && !txe_n) begin
                        ft_data_out <= tx_data;   // present data
                        ft_oe       <= 1'b1;      // drive the bus
                        wr_n        <= 1'b0;      // begin WR# pulse
                        tx_ready    <= 1'b1;      // byte accepted
                        cnt         <= 3'd0;
                        state       <= S_WR_LOW;
                    end
                end

                S_WR_LOW: begin
                    cnt <= cnt + 3'd1;
                    if (cnt == 3'd3) begin        // 80ns elapsed
                        wr_n  <= 1'b1;            // WR# rising -> FTDI latches
                        cnt   <= 3'd0;
                        state <= S_WR_HIGH;
                        // keep ft_oe high one more cycle for hold, then release
                    end
                end

                S_WR_HIGH: begin
                    ft_oe <= 1'b0;               // release the bus
                    if (cnt != 3'd7)
                        cnt <= cnt + 3'd1;
                    // wait out synchronizer latency before next write
                    if (cnt >= 3'd3)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
