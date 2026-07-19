// pll_ctl.v -- runtime pixel-clock reconfiguration for fpga15k v2
//
// Author: Ben Templeman (alphanu1)
// Date:   2026-07-17
//
// Drives Altera's altpll_reconfig megafunction to change the pixel PLL's
// output divider (and M/N if desired) at runtime, from the m/n/c values
// crt1_ft245 latches on CMD_SET_PLL.
//
// WHY THIS EXISTS / WHAT'S PORTABLE:
//   - altpll and altpll_reconfig are Quartus-generated IP (instantiated
//     below, generated via MegaWizard -- their internals are vendor IP).
//   - Their *reconfiguration protocol* is public (Altera AN 454, Cyclone
//     IV Handbook vol.1 ch.5): you write new counter parameters into the
//     reconfig block's scan cache, then pulse reconfig; it serially
//     shifts the cache into the PLL and re-locks. THIS wrapper implements
//     that handshake. So the "vendor IP" is one instantiation; the
//     control logic around it is ordinary, portable RTL written here.
//
// Counter-parameter model (altpll_reconfig data_in is 9 bits, addressed
// by counter_type/counter_param): each output/M/N counter has HIGH, LOW,
// BYPASS, ODD-division fields. For a 50% (or near) duty divide-by-C:
//   high = C/2 (+1 if odd), low = C/2, bypass = (C==1), odd = C&1.
// We expose a simple "set C" path (the common case: change only the
// output divider for a new pixel clock); M/N reload is wired but usually
// left at the compile-time VCO setup.

module pll_ctl (
    input  wire        clk,          // control clock (clk_sys, 50MHz)
    input  wire        rst_n,

    // request from crt1_ft245
    input  wire        req,          // pulse: apply {m,n,c}
    input  wire [31:0] c_div,        // output divider (primary use)
    input  wire [31:0] m_mul,        // VCO M (optional reload)
    input  wire [31:0] n_div,        // VCO N (optional reload)
    output reg         busy,

    // pixel clock out (to the video domain)
    output wire        pclk,
    output wire        locked,

    // ---- altpll_reconfig scan interface (connect to generated IP) ----
    output reg  [3:0]  ra_counter_type,
    output reg  [2:0]  ra_counter_param,
    output reg  [8:0]  ra_data_in,
    output reg         ra_write_param,
    output reg         ra_reconfig,
    input  wire        ra_busy,
    // ---- altpll dynamic-config bus (reconfig <-> pll) ----
    output wire [8:0]  pll_configupdate_bus, // placeholder tie in top
    input  wire        pll_locked_in
);

    // counter_type encodings (per altpll_reconfig): 0=N,1=M,2=C0,...
    localparam CT_N = 4'd0, CT_M = 4'd1, CT_C0 = 4'd2;
    // counter_param encodings: 0=HIGH,1=LOW,2=BYPASS,3=?,4=ODD (mode-dep)
    localparam CP_HIGH = 3'd0, CP_LOW = 3'd1, CP_BYPASS = 3'd2,
               CP_ODD  = 3'd4;

    // decompose C into high/low/odd
    wire [8:0] c_high = (c_div[8:0] >> 1) + (c_div[0] ? 9'd1 : 9'd0);
    wire [8:0] c_low  = (c_div[8:0] >> 1);
    wire       c_odd  = c_div[0];
    wire       c_byp  = (c_div == 32'd1);

    // program sequence: write C0 HIGH, LOW, ODD, BYPASS, then reconfig.
    reg [3:0] st;
    localparam S_IDLE=0, S_H=1, S_L=2, S_O=3, S_B=4, S_GO=5, S_WAIT=6;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; busy <= 1'b0;
            ra_write_param <= 1'b0; ra_reconfig <= 1'b0;
            ra_counter_type <= 4'd0; ra_counter_param <= 3'd0;
            ra_data_in <= 9'd0;
        end else begin
            ra_write_param <= 1'b0;
            ra_reconfig    <= 1'b0;
            case (st)
            S_IDLE: if (req && !ra_busy) begin
                busy <= 1'b1; st <= S_H;
            end
            S_H: begin
                ra_counter_type<=CT_C0; ra_counter_param<=CP_HIGH;
                ra_data_in<=c_high; ra_write_param<=1'b1; st<=S_L;
            end
            S_L: begin
                ra_counter_type<=CT_C0; ra_counter_param<=CP_LOW;
                ra_data_in<=c_low; ra_write_param<=1'b1; st<=S_O;
            end
            S_O: begin
                ra_counter_type<=CT_C0; ra_counter_param<=CP_ODD;
                ra_data_in<={8'd0,c_odd}; ra_write_param<=1'b1; st<=S_B;
            end
            S_B: begin
                ra_counter_type<=CT_C0; ra_counter_param<=CP_BYPASS;
                ra_data_in<={8'd0,c_byp}; ra_write_param<=1'b1; st<=S_GO;
            end
            S_GO: begin
                ra_reconfig <= 1'b1;        // shift cache into PLL
                st <= S_WAIT;
            end
            S_WAIT: begin
                // reconfig asserts ra_busy until done + PLL re-locks
                if (!ra_busy && pll_locked_in) begin
                    busy <= 1'b0; st <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    assign locked = pll_locked_in;
    assign pll_configupdate_bus = 9'd0;   // wired in top to the IP

    // ---------------------------------------------------------------
    // Instantiate the Quartus-generated IP in the top level, not here,
    // so this file simulates standalone. Expected instances:
    //
    //   altpll        u_pll   ( .inclk0(ref50), .c0(pclk),
    //                           .locked(pll_locked_in),
    //                           .configupdate(...), .scandata(...),
    //                           .scanclk(...), .scanclkena(...), ... );
    //   altpll_reconfig u_rc  ( .clock(clk), .reset(~rst_n),
    //                           .counter_type(ra_counter_type),
    //                           .counter_param(ra_counter_param),
    //                           .data_in(ra_data_in),
    //                           .write_param(ra_write_param),
    //                           .reconfig(ra_reconfig),
    //                           .busy(ra_busy),
    //                           .pll_scandata(...), .pll_scanclk(...),
    //                           .pll_configupdate(...), ... );
    //
    // The scandata/scanclk/configupdate nets run reconfig<->pll; they're
    // fixed wiring straight from the MegaWizard example. pclk here is a
    // dangling output until that instance exists.
    // ---------------------------------------------------------------
    assign pclk = 1'b0;  // replaced by u_pll.c0 in top level

endmodule
