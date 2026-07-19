`timescale 1ns/1ps
// tb_uart_rx.v -- feed 8N1 serial bytes, verify decode
// Author: Ben Templeman (alphanu1)
module tb_uart_rx;
    localparam CLKS_PER_BIT = 16;             // matches DUT default
    reg clk=0, rst_n=0; always #10 clk=~clk;  // 50MHz, 20ns period
    reg rx=1;                                   // idle high
    wire [7:0] byte_data;
    wire       byte_valid;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut(
        .clk(clk),.rst_n(rst_n),.rx(rx),
        .byte_data(byte_data),.byte_valid(byte_valid));

    // one bit time = CLKS_PER_BIT * 20ns
    localparam integer BIT_NS = CLKS_PER_BIT*20;

    task send_byte(input [7:0] b);
        integer i;
        begin
            rx = 1'b0; #(BIT_NS);             // start bit
            for (i=0;i<8;i=i+1) begin
                rx = b[i]; #(BIT_NS);         // LSB first
            end
            rx = 1'b1; #(BIT_NS);             // stop bit
        end
    endtask

    integer got=0, errors=0;
    reg [7:0] rxbuf [0:3];
    always @(posedge clk) if (byte_valid) begin
        rxbuf[got] = byte_data; got = got + 1;
    end

    initial begin
        #100 rst_n=1;
        #200;
        send_byte(8'h43);   // 'C'
        send_byte(8'h52);   // 'R'
        send_byte(8'h54);   // 'T'
        send_byte(8'h31);   // '1'
        #(BIT_NS*4);

        if (got!=4) begin $display("FAIL got=%0d want 4",got); errors=errors+1; end
        if (rxbuf[0]!==8'h43||rxbuf[1]!==8'h52||rxbuf[2]!==8'h54||rxbuf[3]!==8'h31) begin
            $display("FAIL bytes %h %h %h %h",rxbuf[0],rxbuf[1],rxbuf[2],rxbuf[3]);
            errors=errors+1;
        end
        if (errors==0) $display("ALL CHECKS PASSED (decoded CRT1)");
        else $display("%0d FAILED",errors);
        $finish;
    end
endmodule
