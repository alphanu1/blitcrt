//=============================================================================
// palette.v -- 16 x RGB444 color lookup, host-writable
//
// Tiny enough to live in registers. Read is registered in the pixel domain.
// A palette write landing mid-frame can produce a one-frame glitch on
// affected colors; if that matters, have the host update the palette during
// vblank or immediately before a frame upload.
//
// Default palette = 16 useful colors so TEST_BARS mode shows something
// sensible before the host ever talks to us.
//=============================================================================
module palette (
    // write port (USB / 50MHz domain)
    input  wire        wclk,
    input  wire        we,
    input  wire [3:0]  windex,
    input  wire [11:0] wcolor,   // {R[3:0], G[3:0], B[3:0]}
    // read port (pixel clock domain)
    input  wire        rclk,
    input  wire [3:0]  rindex,
    output reg  [11:0] rcolor
);

    reg [11:0] pal [0:15];

    initial begin
        pal[0]  = 12'h000;  // black
        pal[1]  = 12'h800;  // dark red
        pal[2]  = 12'h080;  // dark green
        pal[3]  = 12'h880;  // dark yellow
        pal[4]  = 12'h008;  // dark blue
        pal[5]  = 12'h808;  // dark magenta
        pal[6]  = 12'h088;  // dark cyan
        pal[7]  = 12'h888;  // grey
        pal[8]  = 12'h444;  // dark grey
        pal[9]  = 12'hF00;  // red
        pal[10] = 12'h0F0;  // green
        pal[11] = 12'hFF0;  // yellow
        pal[12] = 12'h00F;  // blue
        pal[13] = 12'hF0F;  // magenta
        pal[14] = 12'h0FF;  // cyan
        pal[15] = 12'hFFF;  // white
    end

    always @(posedge wclk) begin
        if (we)
            pal[windex] <= wcolor;
    end

    always @(posedge rclk) begin
        rcolor <= pal[rindex];
    end

endmodule
