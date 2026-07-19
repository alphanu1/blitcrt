//=============================================================================
// framebuffer.v -- 38,400 x 8 dual-clock RAM (320x240 @ 4bpp packed)
//
// Infers ~35 M9K blocks on Cyclone IV (EP4CE10 has 46). Write port lives in
// the 50MHz USB domain, read port in the 6.4MHz pixel domain; the M9K
// hardware handles the clock domain crossing.
//
// Note: there is no double buffering, so a slow host write racing the beam
// can tear. Acceptable for bring-up; fix later with SDRAM + page flip, or
// by having the host time uploads against the vsync status (see README).
//=============================================================================
module framebuffer (
    // write port (USB / 50MHz domain)
    input  wire        wclk,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0]  wdata,
    // read port (pixel clock domain)
    input  wire        rclk,
    input  wire [15:0] raddr,
    output reg  [7:0]  rdata
);

    localparam DEPTH = 38400;

    (* ramstyle = "M9K" *) reg [7:0] mem [0:DEPTH-1];

    always @(posedge wclk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    always @(posedge rclk) begin
        rdata <= mem[raddr];
    end

endmodule
