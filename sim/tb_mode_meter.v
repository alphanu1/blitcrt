`timescale 1ns/1ps
// tb_mode_meter.v -- verify fractional refresh + pixel clock measurement
// Author: Ben Templeman (alphanu1)
module tb_mode_meter;
  reg clk=0,rst_n=0,fp=0; always #10 clk=~clk;
  reg [11:0] ht=407, vt=262;
  wire [15:0] vf,pc;
  mode_meter dut(.clk50(clk),.rst_n(rst_n),.frame_pulse(fp),.htotal(ht),.vtotal(vt),
                 .vfreq_bcd(vf),.pclk_bcd(pc));
  integer TPF = 833078;   // ~60.01 Hz frame period in 50MHz ticks
  integer i;
  initial begin
    #50 rst_n=1; @(negedge clk);
    fp=1; @(negedge clk); fp=0;
    for (i=0;i<TPF-1;i=i+1) @(negedge clk);
    fp=1; @(negedge clk); fp=0;               // latch period
    for (i=0;i<50;i=i+1) @(negedge clk);
    fp=1; @(negedge clk); fp=0;               // trigger divide
    for (i=0;i<300;i=i+1) @(negedge clk);
    $display("vfreq = %0d%0d.%0d%0d HZ",vf[15:12],vf[11:8],vf[7:4],vf[3:0]);
    $display("pclk  = %0d.%0d%0d%0d MHZ",pc[15:12],pc[11:8],pc[7:4],pc[3:0]);
    if (vf==16'h6001 && pc==16'h6400) $display("MODE METER OK");
    else $display("FAIL vf=%h pc=%h",vf,pc);
    $finish;
  end
endmodule
