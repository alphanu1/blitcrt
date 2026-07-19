`timescale 1ns/1ps
module tb_splash;
    reg [11:0] x=0, y=1; reg de=1;
    wire [11:0] rgb;
    splash_pattern sp(.x(x),.y(y),.de(de),.hact(12'd320),.vact(12'd240),.rgb(rgb));
    integer errors=0;
    task chk(input [11:0] xx, input [11:0] want, input [79:0] name);
        begin x=xx; #1;
        if (rgb!==want) begin $display("FAIL %0s: x=%0d got %h want %h",name,xx,rgb,want); errors=errors+1; end
        end
    endtask
    initial begin
        chk(0,   12'hFFF, "border_left");
        chk(20,  12'hFFF, "white");
        chk(60,  12'hFF0, "yellow");
        chk(100, 12'h0FF, "cyan");
        chk(140, 12'h0F0, "green");
        chk(180, 12'hF0F, "magenta");
        chk(220, 12'hF00, "red");
        chk(260, 12'h00F, "blue");
        chk(300, 12'h000, "black");
        chk(319, 12'hFFF, "border_right");
        y=0; chk(150, 12'hFFF, "border_top");
        y=239; chk(150, 12'hFFF, "border_bot");
        de=0; y=100; chk(150, 12'h000, "blanking");
        if (errors==0) $display("ALL CHECKS PASSED"); else $display("%0d FAILED",errors);
        $finish;
    end
endmodule
