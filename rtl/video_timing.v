//=============================================================================
// video_timing.v -- 15kHz progressive timing generator
//
// Defaults, at 6.4MHz pixel clock:
//   H: 320 active + 8 fp + 31 sync + 48 bp = 407  -> 15.724 kHz
//   V: 240 active + 4 fp +  3 sync + 15 bp = 262  -> 60.02 Hz
//
// This lands inside the sync window of standard-def CRTs (15.5-16.0 kHz,
// 50-61 Hz). Tweak the porches if your monitor needs centering.
//=============================================================================
module video_timing #(
    parameter H_ACTIVE = 320,
    parameter H_FP     = 8,
    parameter H_SYNC   = 31,
    parameter H_BP     = 48,
    parameter V_ACTIVE = 240,
    parameter V_FP     = 4,
    parameter V_SYNC   = 3,
    parameter V_BP     = 15
)(
    input  wire       clk,     // pixel clock
    input  wire       rst_n,
    output reg  [9:0] hcnt,    // 0 .. H_TOTAL-1
    output reg  [8:0] vcnt,    // 0 .. V_TOTAL-1
    output wire       de,      // active video
    output wire       hs_n,    // hsync, active low
    output wire       vs_n     // vsync, active low
);

    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 10'd0;
            vcnt <= 9'd0;
        end else begin
            if (hcnt == H_TOTAL - 1) begin
                hcnt <= 10'd0;
                vcnt <= (vcnt == V_TOTAL - 1) ? 9'd0 : vcnt + 9'd1;
            end else begin
                hcnt <= hcnt + 10'd1;
            end
        end
    end

    assign de   = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

    assign hs_n = ~((hcnt >= H_ACTIVE + H_FP) &&
                    (hcnt <  H_ACTIVE + H_FP + H_SYNC));

    assign vs_n = ~((vcnt >= V_ACTIVE + V_FP) &&
                    (vcnt <  V_ACTIVE + V_FP + V_SYNC));

endmodule
