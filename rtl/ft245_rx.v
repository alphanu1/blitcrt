//=============================================================================
// ft245_rx.v -- FT245-style async FIFO read engine (receive only)
//
// Works with FT2232H/FT232H channel configured for async FIFO mode, or an
// FT245R. At 50MHz (20ns/cycle):
//
//   RD# low for 4 cycles (80ns)  -- datasheet min pulse 50ns, data valid
//                                   within 50ns of RD# falling; sampled on
//                                   the last low cycle.
//   RD# high, wait for RXF# high -- FTDI deasserts RXF# after each read and
//                                   reasserts when the next byte is ready.
//   Min 4 high cycles before resampling RXF#, covering the 2FF synchronizer
//   latency so a stale-low RXF# can't trigger a double read.
//
// Sustained throughput lands around 1MB/s, which is the async-mode ceiling
// anyway. Upgrade path: FT2232H sync FIFO mode (60MHz bus, ~40MB/s) --
// replace this module, keep byte_data/byte_valid interface identical.
//=============================================================================
module ft245_rx (
    input  wire       clk,        // 50MHz
    input  wire       rst_n,

    input  wire       rxf_n_raw,  // async from FTDI
    input  wire [7:0] ft_data,
    output reg        rd_n,

    output reg  [7:0] byte_data,
    output reg        byte_valid  // 1-cycle strobe
);

    // 2FF synchronizer on RXF#
    reg [1:0] rxf_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rxf_sync <= 2'b11;
        else        rxf_sync <= {rxf_sync[0], rxf_n_raw};
    end
    wire rxf_n = rxf_sync[1];

    localparam [1:0] S_IDLE    = 2'd0,
                     S_RD_LOW  = 2'd1,
                     S_RD_HIGH = 2'd2;

    reg [1:0] state;
    reg [2:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            rd_n       <= 1'b1;
            cnt        <= 3'd0;
            byte_data  <= 8'd0;
            byte_valid <= 1'b0;
        end else begin
            byte_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    rd_n <= 1'b1;
                    if (!rxf_n) begin
                        rd_n  <= 1'b0;
                        cnt   <= 3'd0;
                        state <= S_RD_LOW;
                    end
                end

                S_RD_LOW: begin
                    cnt <= cnt + 3'd1;
                    if (cnt == 3'd3) begin        // 80ns elapsed
                        byte_data  <= ft_data;    // sample while RD# still low
                        byte_valid <= 1'b1;
                        rd_n       <= 1'b1;
                        cnt        <= 3'd0;
                        state      <= S_RD_HIGH;
                    end
                end

                S_RD_HIGH: begin
                    if (cnt != 3'd7)
                        cnt <= cnt + 3'd1;
                    // wait out synchronizer latency, then require RXF# high
                    if (cnt >= 3'd3 && rxf_n)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
