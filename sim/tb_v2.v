`timescale 1ns/1ps
module tb_v2;
    reg clk = 0, pclk = 0, rst_n = 0;
    always #10 clk = ~clk;      // 50MHz
    always #78 pclk = ~pclk;    // ~6.4MHz

    // packet engine
    reg  [7:0] rx_data = 0; reg rx_valid = 0;
    wire [7:0] tx_data; wire tx_valid; reg tx_ready = 1;
    wire ld_stb; wire [11:0] ld_ha,ld_hb,ld_he,ld_ht,ld_va,ld_vb,ld_ve,ld_vt;
    wire pll_req; wire [31:0] pll_m,pll_n,pll_c;
    wire fb_we; wire [16:0] fb_waddr; wire [7:0] fb_wdata;
    wire pal_we; wire [3:0] pal_index; wire [11:0] pal_rgb;

    crt1_ft245 dut (
        .clk_sys(clk), .rst_n(rst_n),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .ld_toggle(ld_stb),
        .ld_hactive(ld_ha), .ld_hbegin(ld_hb), .ld_hend(ld_he), .ld_htotal(ld_ht),
        .ld_vactive(ld_va), .ld_vbegin(ld_vb), .ld_vend(ld_ve), .ld_vtotal(ld_vt),
        .pll_req(pll_req), .pll_m(pll_m), .pll_n(pll_n), .pll_c(pll_c),
        .pll_busy(1'b0),
        .fb_we(fb_we), .fb_waddr(fb_waddr), .fb_wdata(fb_wdata),
        .pal_we(pal_we), .pal_index(pal_index), .pal_rgb(pal_rgb));

    // proper CDC: 2FF sync of the toggle into pclk + edge detect
    reg [2:0] tgl_sync = 0;
    always @(posedge pclk) tgl_sync <= {tgl_sync[1:0], ld_stb};
    wire stb_p = tgl_sync[2] ^ tgl_sync[1];
    wire [11:0] x,y; wire de,hs_n,vs_n,frame_start;
    video_timing_prog vt (
        .pclk(pclk), .rst_n(rst_n),
        .ld_stb(stb_p),
        .ld_hactive(ld_ha), .ld_hbegin(ld_hb), .ld_hend(ld_he), .ld_htotal(ld_ht),
        .ld_vactive(ld_va), .ld_vbegin(ld_vb), .ld_vend(ld_ve), .ld_vtotal(ld_vt),
        .force_load(1'b1),
        .x(x), .y(y), .de(de), .hs_n(hs_n), .vs_n(vs_n), .frame_start(frame_start));

    task send(input [7:0] b);
        begin @(posedge clk); rx_data <= b; rx_valid <= 1; @(posedge clk); rx_valid <= 0; end
    endtask
    task send_hdr(input [7:0] c, input [15:0] s, input [31:0] l);
        begin
            send(8'h43); send(8'h52); send(8'h54); send(8'h31);
            send(c); send(8'h00); send(s[7:0]); send(s[15:8]);
            send(l[7:0]); send(l[15:8]); send(l[23:16]); send(l[31:24]);
        end
    endtask
    task send16(input [15:0] v); begin send(v[7:0]); send(v[15:8]); end endtask
    task send32(input [31:0] v); begin send16(v[15:0]); send16(v[31:16]); end endtask

    integer txcount = 0; reg [7:0] txlog [0:63];
    always @(posedge clk) if (tx_valid && tx_ready && txcount < 64) begin
        txlog[txcount] = tx_data; txcount = txcount + 1;
    end

    integer errors = 0;
    task expect(input [31:0] got, input [31:0] want, input [127:0] name);
        if (got !== want) begin
            $display("FAIL %0s: got %0d want %0d", name, got, want);
            errors = errors + 1;
        end
    endtask

    // measure one hsync period after mode load
    time t_hs0, t_hs1;
    initial begin
        #200 rst_n = 1;

        // garbage before magic (resync test)
        send(8'hDE); send(8'hAD);

        // SET_MODE: 384x224 in 456x261 (the "55Hz oddity" geometry)
        send_hdr(8'h10, 16'h0007, 32'd32);
        send32(32'd7156800);                 // pclock (informational)
        send16(384); send16(396); send16(432); send16(456);
        send16(224); send16(232); send16(235); send16(261);
        send16(0);                            // mode_flags
        send(8'd1); send(8'd0);               // pixfmt, pad
        send32(0); send32(0);                 // host_tag

        // SET_PLL: m=447 n=25 c=125 -> 50e6*447/25/125 = 7.1520MHz
        send_hdr(8'h11, 16'h0008, 32'd12);
        send32(447); send32(25); send32(125);

        // GET_INFO
        send_hdr(8'h01, 16'h0009, 32'd0);

        // let timing core run with the new geometry, measure hsync
        #2000;
        @(negedge hs_n); t_hs0 = $time;
        @(negedge hs_n); t_hs1 = $time;

        // checks
        expect(ld_ha, 384, "hactive");
        expect(ld_vt, 261, "vtotal");
        expect(pll_m, 447, "pll_m");
        expect(pll_c, 125, "pll_c");
        // htotal=456 pclk period 156ns -> line = 71.136us
        expect((t_hs1 - t_hs0), 456*156, "hsync_period_ns");
        // replies arrived: MODE_RESULT(20) + STATUS(16) + INFO(20) = 56
        expect(txcount, 56, "tx_bytes");
        // first reply is EVT_MODE_RESULT (0x90) with our seq 0x0007
        expect(txlog[4], 8'h90, "evt_mode_result");
        expect(txlog[6], 8'h07, "seq_echo");
        // INFO reply carries MAX dims 384x288
        expect({txlog[53],txlog[52]}, 16'd384, "info_max_w");
        expect({txlog[55],txlog[54]}, 16'd288, "info_max_h");

        if (errors == 0) $display("ALL CHECKS PASSED");
        else $display("%0d CHECKS FAILED", errors);
        $finish;
    end
endmodule
