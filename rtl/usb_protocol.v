//=============================================================================
// usb_protocol.v -- byte-stream parser for the framebuffer link
//
// Wire protocol (host -> FPGA), byte oriented:
//
//   Frame upload:    AA 55 01 <38400 bytes>
//                    Raster order, top-left first. 2 pixels per byte:
//                    byte = (pix[2i] << 4) | pix[2i+1]   (even px = high nib)
//
//   Palette upload:  AA 55 02 <32 bytes>
//                    16 entries x 2 bytes, big-endian per entry:
//                    byte0 = 0x0R, byte1 = 0xGB  ->  color = {R,G,B}
//
// Robustness: any unknown command drops back to sync hunting. A watchdog
// (~168ms of link silence mid-message) also resets the parser, so a torn
// USB transfer can't wedge the FSM -- the host just resends the frame.
// The AA 55 sync word can appear inside pixel data; that's fine, we only
// hunt for it when we're not inside a known-length payload.
//=============================================================================
module usb_protocol (
    input  wire        clk,       // 50MHz
    input  wire        rst_n,

    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    output reg         fb_we,
    output reg  [15:0] fb_addr,
    output reg  [7:0]  fb_data,

    output reg         pal_we,
    output reg  [3:0]  pal_index,
    output reg  [11:0] pal_color
);

    localparam [15:0] FRAME_BYTES = 16'd38400;   // 320*240/2
    localparam [7:0]  SYNC0     = 8'hAA,
                      SYNC1     = 8'h55,
                      CMD_FRAME = 8'h01,
                      CMD_PAL   = 8'h02;

    localparam [2:0] S_SYNC0  = 3'd0,
                     S_SYNC1  = 3'd1,
                     S_CMD    = 3'd2,
                     S_FRAME  = 3'd3,
                     S_PAL_HI = 3'd4,
                     S_PAL_LO = 3'd5;

    reg [2:0]  state;
    reg [15:0] cnt;
    reg [3:0]  pal_hi;

    // watchdog: 2^23 / 50MHz ~= 168ms
    reg [22:0] idle_cnt;
    wire       timeout = (idle_cnt == 23'h7FFFFF);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            idle_cnt <= 23'd0;
        else if (rx_valid || state == S_SYNC0)
            idle_cnt <= 23'd0;
        else if (!timeout)
            idle_cnt <= idle_cnt + 23'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_SYNC0;
            cnt       <= 16'd0;
            fb_we     <= 1'b0;
            fb_addr   <= 16'd0;
            fb_data   <= 8'd0;
            pal_we    <= 1'b0;
            pal_index <= 4'd0;
            pal_color <= 12'd0;
            pal_hi    <= 4'd0;
        end else begin
            fb_we  <= 1'b0;
            pal_we <= 1'b0;

            if (timeout) begin
                state <= S_SYNC0;
            end else if (rx_valid) begin
                case (state)
                    S_SYNC0:
                        if (rx_data == SYNC0) state <= S_SYNC1;

                    S_SYNC1:
                        if      (rx_data == SYNC1) state <= S_CMD;
                        else if (rx_data != SYNC0) state <= S_SYNC0;
                        // AA AA 55 still syncs

                    S_CMD: begin
                        cnt <= 16'd0;
                        case (rx_data)
                            CMD_FRAME: state <= S_FRAME;
                            CMD_PAL:   state <= S_PAL_HI;
                            default:   state <= S_SYNC0;
                        endcase
                    end

                    S_FRAME: begin
                        fb_we   <= 1'b1;
                        fb_addr <= cnt;
                        fb_data <= rx_data;
                        cnt     <= cnt + 16'd1;
                        if (cnt == FRAME_BYTES - 1)
                            state <= S_SYNC0;
                    end

                    S_PAL_HI: begin
                        pal_hi <= rx_data[3:0];
                        cnt    <= cnt + 16'd1;
                        state  <= S_PAL_LO;
                    end

                    S_PAL_LO: begin
                        pal_we    <= 1'b1;
                        pal_index <= cnt[4:1];
                        pal_color <= {pal_hi, rx_data};
                        cnt       <= cnt + 16'd1;
                        state     <= (cnt == 16'd31) ? S_SYNC0 : S_PAL_HI;
                    end

                    default: state <= S_SYNC0;
                endcase
            end
        end
    end

endmodule
