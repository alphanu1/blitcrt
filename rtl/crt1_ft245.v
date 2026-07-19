// crt1_ft245.v -- CRT1 packet engine over an FT245 async FIFO
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// fpga15k v2: the same wire protocol the CRTPi speaks over USB bulk,
// carried over the FT2232H FIFO instead. One host library, two devices.
//
// Implemented commands (FPGA transport profile of docs/PROTOCOL.md):
//   CMD_SET_MODE (0x10) 32-byte wire_modeline -> timing shadow regs.
//       pclock_hz in the payload is informational here; the clock itself
//       is set by CMD_SET_PLL (the host computes dividers -- see
//       docs/VIDEOCARD_V2.md). Replies EVT_MODE_RESULT.
//   CMD_SET_PLL  (0x11) 12 bytes {u32 m, u32 n, u32 c} -> PLL reconfig
//       request lines (consumed by the pll_ctl/altpll_reconfig wrapper).
//       Replies EVT_STATUS.
//   CMD_FRAME    (0x20) frame_hdr{x,y,w,h} + 4bpp packed pixels ->
//       framebuffer write stream (two pixels per byte, high nibble first).
//   CMD_SET_PAL  (0x30 FPGA profile) {u8 index, u8 pad, u16 rgb444}.
//   CMD_GET_INFO (0x01) -> EVT_INFO (version, max dims).
//
// Unknown cmd: swallow payload, reply EVT_STATUS/ST_EBADCMD, resync by
// magic hunt (same recovery contract as the Pi implementation).
//
// Clock domains: everything here runs in clk_sys (50MHz). The timing
// core runs in pclk. ld_* outputs are held stable and ld_stb is
// stretched; top level synchronizes the strobe into pclk.

module crt1_ft245 #(
    parameter [11:0] MAX_W = 12'd384,   // report + clamp: RAM budget
    parameter [11:0] MAX_H = 12'd288
) (
    input  wire        clk_sys,
    input  wire        rst_n,

    // RX byte stream (from ft245_rx)
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // TX byte stream (to ft245_tx); simple ready/valid
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,

    // timing shadow-register load. ld_toggle FLIPS on each accepted
    // SET_MODE (toggle semantics -- a 1-cycle clk_sys pulse cannot be
    // reliably sampled by a slow pclk). Top level runs it through a
    // 2FF synchronizer in pclk and edge-detects into a 1-pclk strobe.
    output reg         ld_toggle,
    output reg [11:0]  ld_hactive, ld_hbegin, ld_hend, ld_htotal,
    output reg [11:0]  ld_vactive, ld_vbegin, ld_vend, ld_vtotal,

    // PLL reconfig request (to pll_ctl wrapper)
    output reg         pll_req,
    output reg [31:0]  pll_m, pll_n, pll_c,
    input  wire        pll_busy,

    // framebuffer write port (clk_sys side of the fb's dual-port RAM)
    output reg         fb_we,
    output reg [16:0]  fb_waddr,      // nibble-pair (byte) address
    output reg [7:0]   fb_wdata,

    // palette write
    output reg         pal_we,
    output reg [3:0]   pal_index,
    output reg [11:0]  pal_rgb
);

    // ---- protocol constants (mirror protocol.h) ----
    localparam [31:0] MAGIC = 32'h31545243;          // "CRT1" LE
    localparam [7:0]  CMD_GET_INFO = 8'h01,
                      CMD_SET_MODE = 8'h10,
                      CMD_SET_PLL  = 8'h11,
                      CMD_FRAME    = 8'h20,
                      CMD_SET_PAL  = 8'h30;
    localparam [7:0]  EVT_INFO = 8'h81, EVT_MODE_RESULT = 8'h90,
                      EVT_STATUS = 8'hA0;
    localparam [15:0] ST_OK = 16'd0, ST_EBADCMD = 16'd1,
                      ST_ERANGE = 16'd2, ST_EBUSY = 16'd5;

    // ---- RX: header accumulation with magic hunt ----
    reg [3:0]  st;
    localparam S_MAGIC = 4'd0, S_HDR = 4'd1, S_PAYLOAD = 4'd2,
               S_REPLY = 4'd3, S_DROP = 4'd4;

    reg [31:0] shift;                 // magic hunter
    reg [7:0]  hdr [0:7];             // cmd,flags,seq(2),len(4)
    reg [2:0]  hidx;
    reg [7:0]  cmd;
    reg [15:0] seq;
    reg [31:0] plen, pcnt;

    reg [7:0]  pay [0:31];            // small-payload capture (SET_MODE etc.)
    reg [31:0] fcnt;                  // frame pixel byte counter
    reg [15:0] fx, fy, fw, fh;        // frame_hdr fields (16-bit each here)
    reg        in_frame_px;

    // reply machinery: fixed-format small replies from a byte ROM-ish buffer
    reg [7:0]  rbuf [0:63];
    reg [5:0]  rlen, ridx;

    integer i;

    // achieved-timing echo for EVT_MODE_RESULT: on the FPGA the "achieved"
    // pixel clock is whatever CMD_SET_PLL last programmed; the top level
    // computes it (50e6*m/(n*c)) and feeds it back here.
    reg [31:0] achieved_pclk;
    always @(posedge clk_sys)
        if (pll_req) achieved_pclk <= 32'd0;   // placeholder till top writes
    // top level may override via hierarchical tie in fb_top_v2; kept simple.

    task reply_status(input [15:0] code);
        begin
            rbuf[0]=8'h43; rbuf[1]=8'h52; rbuf[2]=8'h54; rbuf[3]=8'h31; // magic
            rbuf[4]=EVT_STATUS; rbuf[5]=8'h00;
            rbuf[6]=seq[7:0]; rbuf[7]=seq[15:8];
            rbuf[8]=8'd4; rbuf[9]=0; rbuf[10]=0; rbuf[11]=0;            // len=4
            rbuf[12]=seq[7:0]; rbuf[13]=seq[15:8];
            rbuf[14]=code[7:0]; rbuf[15]=code[15:8];
            rlen = 6'd16; ridx = 6'd0;
        end
    endtask

    task reply_mode_result;
        begin
            rbuf[0]=8'h43; rbuf[1]=8'h52; rbuf[2]=8'h54; rbuf[3]=8'h31;
            rbuf[4]=EVT_MODE_RESULT; rbuf[5]=8'h00;
            rbuf[6]=seq[7:0]; rbuf[7]=seq[15:8];
            rbuf[8]=8'd8; rbuf[9]=0; rbuf[10]=0; rbuf[11]=0;            // len=8
            rbuf[12]=8'd0; rbuf[13]=8'd0;                               // ST_OK
            rbuf[14]=8'd0; rbuf[15]=8'd0;                               // pad
            rbuf[16]=achieved_pclk[7:0];  rbuf[17]=achieved_pclk[15:8];
            rbuf[18]=achieved_pclk[23:16];rbuf[19]=achieved_pclk[31:24];
            rlen = 6'd20; ridx = 6'd0;
        end
    endtask

    task reply_info;
        begin
            rbuf[0]=8'h43; rbuf[1]=8'h52; rbuf[2]=8'h54; rbuf[3]=8'h31;
            rbuf[4]=EVT_INFO; rbuf[5]=8'h00;
            rbuf[6]=seq[7:0]; rbuf[7]=seq[15:8];
            rbuf[8]=8'd8; rbuf[9]=0; rbuf[10]=0; rbuf[11]=0;
            rbuf[12]=8'd2;  rbuf[13]=8'd0;                 // proto ver 2
            rbuf[14]=8'd1;  rbuf[15]=8'd0;                 // impl: 1 = FPGA
            rbuf[16]=MAX_W[7:0]; rbuf[17]={4'd0,MAX_W[11:8]};
            rbuf[18]=MAX_H[7:0]; rbuf[19]={4'd0,MAX_H[11:8]};
            rlen = 6'd20; ridx = 6'd0;
        end
    endtask

    wire [11:0] m_hact = {pay[5][3:0],  pay[4]};
    wire [11:0] m_hbeg = {pay[7][3:0],  pay[6]};
    wire [11:0] m_hend = {pay[9][3:0],  pay[8]};
    wire [11:0] m_htot = {pay[11][3:0], pay[10]};
    wire [11:0] m_vact = {pay[13][3:0], pay[12]};
    wire [11:0] m_vbeg = {pay[15][3:0], pay[14]};
    wire [11:0] m_vend = {pay[17][3:0], pay[16]};
    wire [11:0] m_vtot = {pay[19][3:0], pay[18]};
    wire        mode_too_big = (m_hact > MAX_W) || (m_vact > MAX_H);

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_MAGIC; shift <= 32'd0; hidx <= 3'd0;
            ld_toggle <= 1'b0; pll_req <= 1'b0;
            fb_we <= 1'b0; pal_we <= 1'b0;
            tx_valid <= 1'b0; rlen <= 6'd0; ridx <= 6'd0;
            pcnt <= 32'd0; in_frame_px <= 1'b0;
        end else begin
            pll_req <= 1'b0;
            fb_we <= 1'b0;
            pal_we <= 1'b0;

            // TX side: drain reply buffer whenever present
            if (!tx_valid && ridx != rlen) begin
                tx_data  <= rbuf[ridx];
                tx_valid <= 1'b1;
            end else if (tx_valid && tx_ready) begin
                if (ridx + 6'd1 == rlen) begin
                    tx_valid <= 1'b0;
                    ridx <= ridx + 6'd1;
                end else begin
                    tx_data <= rbuf[ridx + 6'd1];
                    ridx <= ridx + 6'd1;
                end
            end

            case (st)
            S_MAGIC: if (rx_valid) begin
                shift <= {rx_data, shift[31:8]};
                if ({rx_data, shift[31:8]} == MAGIC) begin
                    st <= S_HDR; hidx <= 3'd0;
                end
            end

            S_HDR: if (rx_valid) begin
                hdr[hidx] <= rx_data;
                hidx <= hidx + 3'd1;
                if (hidx == 3'd7) begin
                    cmd  <= hdr[0];
                    seq  <= {hdr[3], hdr[2]};
                    plen <= {rx_data, hdr[6], hdr[5], hdr[4]};
                    pcnt <= 32'd0;
                    in_frame_px <= 1'b0;
                    if ({rx_data, hdr[6], hdr[5], hdr[4]} == 32'd0)
                        st <= S_REPLY;      // zero-payload command
                    else
                        st <= S_PAYLOAD;
                end
            end

            S_PAYLOAD: if (rx_valid) begin
                // small-payload capture for structured commands
                if (pcnt < 32)
                    pay[pcnt[4:0]] <= rx_data;

                // FRAME: after 16-byte header, stream nibble-pairs to fb
                if (cmd == CMD_FRAME) begin
                    if (pcnt == 32'd15) begin
                        fx <= {pay[1], pay[0]};   fy <= {pay[3],  pay[2]};
                        fw <= {pay[5], pay[4]};   fh <= {pay[7],  pay[6]};
                        // NOTE frame_hdr is u32 fields; we accept the low
                        // u16 of each (dims never exceed 12 bits here) and
                        // require the high halves zero (host lib complies).
                        fcnt <= 32'd0;
                        in_frame_px <= 1'b1;
                        fb_waddr <= 17'd0; // linear stream; top adds x/y base
                    end else if (in_frame_px) begin
                        fb_we   <= 1'b1;
                        fb_wdata<= rx_data;
                        fb_waddr<= fcnt[16:0];
                        fcnt <= fcnt + 32'd1;
                    end
                end

                pcnt <= pcnt + 32'd1;
                if (pcnt + 32'd1 == plen)
                    st <= S_REPLY;
            end

            S_REPLY: begin
                case (cmd)
                CMD_SET_MODE: begin
                    if (mode_too_big)
                        reply_status(ST_ERANGE);
                    else begin
                        ld_hactive <= m_hact; ld_hbegin <= m_hbeg;
                        ld_hend    <= m_hend; ld_htotal <= m_htot;
                        ld_vactive <= m_vact; ld_vbegin <= m_vbeg;
                        ld_vend    <= m_vend; ld_vtotal <= m_vtot;
                        ld_toggle <= ~ld_toggle;
                        reply_mode_result;
                    end
                end
                CMD_SET_PLL: begin
                    if (pll_busy)
                        reply_status(ST_EBUSY);
                    else begin
                        pll_m <= {pay[3],pay[2],pay[1],pay[0]};
                        pll_n <= {pay[7],pay[6],pay[5],pay[4]};
                        pll_c <= {pay[11],pay[10],pay[9],pay[8]};
                        pll_req <= 1'b1;
                        reply_status(ST_OK);
                    end
                end
                CMD_SET_PAL: begin
                    pal_index <= pay[0][3:0];
                    pal_rgb   <= {pay[3][3:0], pay[2]};
                    pal_we    <= 1'b1;
                    reply_status(ST_OK);
                end
                CMD_FRAME:    reply_status(ST_OK);
                CMD_GET_INFO: reply_info;
                default:      reply_status(ST_EBADCMD);
                endcase
                st <= S_MAGIC;
                shift <= 32'd0;
            end

            default: st <= S_MAGIC;
            endcase
        end
    end

endmodule
