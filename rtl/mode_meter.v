// mode_meter.v -- measure fractional refresh + pixel clock for the test card
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// Measures the frame PERIOD in clk50 ticks (one counter, latched each
// frame_pulse), then derives:
//
//   vfreq (centi-Hz) = 50_000_000 * 100 / ticks_per_frame
//                      -> e.g. 5994 = 59.94 Hz  (2 decimal places)
//
//   pclk  (kHz)      = htotal * vtotal * 50_000_000 / ticks_per_frame / 1000
//                      = (htotal*vtotal*50_000) / ticks_per_frame
//                      -> e.g. 6400 = 6.400 MHz
//
// Both use a shared sequential restoring divider that runs once per frame
// during blanking -- far from the pixel datapath, so timing is trivial.
// The 2^6-cycle-ish divide completes in well under a frame at 50MHz.
//
// Outputs are latched digit sets for the splash text (BCD-ish nibbles).
//   vfreq_bcd : 4 digits  D3 D2 . D1 D0   (tens, ones, tenths, hundredths)
//   pclk_bcd  : 4 digits  D3 . D2 D1 D0   (MHz, then 3 fractional -> kHz)
// The splash formats them as "NN.NN HZ" and "N.NNN MHZ".

module mode_meter (
    input  wire        clk50,
    input  wire        rst_n,
    input  wire        frame_pulse,       // 1 clk50 cycle per frame
    input  wire [11:0] htotal,            // total pixels/line  (loaded)
    input  wire [11:0] vtotal,            // total lines/frame  (loaded)
    output reg  [15:0] vfreq_bcd,         // {d3,d2,d1,d0} centi-Hz digits
    output reg  [15:0] pclk_bcd           // {d3,d2,d1,d0} kHz digits (MHz.fff)
);
    // ---- 1. measure ticks per frame ----------------------------------
    reg [25:0] tick_cnt;
    reg [25:0] ticks_per_frame;
    reg        have_period;

    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt        <= 26'd0;
            ticks_per_frame <= 26'd0;
            have_period     <= 1'b0;
        end else if (frame_pulse) begin
            ticks_per_frame <= tick_cnt;
            tick_cnt        <= 26'd0;
            have_period     <= (tick_cnt != 26'd0);
        end else if (tick_cnt != {26{1'b1}}) begin
            tick_cnt <= tick_cnt + 26'd1;
        end
    end

    // ---- 2. numerators -----------------------------------------------
    // vfreq centi-Hz numerator = 50e6 * 100 = 5_000_000_000 (needs 33 bits)
    localparam [39:0] VNUM = 40'd5_000_000_000;
    // pclk kHz numerator = htotal*vtotal*50_000
    wire [39:0] pnum = htotal * vtotal * 40'd50_000;

    // ---- 3. shared sequential divider --------------------------------
    // Computes q = num / ticks_per_frame by restoring division (40-bit).
    // A tiny FSM: on a new period, run the vfreq divide, then the pclk
    // divide, latch both. Runs once per frame; ~80 clk50 cycles total.
    localparam [2:0] S_IDLE=0, S_LOAD_V=1, S_DIV=2, S_DONE_V=3,
                     S_LOAD_P=4, S_DONE_P=5;
    reg [2:0]  st;
    reg [39:0] num, rem, quo;
    reg [5:0]  bit_i;
    reg        which;                 // 0=vfreq, 1=pclk
    reg [39:0] div;

    reg period_seen;
    reg trigger;
    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n) trigger <= 1'b0;
        else        trigger <= frame_pulse & have_period;  // 1-cycle delayed
    end

    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; period_seen <= 1'b0;
            vfreq_bcd <= 16'd0; pclk_bcd <= 16'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (trigger) begin           // ticks_per_frame now settled
                        div  <= {14'd0, ticks_per_frame};
                        st   <= S_LOAD_V;
                    end
                end
                S_LOAD_V: begin
                    num <= VNUM; rem <= 40'd0; quo <= 40'd0;
                    bit_i <= 6'd39; which <= 1'b0; st <= S_DIV;
                end
                S_DIV: begin
                    // restoring division, one bit per cycle
                    if ( ({rem[38:0], num[bit_i]}) >= div ) begin
                        rem <= {rem[38:0], num[bit_i]} - div;
                        quo <= (quo << 1) | 40'd1;
                    end else begin
                        rem <= {rem[38:0], num[bit_i]};
                        quo <= (quo << 1);
                    end
                    if (bit_i == 6'd0)
                        st <= which ? S_DONE_P : S_DONE_V;   // quo settles by next state
                    else
                        bit_i <= bit_i - 6'd1;
                end
                S_DONE_V: begin
                    // quo now holds the final quotient (last bit settled)
                    vfreq_bcd <= bin_to_4bcd(quo[15:0]);   // centi-Hz
                    st <= S_LOAD_P;
                end
                S_LOAD_P: begin
                    num <= pnum; rem <= 40'd0; quo <= 40'd0;
                    bit_i <= 6'd39; which <= 1'b1; st <= S_DIV;
                end
                S_DONE_P: begin
                    pclk_bcd <= bin_to_4bcd(quo[15:0]);     // kHz
                    st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // 16-bit binary -> 4 decimal digits (0..9999), each nibble a digit
    function [15:0] bin_to_4bcd;
        input [15:0] v;
        reg [15:0] n;
        reg [3:0] d3,d2,d1,d0;
        begin
            n  = (v > 16'd9999) ? 16'd9999 : v;
            d3 = n / 16'd1000;
            d2 = (n / 16'd100) % 16'd10;
            d1 = (n / 16'd10)  % 16'd10;
            d0 = n % 16'd10;
            bin_to_4bcd = {d3,d2,d1,d0};
        end
    endfunction

endmodule
