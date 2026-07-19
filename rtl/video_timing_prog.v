// video_timing_prog.v -- runtime-programmable 15kHz timing generator
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// fpga15k v2: the CRT1 "video card" successor to the fixed-parameter
// video_timing.v. All geometry comes from registers written by the CRT1
// packet engine (CMD_SET_MODE), using switchres POSITION semantics
// exactly as on the wire: begin/end are sync start/end positions, not
// porch widths -- identical to wire_modeline and to DRM, so no
// conversion anywhere in the stack.
//
// Loads are double-buffered: writes land in shadow registers and are
// latched into the active set at the next frame boundary (or immediately
// when 'force_load' pulses, for first-init), so a mode switch never
// produces a torn frame.
//
// Syncs are active-low (SCART/arcade convention, matches Pi2SCART).

module video_timing_prog (
    input  wire        pclk,
    input  wire        rst_n,

    // shadow-register load interface (pclk domain; packet engine
    // crosses domains before driving this)
    input  wire        ld_stb,      // pulse: latch shadow set below
    input  wire [11:0] ld_hactive,
    input  wire [11:0] ld_hbegin,
    input  wire [11:0] ld_hend,
    input  wire [11:0] ld_htotal,
    input  wire [11:0] ld_vactive,
    input  wire [11:0] ld_vbegin,
    input  wire [11:0] ld_vend,
    input  wire [11:0] ld_vtotal,
    input  wire        force_load,  // apply immediately (init), else at frame end

    output reg  [11:0] x,           // pixel position in active area
    output reg  [11:0] y,
    output reg         de,          // display enable (active area)
    output reg         hs_n,
    output reg         vs_n,
    output wire        frame_start  // 1-pclk pulse at (0,0)
);

    // ---------------- shadow set ----------------
    reg [11:0] s_hact, s_hbeg, s_hend, s_htot;
    reg [11:0] s_vact, s_vbeg, s_vend, s_vtot;
    reg        pending;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            // safe defaults: the phase-1 320x240p60 mode
            s_hact <= 12'd320; s_hbeg <= 12'd328;
            s_hend <= 12'd359; s_htot <= 12'd407;
            s_vact <= 12'd240; s_vbeg <= 12'd244;
            s_vend <= 12'd247; s_vtot <= 12'd262;
        end else if (ld_stb) begin
            s_hact <= ld_hactive; s_hbeg <= ld_hbegin;
            s_hend <= ld_hend;    s_htot <= ld_htotal;
            s_vact <= ld_vactive; s_vbeg <= ld_vbegin;
            s_vend <= ld_vend;    s_vtot <= ld_vtotal;
            pending <= 1'b1;
        end else if (apply_now)
            pending <= 1'b0;
    end

    // ---------------- active set ----------------
    reg [11:0] hact, hbeg, hend, htot;
    reg [11:0] vact, vbeg, vend, vtot;
    reg [11:0] hcnt, vcnt;

    wire line_end  = (hcnt == htot - 1);
    wire frame_end = line_end && (vcnt == vtot - 1);
    wire apply_now = (pending && (frame_end || force_load));

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hact <= 12'd320; hbeg <= 12'd328; hend <= 12'd359; htot <= 12'd407;
            vact <= 12'd240; vbeg <= 12'd244; vend <= 12'd247; vtot <= 12'd262;
        end else if (apply_now) begin
            hact <= s_hact; hbeg <= s_hbeg; hend <= s_hend; htot <= s_htot;
            vact <= s_vact; vbeg <= s_vbeg; vend <= s_vend; vtot <= s_vtot;
        end
    end

    // ---------------- counters ----------------
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
        end else begin
            if (line_end) begin
                hcnt <= 12'd0;
                vcnt <= frame_end ? 12'd0 : vcnt + 12'd1;
            end else
                hcnt <= hcnt + 12'd1;
            // a mode load resets scan position for a clean first frame
            if (apply_now) begin
                hcnt <= 12'd0;
                vcnt <= 12'd0;
            end
        end
    end

    assign frame_start = (hcnt == 12'd0) && (vcnt == 12'd0);

    // ---------------- registered outputs ----------------
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 12'd0; y <= 12'd0;
            de <= 1'b0; hs_n <= 1'b1; vs_n <= 1'b1;
        end else begin
            x    <= hcnt;
            y    <= vcnt;
            de   <= (hcnt < hact) && (vcnt < vact);
            hs_n <= ~((hcnt >= hbeg) && (hcnt < hend));
            vs_n <= ~((vcnt >= vbeg) && (vcnt < vend));
        end
    end

endmodule
