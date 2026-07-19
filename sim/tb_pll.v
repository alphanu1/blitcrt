`timescale 1ns/1ps
module tb_pll;
    reg clk=0, rst_n=0, req=0; always #10 clk=~clk;
    reg [31:0] c_div=125, m_mul=16, n_div=1;
    wire busy, pclk, locked;
    reg ra_busy=0, pll_locked_in=1;
    wire [3:0] ct; wire [2:0] cp; wire [8:0] di;
    wire wr, rc; wire [8:0] cub;

    pll_ctl dut(.clk(clk),.rst_n(rst_n),.req(req),
        .c_div(c_div),.m_mul(m_mul),.n_div(n_div),.busy(busy),
        .pclk(pclk),.locked(locked),
        .ra_counter_type(ct),.ra_counter_param(cp),.ra_data_in(di),
        .ra_write_param(wr),.ra_reconfig(rc),.ra_busy(ra_busy),
        .pll_configupdate_bus(cub),.pll_locked_in(pll_locked_in));

    integer writes=0, errors=0;
    reg saw_reconfig=0, saw_high=0, saw_low=0, saw_odd=0, saw_byp=0;
    always @(posedge clk) begin
        if (wr) begin
            writes = writes+1;
            if (cp==3'd0) begin saw_high=1; if(di!==9'd63) begin $display("FAIL high=%0d want 63",di); errors=errors+1; end end
            if (cp==3'd1) begin saw_low=1;  if(di!==9'd62) begin $display("FAIL low=%0d want 62",di); errors=errors+1; end end
            if (cp==3'd4) begin saw_odd=1;  if(di!==9'd1)  begin $display("FAIL odd=%0d want 1",di); errors=errors+1; end end
            if (cp==3'd2) begin saw_byp=1;  if(di!==9'd0)  begin $display("FAIL byp=%0d want 0",di); errors=errors+1; end end
        end
        if (rc) saw_reconfig=1;
    end

    initial begin
        #50 rst_n=1;
        // C=125 (odd): high=63, low=62, odd=1, byp=0
        #20 @(posedge clk); req<=1; @(posedge clk); req<=0;
        // let the sequence run; emulate reconfig busy for a bit
        #40 ra_busy=1; #100 ra_busy=0;
        #200;
        if (!busy) $display("busy deasserted after lock: OK");
        else begin $display("FAIL busy stuck"); errors=errors+1; end
        if (writes!=4) begin $display("FAIL writes=%0d want 4",writes); errors=errors+1; end
        if (!(saw_high&&saw_low&&saw_odd&&saw_byp&&saw_reconfig)) begin
            $display("FAIL missing step h%b l%b o%b b%b r%b",saw_high,saw_low,saw_odd,saw_byp,saw_reconfig);
            errors=errors+1; end
        if (errors==0) $display("ALL CHECKS PASSED"); else $display("%0d FAILED",errors);
        $finish;
    end
endmodule
