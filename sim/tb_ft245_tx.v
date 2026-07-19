`timescale 1ns/1ps
// tb_ft245_tx.v -- exercise the FT245 async write engine
// Author: Ben Templeman (alphanu1)
module tb_ft245_tx;
    reg clk=0, rst_n=0; always #10 clk=~clk;   // 50MHz
    reg        txe_n=0;                          // FTDI ready (has room)
    reg  [7:0] tx_data=8'h00;
    reg        tx_valid=0;
    wire [7:0] ft_data_out;
    wire       ft_oe, wr_n, tx_ready;

    ft245_tx dut(.clk(clk),.rst_n(rst_n),.txe_n_raw(txe_n),
        .ft_data_out(ft_data_out),.ft_oe(ft_oe),.wr_n(wr_n),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));

    integer errors=0, writes=0;
    reg [7:0] captured [0:3];
    integer widx=0;

    // Capture data on WR# rising edge (that's when FTDI latches)
    reg wr_n_d;
    always @(posedge clk) begin
        wr_n_d <= wr_n;
        if (wr_n && !wr_n_d) begin      // rising edge of WR#
            if (!ft_oe)
                $display("FAIL: OE not asserted during latch");
            captured[widx] = ft_data_out;
            widx = widx + 1;
        end
        if (tx_ready) writes = writes + 1;
    end

    task send(input [7:0] b);
        begin
            @(posedge clk); tx_data<=b; tx_valid<=1;
            // hold valid until accepted
            wait(tx_ready==1'b1);
            @(posedge clk); tx_valid<=0;
            // wait for engine to return to idle before next
            repeat(10) @(posedge clk);
        end
    endtask

    initial begin
        #50 rst_n=1;
        repeat(4) @(posedge clk);
        send(8'hC3);
        send(8'h31);        // 'CRT1' magic low bytes as a token test
        send(8'hA5);
        send(8'h5A);
        repeat(10) @(posedge clk);

        if (writes != 4) begin
            $display("FAIL: writes=%0d want 4", writes); errors=errors+1; end
        if (captured[0]!==8'hC3||captured[1]!==8'h31||
            captured[2]!==8'hA5||captured[3]!==8'h5A) begin
            $display("FAIL: captured %h %h %h %h",
                captured[0],captured[1],captured[2],captured[3]);
            errors=errors+1;
        end

        // Test back-pressure: TXE# high (no room) -> no write
        widx=0;
        txe_n=1;                        // FTDI full
        @(posedge clk); tx_data<=8'hFF; tx_valid<=1;
        repeat(20) @(posedge clk);
        if (widx != 0) begin
            $display("FAIL: wrote while TXE# high"); errors=errors+1; end
        tx_valid<=0; txe_n=0;

        if (errors==0) $display("ALL CHECKS PASSED");
        else $display("%0d FAILED", errors);
        $finish;
    end
endmodule
