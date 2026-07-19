`timescale 1ns/1ps
//=============================================================================
// tb_fb_top.v -- smoke test (iverilog)
//   * behavioral pix_pll stub (6.4MHz)
//   * behavioral FT245 model driving the async FIFO handshake
//   * sends palette + one full frame, checks framebuffer contents
//   * measures hsync and vsync periods
//=============================================================================

// ---- PLL stub --------------------------------------------------------------
module pix_pll (input inclk0, output reg c0, output reg locked);
    initial begin
        c0 = 0;
        locked = 0;
        #200 locked = 1;
    end
    always #78.125 c0 = ~c0;   // 6.4MHz
endmodule

// ---- TB --------------------------------------------------------------------
module tb_fb_top;

    reg clk50 = 0;
    always #10 clk50 = ~clk50;

    reg rst_n = 0;

    // FT245 model signals
    reg        rxf_n = 1;
    reg  [7:0] fifo_data = 8'hZZ;
    wire       rd_n, wr_n;

    wire [3:0] vid_r, vid_g, vid_b;
    wire vid_hs_n, vid_vs_n, vid_cs_n;

    fb_top dut (
        .clk50(clk50), .rst_n(rst_n),
        .ft_rxf_n(rxf_n), .ft_data(fifo_data),
        .ft_rd_n(rd_n), .ft_wr_n(wr_n),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_hs_n(vid_hs_n), .vid_vs_n(vid_vs_n), .vid_cs_n(vid_cs_n)
    );

    // ---- FT245 behavioral model: present one byte, honor RD# ---------------
    task send_byte(input [7:0] b);
        begin
            fifo_data = b;
            #15 rxf_n = 0;              // byte available
            @(negedge rd_n);
            @(posedge rd_n);            // FPGA sampled during low phase
            #14 rxf_n = 1;              // RXF# deasserts after read
            #85;                        // inter-byte gap
        end
    endtask

    integer i, errors;
    reg [7:0] expect_b;

    // ---- hsync / vsync period measurement -----------------------------------
    realtime t_hs_last, t_hs_period;
    realtime t_vs_last, t_vs_period;
    initial begin t_hs_last=0; t_hs_period=0; t_vs_last=0; t_vs_period=0; end
    always @(negedge vid_hs_n) begin
        if (t_hs_last != 0) t_hs_period = $realtime - t_hs_last;
        t_hs_last = $realtime;
    end
    always @(negedge vid_vs_n) begin
        if (t_vs_last != 0) t_vs_period = $realtime - t_vs_last;
        t_vs_last = $realtime;
    end

    initial begin
        errors = 0;
        #100 rst_n = 1;
        #1000;

        // palette upload: AA 55 02 + 32 bytes (entry n = 0x0n, 0xnn)
        send_byte(8'hAA); send_byte(8'h55); send_byte(8'h02);
        for (i = 0; i < 16; i = i + 1) begin
            send_byte({4'h0, i[3:0]});
            send_byte({i[3:0], i[3:0]});
        end

        // frame upload: AA 55 01 + 38400 bytes, byte value = addr[7:0]
        send_byte(8'hAA); send_byte(8'h55); send_byte(8'h01);
        for (i = 0; i < 38400; i = i + 1)
            send_byte(i[7:0]);

        #2000;

        // check framebuffer contents (spot check + endpoints)
        for (i = 0; i < 38400; i = i + 383) begin
            expect_b = i[7:0];
            if (dut.u_fb.mem[i] !== expect_b) begin
                errors = errors + 1;
                if (errors < 10)
                    $display("FB MISMATCH addr=%0d got=%02x want=%02x",
                             i, dut.u_fb.mem[i], expect_b);
            end
        end
        if (dut.u_fb.mem[38399] !== 8'hFF)  // 38399 % 256 = 0xFF
            begin errors = errors + 1; $display("FB last byte wrong: %02x", dut.u_fb.mem[38399]); end

        // check palette
        for (i = 0; i < 16; i = i + 1)
            if (dut.u_pal.pal[i] !== {i[3:0], i[3:0], i[3:0]}) begin
                errors = errors + 1;
                $display("PAL MISMATCH %0d = %03x", i, dut.u_pal.pal[i]);
            end

        // parser must be back at sync hunt
        if (dut.u_proto.state !== 3'd0)
            begin errors = errors + 1; $display("parser not back in S_SYNC0"); end

        // let video run a couple frames for period measurement
        #35_000_000;

        $display("hsync period = %0.1f ns  (%0.3f kHz)  [expect 63593.75 ns / 15.724 kHz]",
                 t_hs_period, 1e6/t_hs_period);
        $display("vsync period = %0.1f ns  (%0.3f Hz)   [expect 16661562.5 ns / 60.02 Hz]",
                 t_vs_period, 1e9/t_vs_period);

        if (t_hs_period < 63500.0 || t_hs_period > 63700.0)
            begin errors = errors + 1; $display("HSYNC PERIOD OUT OF RANGE"); end
        if (t_vs_period < 16600000.0 || t_vs_period > 16720000.0)
            begin errors = errors + 1; $display("VSYNC PERIOD OUT OF RANGE"); end

        if (errors == 0) $display("*** PASS ***");
        else             $display("*** FAIL: %0d errors ***", errors);
        $finish;
    end

endmodule
