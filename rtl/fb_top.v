//=============================================================================
// fb_top.v -- 15kHz USB framebuffer, Waveshare CoreEP4CE10 / DVK600
//
// 320x240 @ 60Hz progressive, 15.72kHz horizontal, 4bpp + 16-entry RGB444
// palette. Video data received over an FT245-style async FIFO (FT2232H
// module on the DVK600 I/O headers).
//
// Clock domains:
//   clk50    : 50MHz board oscillator. USB RX + framebuffer write port.
//   clk_pix  : 6.4MHz from PLL.       Video timing + framebuffer read port.
//   CDC happens inside the dual-clock M9K RAM; no other signals cross.
//
// Set TEST_BARS=1 to render 16 palette color bars and verify the whole
// analog video path before any USB traffic exists.
//=============================================================================
module fb_top #(
    parameter TEST_BARS = 0
)(
    input  wire       clk50,       // 50MHz oscillator on core board
    input  wire       rst_n,       // RESET pushbutton (active low)

    // FT245 async FIFO interface (FT2232H channel A in FIFO mode)
    input  wire       ft_rxf_n,    // low = byte available
    input  wire [7:0] ft_data,     // D[7:0] (read-only use)
    output wire       ft_rd_n,     // read strobe, active low
    output wire       ft_wr_n,     // unused, held high

    // Analog RGB via resistor DAC, 15kHz
    output reg  [3:0] vid_r,
    output reg  [3:0] vid_g,
    output reg  [3:0] vid_b,
    output reg        vid_hs_n,    // separate hsync, active low
    output reg        vid_vs_n,    // separate vsync, active low
    output reg        vid_cs_n     // composite sync (for SCART/arcade)
);

    assign ft_wr_n = 1'b1;         // never drive the FIFO bus

    //-------------------------------------------------------------------------
    // Pixel clock PLL: generate with Quartus IP Catalog (ALTPLL)
    //   name: pix_pll, inclk0 = 50MHz, c0 = 6.4MHz
    //-------------------------------------------------------------------------
    wire clk_pix, pll_locked;
    pix_pll u_pll (
        .inclk0 (clk50),
        .c0     (clk_pix),
        .locked (pll_locked)
    );
    wire vrst_n = rst_n & pll_locked;

    //-------------------------------------------------------------------------
    // Video timing: 407 x 262 total @ 6.4MHz -> 15.72kHz / 60.0Hz
    //-------------------------------------------------------------------------
    wire [9:0] hcnt;
    wire [8:0] vcnt;
    wire       de, hs_n, vs_n;

    video_timing u_vt (
        .clk   (clk_pix),
        .rst_n (vrst_n),
        .hcnt  (hcnt),
        .vcnt  (vcnt),
        .de    (de),
        .hs_n  (hs_n),
        .vs_n  (vs_n)
    );

    //-------------------------------------------------------------------------
    // USB receive path (50MHz domain)
    //-------------------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;

    ft245_rx u_ft (
        .clk        (clk50),
        .rst_n      (rst_n),
        .rxf_n_raw  (ft_rxf_n),
        .ft_data    (ft_data),
        .rd_n       (ft_rd_n),
        .byte_data  (rx_data),
        .byte_valid (rx_valid)
    );

    wire        fb_we;
    wire [15:0] fb_waddr;
    wire [7:0]  fb_wdata;
    wire        pal_we;
    wire [3:0]  pal_windex;
    wire [11:0] pal_wcolor;

    usb_protocol u_proto (
        .clk        (clk50),
        .rst_n      (rst_n),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .fb_we      (fb_we),
        .fb_addr    (fb_waddr),
        .fb_data    (fb_wdata),
        .pal_we     (pal_we),
        .pal_index  (pal_windex),
        .pal_color  (pal_wcolor)
    );

    //-------------------------------------------------------------------------
    // Framebuffer read path (pixel clock domain)
    // Byte address = vcnt*160 + hcnt/2  (160 bytes per line, 2 px per byte)
    // vcnt*160 = (vcnt<<7) + (vcnt<<5)
    //-------------------------------------------------------------------------
    wire [15:0] raddr = ({7'd0, vcnt} << 7) + ({7'd0, vcnt} << 5)
                      + {6'd0, hcnt[9:1]};

    wire [7:0] fb_q;
    framebuffer u_fb (
        .wclk  (clk50),
        .we    (fb_we),
        .waddr (fb_waddr),
        .wdata (fb_wdata),
        .rclk  (clk_pix),
        .raddr (raddr),
        .rdata (fb_q)
    );

    // Pipeline stage 1: RAM output registered inside framebuffer.
    // Delay nibble select + a copy of hcnt to match.
    reg       x0_d1;
    reg [9:0] hcnt_d1;
    always @(posedge clk_pix) begin
        x0_d1   <= hcnt[0];
        hcnt_d1 <= hcnt;
    end

    // Even pixel = high nibble, odd pixel = low nibble.
    // Host packs: byte = (pix[2i] << 4) | pix[2i+1]
    wire [3:0] pix_idx = (TEST_BARS != 0) ? hcnt_d1[8:5]
                       : (x0_d1 ? fb_q[3:0] : fb_q[7:4]);

    // Pipeline stage 2: palette lookup (registered inside palette).
    wire [11:0] pix_rgb;
    palette u_pal (
        .wclk   (clk50),
        .we     (pal_we),
        .windex (pal_windex),
        .wcolor (pal_wcolor),
        .rclk   (clk_pix),
        .rindex (pix_idx),
        .rcolor (pix_rgb)
    );

    //-------------------------------------------------------------------------
    // Align syncs/DE with the 2-cycle pixel pipeline, register all outputs.
    //-------------------------------------------------------------------------
    reg [1:0] de_d, hs_d, vs_d;
    always @(posedge clk_pix or negedge vrst_n) begin
        if (!vrst_n) begin
            de_d <= 2'b00; hs_d <= 2'b11; vs_d <= 2'b11;
            vid_r <= 4'd0; vid_g <= 4'd0; vid_b <= 4'd0;
            vid_hs_n <= 1'b1; vid_vs_n <= 1'b1; vid_cs_n <= 1'b1;
        end else begin
            de_d <= {de_d[0], de};
            hs_d <= {hs_d[0], hs_n};
            vs_d <= {vs_d[0], vs_n};

            vid_r <= de_d[1] ? pix_rgb[11:8] : 4'd0;
            vid_g <= de_d[1] ? pix_rgb[7:4]  : 4'd0;
            vid_b <= de_d[1] ? pix_rgb[3:0]  : 4'd0;

            vid_hs_n <= hs_d[1];
            vid_vs_n <= vs_d[1];
            vid_cs_n <= hs_d[1] & vs_d[1];   // combined negative sync
        end
    end

endmodule
