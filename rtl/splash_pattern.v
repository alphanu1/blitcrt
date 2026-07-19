// splash_pattern.v -- test card: SMPTE bars + border + mode readout
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// BlitCRT test card. Combinational from scan position -- no RAM, no host.
// Draws 8 SMPTE colour bars, a 1px white border, and a two-line readout:
//     line A:  <hact> x <vact>
//     line B:  <vfreq> HZ   <pclk> MHZ
// e.g. "320x240" / "60.01HZ 6.400MHZ". Digits track live timing (res) and
// the measured meters (vfreq centi-Hz, pclk kHz), so a SET_MODE updates
// them immediately. 8x8 font, 1x scale, two rows near the top-left.
//
// The top keeps this card visible until the first real CMD_FRAME (not the
// first SET_MODE), so resolutions can be switched over UART and confirmed
// on the CRT without streaming a frame.

module splash_pattern (
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,
    input  wire [11:0] hact,
    input  wire [11:0] vact,
    input  wire [15:0] vfreq_bcd,   // centi-Hz digits {d3,d2,d1,d0} = DD.DD
    input  wire [15:0] pclk_bcd,    // kHz digits {d3,d2,d1,d0} = D.DDD MHz
    output reg  [11:0] rgb          // RGB444
);
    // ---- colour bars ----
    wire [11:0] e1 = hact >> 3;
    wire [11:0] e2 = hact >> 2;
    wire [11:0] e3 = e2 + e1;
    wire [11:0] e4 = hact >> 1;
    wire [11:0] e5 = e4 + e1;
    wire [11:0] e6 = e4 + e2;
    wire [11:0] e7 = e6 + e1;
    wire border = de && ((x==12'd0)||(y==12'd0)||(x==hact-12'd1)||(y==vact-12'd1));
    reg [11:0] bars;
    always @* begin
        if      (x < e1) bars = 12'hFFF;
        else if (x < e2) bars = 12'hFF0;
        else if (x < e3) bars = 12'h0FF;
        else if (x < e4) bars = 12'h0F0;
        else if (x < e5) bars = 12'hF0F;
        else if (x < e6) bars = 12'hF00;
        else if (x < e7) bars = 12'h00F;
        else             bars = 12'h000;
    end

    // ---- glyph codes ----
    // 0-9 digits; 10='x'; 11=' '; 12='H'; 13='Z'; 14='.'; 15='M'
    localparam [3:0] GX=10, GSP=11, GH=12, GZ=13, GDOT=14, GM=15;

    // resolution digits (leading-zero blanked)
    wire [3:0] h_th=(hact/1000)%10, h_h=(hact/100)%10, h_t=(hact/10)%10, h_o=hact%10;
    wire [3:0] v_th=(vact/1000)%10, v_h=(vact/100)%10, v_t=(vact/10)%10, v_o=vact%10;
    wire [3:0] rh0=(h_th!=0)?h_th:GSP;
    wire [3:0] rh1=(h_th!=0||h_h!=0)?h_h:GSP;
    wire [3:0] rh2=(h_th!=0||h_h!=0||h_t!=0)?h_t:GSP;
    wire [3:0] rv0=(v_th!=0)?v_th:GSP;
    wire [3:0] rv1=(v_th!=0||v_h!=0)?v_h:GSP;
    wire [3:0] rv2=(v_th!=0||v_h!=0||v_t!=0)?v_t:GSP;

    // meter digits
    wire [3:0] f3=vfreq_bcd[15:12], f2=vfreq_bcd[11:8], f1=vfreq_bcd[7:4], f0=vfreq_bcd[3:0];
    wire [3:0] p3=pclk_bcd[15:12],  p2=pclk_bcd[11:8],  p1=pclk_bcd[7:4],  p0=pclk_bcd[3:0];
    wire [3:0] vf0=(f3!=0)?f3:GSP;   // tens of Hz, blank if 0

    // ---- two text rows, 1x 8x8 font ----
    localparam [11:0] TX0 = 12'd16;
    localparam [11:0] TYA = 12'd16;   // row A baseline
    localparam [11:0] TYB = 12'd28;   // row B baseline (12px below)

    wire in_rowA = de && (y >= TYA) && (y < TYA + 12'd8);
    wire in_rowB = de && (y >= TYB) && (y < TYB + 12'd8);
    wire in_rows = in_rowA || in_rowB;

    wire [11:0] rel_x = x - TX0;
    wire [7:0]  tcell = rel_x[11:3];              // /8
    wire [2:0]  gx    = rel_x[2:0];               // 0..7 within glyph
    wire [2:0]  gy    = in_rowA ? (y - TYA) : (y - TYB);

    // row A cells: H H H H x V V V V  (0..8)
    reg [3:0] gA;
    always @* case (tcell)
        8'd0: gA=rh0; 8'd1: gA=rh1; 8'd2: gA=rh2; 8'd3: gA=h_o;
        8'd4: gA=GX;
        8'd5: gA=rv0; 8'd6: gA=rv1; 8'd7: gA=rv2; 8'd8: gA=v_o;
        default: gA=GSP;
    endcase
    wire in_rowA_x = in_rowA && (tcell < 8'd9);

    // row B cells: f3 f2 . f1 f0 H Z sp p3 . p2 p1 p0 M H Z  (0..15)
    reg [3:0] gB;
    always @* case (tcell)
        8'd0:  gB=vf0;  8'd1:  gB=f2;   8'd2:  gB=GDOT; 8'd3:  gB=f1;
        8'd4:  gB=f0;   8'd5:  gB=GH;   8'd6:  gB=GZ;   8'd7:  gB=GSP;
        8'd8:  gB=p3;   8'd9:  gB=GDOT; 8'd10: gB=p2;   8'd11: gB=p1;
        8'd12: gB=p0;   8'd13: gB=GM;   8'd14: gB=GH;   8'd15: gB=GZ;
        default: gB=GSP;
    endcase
    wire in_rowB_x = in_rowB && (tcell < 8'd16);

    wire [3:0] gsel = in_rowA ? gA : gB;
    wire in_text_x  = in_rowA ? in_rowA_x : in_rowB_x;

    // 8x8 font
    function [7:0] frow;
        input [3:0] g; input [2:0] r;
        begin case (g)
        4'd0: case(r) 0:frow=8'b00111100;1:frow=8'b01100110;2:frow=8'b01101110;3:frow=8'b01110110;4:frow=8'b01100110;5:frow=8'b01100110;6:frow=8'b00111100;default:frow=0;endcase
        4'd1: case(r) 0:frow=8'b00011000;1:frow=8'b00111000;2:frow=8'b00011000;3:frow=8'b00011000;4:frow=8'b00011000;5:frow=8'b00011000;6:frow=8'b01111110;default:frow=0;endcase
        4'd2: case(r) 0:frow=8'b00111100;1:frow=8'b01100110;2:frow=8'b00000110;3:frow=8'b00001100;4:frow=8'b00110000;5:frow=8'b01100000;6:frow=8'b01111110;default:frow=0;endcase
        4'd3: case(r) 0:frow=8'b00111100;1:frow=8'b01100110;2:frow=8'b00000110;3:frow=8'b00011100;4:frow=8'b00000110;5:frow=8'b01100110;6:frow=8'b00111100;default:frow=0;endcase
        4'd4: case(r) 0:frow=8'b00001100;1:frow=8'b00011100;2:frow=8'b00111100;3:frow=8'b01101100;4:frow=8'b01111110;5:frow=8'b00001100;6:frow=8'b00001100;default:frow=0;endcase
        4'd5: case(r) 0:frow=8'b01111110;1:frow=8'b01100000;2:frow=8'b01111100;3:frow=8'b00000110;4:frow=8'b00000110;5:frow=8'b01100110;6:frow=8'b00111100;default:frow=0;endcase
        4'd6: case(r) 0:frow=8'b00111100;1:frow=8'b01100000;2:frow=8'b01111100;3:frow=8'b01100110;4:frow=8'b01100110;5:frow=8'b01100110;6:frow=8'b00111100;default:frow=0;endcase
        4'd7: case(r) 0:frow=8'b01111110;1:frow=8'b00000110;2:frow=8'b00001100;3:frow=8'b00011000;4:frow=8'b00110000;5:frow=8'b00110000;6:frow=8'b00110000;default:frow=0;endcase
        4'd8: case(r) 0:frow=8'b00111100;1:frow=8'b01100110;2:frow=8'b01100110;3:frow=8'b00111100;4:frow=8'b01100110;5:frow=8'b01100110;6:frow=8'b00111100;default:frow=0;endcase
        4'd9: case(r) 0:frow=8'b00111100;1:frow=8'b01100110;2:frow=8'b01100110;3:frow=8'b00111110;4:frow=8'b00000110;5:frow=8'b01100110;6:frow=8'b00111100;default:frow=0;endcase
        4'd10:case(r) 0:frow=8'b00000000;1:frow=8'b01100110;2:frow=8'b00111100;3:frow=8'b00011000;4:frow=8'b00111100;5:frow=8'b01100110;6:frow=8'b00000000;default:frow=0;endcase // x
        4'd12:case(r) 0:frow=8'b01100110;1:frow=8'b01100110;2:frow=8'b01100110;3:frow=8'b01111110;4:frow=8'b01100110;5:frow=8'b01100110;6:frow=8'b01100110;default:frow=0;endcase // H
        4'd13:case(r) 0:frow=8'b01111110;1:frow=8'b00000110;2:frow=8'b00001100;3:frow=8'b00011000;4:frow=8'b00110000;5:frow=8'b01100000;6:frow=8'b01111110;default:frow=0;endcase // Z
        4'd14:case(r) 0:frow=8'b00000000;1:frow=8'b00000000;2:frow=8'b00000000;3:frow=8'b00000000;4:frow=8'b00000000;5:frow=8'b00011000;6:frow=8'b00011000;default:frow=0;endcase // .
        4'd15:case(r) 0:frow=8'b01100110;1:frow=8'b01111110;2:frow=8'b01111110;3:frow=8'b01011010;4:frow=8'b01000010;5:frow=8'b01000010;6:frow=8'b01000010;default:frow=0;endcase // M
        default: frow=0; // space
        endcase end
    endfunction

    wire [7:0] rowbits   = frow(gsel, gy);
    wire       text_pix  = in_text_x && in_rows && rowbits[3'd7 - gx];
    wire       text_plate= in_text_x && in_rows;

    always @* begin
        if (!de)              rgb = 12'h000;
        else if (text_pix)    rgb = 12'h000;   // black glyph
        else if (text_plate)  rgb = 12'hFFF;   // white plate
        else if (border)      rgb = 12'hFFF;
        else                  rgb = bars;
    end
endmodule
