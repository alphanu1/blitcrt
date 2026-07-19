# pins_template.tcl -- pin assignments for CoreEP4CE10 on DVK600
#
# The FPGA pin numbers depend on which DVK600 headers you wire the FTDI
# module and the RGB DAC into. Fill in every PIN_xx from the Waveshare
# CoreEP4CE10 schematic (the header silkscreen labels map 1:1 to FPGA pins
# in the schematic PDF). Run in Quartus:  source pins_template.tcl
#
# Suggested physical placement:
#   ft_*   -> 16I/Os_1 header (11 signals: D[7:0], RXF#, RD#, WR#)
#   vid_*  -> 16I/Os_2 header (15 signals: R/G/B[3:0], HS, VS, CS)

# --- system ---------------------------------------------------------------
set_location_assignment PIN_XX -to clk50      ;# 50MHz osc on core board
set_location_assignment PIN_XX -to rst_n      ;# RESET pushbutton

# --- FT2232H async FIFO ---------------------------------------------------
set_location_assignment PIN_XX -to ft_rxf_n
set_location_assignment PIN_XX -to ft_rd_n
set_location_assignment PIN_XX -to ft_wr_n
set_location_assignment PIN_XX -to ft_data[0]
set_location_assignment PIN_XX -to ft_data[1]
set_location_assignment PIN_XX -to ft_data[2]
set_location_assignment PIN_XX -to ft_data[3]
set_location_assignment PIN_XX -to ft_data[4]
set_location_assignment PIN_XX -to ft_data[5]
set_location_assignment PIN_XX -to ft_data[6]
set_location_assignment PIN_XX -to ft_data[7]

# --- video out ------------------------------------------------------------
set_location_assignment PIN_XX -to vid_r[0]
set_location_assignment PIN_XX -to vid_r[1]
set_location_assignment PIN_XX -to vid_r[2]
set_location_assignment PIN_XX -to vid_r[3]
set_location_assignment PIN_XX -to vid_g[0]
set_location_assignment PIN_XX -to vid_g[1]
set_location_assignment PIN_XX -to vid_g[2]
set_location_assignment PIN_XX -to vid_g[3]
set_location_assignment PIN_XX -to vid_b[0]
set_location_assignment PIN_XX -to vid_b[1]
set_location_assignment PIN_XX -to vid_b[2]
set_location_assignment PIN_XX -to vid_b[3]
set_location_assignment PIN_XX -to vid_hs_n
set_location_assignment PIN_XX -to vid_vs_n
set_location_assignment PIN_XX -to vid_cs_n

# --- global ---------------------------------------------------------------
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to *
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"
