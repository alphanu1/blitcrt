//=============================================================================
// fb_top_v2.v -- fpga15k v2 top level (CRT1 video card)
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// Wires the simulated v2 modules into a bitstream-ready top:
//   ft245_rx        -> byte stream from the FT2232H FIFO
//   crt1_ft245      -> CRT1 packet engine (mode/pll/frame/pal/info)
//   video_timing_prog -> runtime timing generator (pclk domain)
//   framebuffer     -> 4bpp dual-clock RAM (write: clk50, read: pclk)
//   palette         -> 16 x RGB444 lookup
//   splash_pattern  -> power-on test card until first SET_MODE
//   pll_ctl + pix_pll + pix_pll_reconfig -> runtime pixel clock
//
// The two Altera megafunctions (pix_pll, pix_pll_reconfig) are generated
// in Quartus (see the v2 build guide). Their instantiations are at the
// bottom, commented with the exact port names to connect -- uncomment and
// match to the generated wrappers.
//=============================================================================
module fb_top_v2 #(
    // Byte source select for bring-up:
    //   USE_UART=0 -> CRT1 bytes arrive over the FT2232H FT245 FIFO (fast path)
    //   USE_UART=1 -> CRT1 bytes arrive over a plain USB-serial UART (uses a
    //                 cable you already have; ~3Mbaud). Downstream identical.
    parameter USE_UART        = 1,
    parameter UART_CLKS_PER_BIT = 16     // 50MHz / 3,000,000 baud
) (
    input  wire       clk50,
    input  wire       rst_n,

    // FT2232H FT245 async FIFO (full RX + TX; sync-FIFO later for 60Hz).
    // ft_data is the shared BIDIRECTIONAL data bus. The top drives it only
    // while ft245_tx owns it (ft_oe high); otherwise it is an input for
    // ft245_rx. rd_n/wr_n/rxf_n/txe_n are the FT245 handshake lines.
    input  wire       ft_rxf_n,     // RX FIFO has a byte (active low)
    input  wire       ft_txe_n,     // TX FIFO has room  (active low)
    inout  wire [7:0] ft_data,      // shared 8-bit FIFO data bus
    output wire       ft_rd_n,      // read strobe  (to FTDI)
    output wire       ft_wr_n,      // write strobe (to FTDI)

    // Plain USB-serial UART receive (used when USE_UART=1). Idle high.
    input  wire       uart_rx_pin,

    // Analog RGB666 via Pi2SCART resistor DAC
    output reg  [5:0] vid_r6,
    output reg  [5:0] vid_g6,
    output reg  [5:0] vid_b6,
    output reg        vid_hs_n,
    output reg        vid_vs_n
);
    // ------------------------------------------------------------------
    // Clocks
    // ------------------------------------------------------------------
    wire pclk;              // from pix_pll.c0 (runtime-reconfigurable)
    wire pll_locked;

    // ------------------------------------------------------------------
    // CRT1 byte source: FT245 FIFO or UART, selected by USE_UART.
    // Both produce {rx_data, rx_valid}; the packet engine sees one stream.
    // ------------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;
    wire [7:0] tx_data;
    wire       tx_valid;
    wire       tx_ready;

    // per-source byte streams
    wire [7:0] ft_rx_data;
    wire       ft_rx_valid;
    wire [7:0] ua_rx_data;
    wire       ua_rx_valid;

    // TX drives the bus only when it asserts ft_oe; else the bus is input.
    wire [7:0] ft_data_out;
    wire       ft_oe;
    assign ft_data = ft_oe ? ft_data_out : 8'bz;   // tri-state the pad

    ft245_rx u_rx (
        .clk       (clk50),
        .rst_n     (rst_n),
        .rxf_n_raw (ft_rxf_n),
        .ft_data   (ft_data),        // reads the shared bus (input when ft_oe=0)
        .rd_n      (ft_rd_n),
        .byte_data (ft_rx_data),
        .byte_valid(ft_rx_valid)
    );

    ft245_tx u_tx (
        .clk        (clk50),
        .rst_n      (rst_n),
        .txe_n_raw  (ft_txe_n),
        .ft_data_out(ft_data_out),
        .ft_oe      (ft_oe),
        .wr_n       (ft_wr_n),
        .tx_data    (tx_data),
        .tx_valid   (tx_valid),
        .tx_ready   (tx_ready)
    );

    uart_rx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) u_uart (
        .clk       (clk50),
        .rst_n     (rst_n),
        .rx        (uart_rx_pin),
        .byte_data (ua_rx_data),
        .byte_valid(ua_rx_valid)
    );

    // select which source drives the packet engine
    assign rx_data  = USE_UART ? ua_rx_data  : ft_rx_data;
    assign rx_valid = USE_UART ? ua_rx_valid : ft_rx_valid;

    // ------------------------------------------------------------------
    // CRT1 packet engine (clk50 domain)
    // ------------------------------------------------------------------
    wire        ld_toggle;
    wire [11:0] ld_ha, ld_hb, ld_he, ld_ht, ld_va, ld_vb, ld_ve, ld_vt;
    wire        pll_req;
    wire [31:0] pll_m, pll_n, pll_c;
    wire        pll_busy;
    wire        fb_we;
    wire [16:0] fb_waddr;
    wire [7:0]  fb_wdata;
    wire        pal_we;
    wire [3:0]  pal_index;
    wire [11:0] pal_rgb;

    crt1_ft245 #(.MAX_W(12'd384), .MAX_H(12'd288)) u_crt1 (
        .clk_sys   (clk50),
        .rst_n     (rst_n),
        .rx_data   (rx_data),
        .rx_valid  (rx_valid),
        .tx_data   (tx_data),
        .tx_valid  (tx_valid),
        .tx_ready  (tx_ready),             // real TX engine back-pressure
        .ld_toggle (ld_toggle),
        .ld_hactive(ld_ha), .ld_hbegin(ld_hb), .ld_hend(ld_he), .ld_htotal(ld_ht),
        .ld_vactive(ld_va), .ld_vbegin(ld_vb), .ld_vend(ld_ve), .ld_vtotal(ld_vt),
        .pll_req   (pll_req),
        .pll_m     (pll_m), .pll_n(pll_n), .pll_c(pll_c),
        .pll_busy  (pll_busy),
        .fb_we     (fb_we), .fb_waddr(fb_waddr), .fb_wdata(fb_wdata),
        .pal_we    (pal_we), .pal_index(pal_index), .pal_rgb(pal_rgb)
    );

    // load-toggle -> 1-pclk strobe (2FF sync + edge detect)
    reg [2:0] tgl_sync;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) tgl_sync <= 3'd0;
        else        tgl_sync <= {tgl_sync[1:0], ld_toggle};
    wire ld_stb = tgl_sync[2] ^ tgl_sync[1];

    // Test card persists through SET_MODE so resolutions can be switched
    // and confirmed on the CRT (numbers update live). It yields to the
    // framebuffer only when real pixels arrive: the first CMD_FRAME write
    // (fb_we). Synchronise fb_we (clk50 domain) into pclk before latching.
    reg [2:0] fbwe_sync;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) fbwe_sync <= 3'd0;
        else        fbwe_sync <= {fbwe_sync[1:0], fb_we};
    wire first_frame = fbwe_sync[2];

    reg splash_active;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n)           splash_active <= 1'b1;
        else if (first_frame) splash_active <= 1'b0;

    // ------------------------------------------------------------------
    // Timing generator (pclk domain)
    // ------------------------------------------------------------------
    wire [11:0] x, y;
    wire        de, hs_n, vs_n, frame_start;

    video_timing_prog u_vt (
        .pclk       (pclk),
        .rst_n      (rst_n),
        .ld_stb     (ld_stb),
        .ld_hactive (ld_ha), .ld_hbegin(ld_hb), .ld_hend(ld_he), .ld_htotal(ld_ht),
        .ld_vactive (ld_va), .ld_vbegin(ld_vb), .ld_vend(ld_ve), .ld_vtotal(ld_vt),
        .force_load (1'b0),
        .x(x), .y(y), .de(de), .hs_n(hs_n), .vs_n(vs_n),
        .frame_start(frame_start)
    );

    // ------------------------------------------------------------------
    // Framebuffer (write clk50 / read pclk) + palette
    // read address from scan position; map (x,y) -> linear nibble index.
    // NOTE: framebuffer.v is the v1 module; confirm its port names and
    // that its address width covers MAX_W*MAX_H. Rect-addressed writes
    // (fb_waddr currently linear from rect origin) may need the base
    // offset added here from the FRAME x/y -- see VIDEOCARD_V2 "remaining".
    // ------------------------------------------------------------------
    wire [3:0]  pix_index;   // combinational nibble select (below)
    wire [11:0] pix_rgb;

    // framebuffer stores one BYTE (two 4bpp pixels) per address. The
    // read address is the pixel's byte index (x>>1 within the row);
    // low bit of x selects the nibble. waddr/raddr are 16-bit here, so
    // MAX active must satisfy (w*h)/2 < 65536 -- 384x288/2 = 55296 ok.
    wire [15:0] rd_byte_addr = (({4'd0,y} * ld_ha) + {4'd0,x}) >> 1;
    wire [7:0]  fb_rbyte;
    reg         xlsb_d;
    always @(posedge pclk) xlsb_d <= x[0];
    assign pix_index = xlsb_d ? fb_rbyte[3:0] : fb_rbyte[7:4];

    framebuffer u_fb (
        .wclk   (clk50),
        .we     (fb_we),
        .waddr  (fb_waddr[15:0]),
        .wdata  (fb_wdata),
        .rclk   (pclk),
        .raddr  (rd_byte_addr),
        .rdata  (fb_rbyte)
    );

    palette u_pal (
        .wclk   (clk50),
        .we     (pal_we),
        .windex (pal_index),
        .wcolor (pal_rgb),
        .rclk   (pclk),
        .rindex (pix_index),
        .rcolor (pix_rgb)
    );

    // ------------------------------------------------------------------
    // Mode meter: measures fractional refresh (centi-Hz) and pixel clock
    // (kHz) from the frame period against the 50MHz crystal. Sync
    // frame_start (pclk) into clk50 and edge-detect a 1-cycle pulse.
    // ------------------------------------------------------------------
    reg [2:0] fs_sync;
    always @(posedge clk50 or negedge rst_n)
        if (!rst_n) fs_sync <= 3'd0;
        else        fs_sync <= {fs_sync[1:0], frame_start};
    wire frame_pulse = fs_sync[1] & ~fs_sync[2];

    wire [15:0] vfreq_bcd, pclk_bcd;
    mode_meter u_meter (
        .clk50      (clk50),
        .rst_n      (rst_n),
        .frame_pulse(frame_pulse),
        .htotal     (ld_ht),
        .vtotal     (ld_vt),
        .vfreq_bcd  (vfreq_bcd),
        .pclk_bcd   (pclk_bcd)
    );

    // ------------------------------------------------------------------
    // Splash pattern (pclk domain)
    // ------------------------------------------------------------------
    wire [11:0] splash_rgb;
    splash_pattern u_splash (
        .x(x), .y(y), .de(de),
        .hact(ld_ha), .vact(ld_va),   // current active dims (live)
        .vfreq_bcd(vfreq_bcd),        // measured refresh, DD.DD Hz
        .pclk_bcd (pclk_bcd),         // measured pixel clock, D.DDD MHz
        .rgb(splash_rgb)
    );

    // ------------------------------------------------------------------
    // Output mux + register (RGB444 -> 666 by MSB replication)
    // ------------------------------------------------------------------
    wire [11:0] src_rgb = splash_active ? splash_rgb
                                        : (de ? pix_rgb : 12'h000);
    always @(posedge pclk) begin
        vid_r6   <= {src_rgb[11:8], src_rgb[11:10]};
        vid_g6   <= {src_rgb[7:4],  src_rgb[7:6]};
        vid_b6   <= {src_rgb[3:0],  src_rgb[3:2]};
        vid_hs_n <= hs_n;
        vid_vs_n <= vs_n;
    end

    // ------------------------------------------------------------------
    // PLL control + megafunctions (wired to the generated pix_pll /
    // pix_pll_reconfig -- classic ALTPLL scan-reconfiguration model).
    //
    //   pll_ctl  -> pix_pll_reconfig (control: counter_type/param/data_in,
    //               write_param, reconfig, busy)
    //   reconfig <-> pix_pll         (scan chain: scandata/scanclk/
    //               scanclkena/configupdate out of reconfig into the PLL,
    //               scandataout/scandone back)
    //   pix_pll.c0 -> pclk (the runtime-reconfigurable pixel clock)
    // ------------------------------------------------------------------
    wire [3:0]  ra_ct;
    wire [2:0]  ra_cp;
    wire [8:0]  ra_di;
    wire        ra_wr, ra_rc, ra_busy;

    /* scan chain nets between reconfig and the PLL (single wires) */
    wire        rc_scandata, rc_scanclk, rc_scanclkena, rc_configupdate;
    wire        pll_scandataout, pll_scandone;
    wire        pll_areset_w;

    pll_ctl u_pllctl (
        .clk             (clk50),
        .rst_n           (rst_n),
        .req             (pll_req),
        .c_div           (pll_c),
        .m_mul           (pll_m),
        .n_div           (pll_n),
        .busy            (pll_busy),
        .pclk            (),               /* pclk is driven by pix_pll.c0 */
        .locked          (),
        .ra_counter_type (ra_ct),
        .ra_counter_param(ra_cp),
        .ra_data_in      (ra_di),
        .ra_write_param  (ra_wr),
        .ra_reconfig     (ra_rc),
        .ra_busy         (ra_busy),
        .pll_configupdate_bus(),           /* unused; scan nets wired below */
        .pll_locked_in   (pll_locked)
    );

    pix_pll_reconfig u_reconf (
        .clock           (clk50),
        .reset           (~rst_n),
        .counter_type    (ra_ct),
        .counter_param   (ra_cp),
        .data_in         (ra_di),
        .read_param      (1'b0),
        .write_param     (ra_wr),
        .reconfig        (ra_rc),
        .busy            (ra_busy),
        .data_out        (),                /* readback unused */
        .pll_areset_in   (1'b0),
        .pll_areset      (pll_areset_w),
        .pll_scandataout (pll_scandataout),
        .pll_scandone    (pll_scandone),
        .pll_scandata    (rc_scandata),
        .pll_scanclk     (rc_scanclk),
        .pll_scanclkena  (rc_scanclkena),
        .pll_configupdate(rc_configupdate)
    );

    pix_pll u_pix_pll (
        .inclk0          (clk50),
        .areset          (pll_areset_w | ~rst_n),
        .scandata        (rc_scandata),
        .scanclk         (rc_scanclk),
        .scanclkena      (rc_scanclkena),
        .configupdate    (rc_configupdate),
        .c0              (pclk),
        .locked          (pll_locked),
        .scandataout     (pll_scandataout),
        .scandone        (pll_scandone)
    );

endmodule
