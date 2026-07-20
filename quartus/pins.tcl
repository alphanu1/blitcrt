# pins_all.tcl -- BlitCRT: ALL signals assigned (video + FT245 + UART)
# Author: Ben Templeman (alphanu1)
#
# Every signal on a distinct ball, no duplicates. FT245 owns holes 21..32;
# ft_data[0] keeps PIN_R3. The UART input moves to its OWN pin on a spare
# DVK600 header (32I/Os_2 is full: video 1..20, FT245 21..32).
#
# >>> ACTION REQUIRED: set the UART pin below (one line, marked TODO).  <<<
# Pick any free hole on another header (8I/Os_1/2, 16I/Os_1/2, 32I/Os_1),
# read its EP4CE10 ball off the CoreEP4CE10 schematic, and put it in the
# uart_rx_pin line. Until then that line is commented out so this sources
# cleanly and Quartus auto-places uart_rx_pin.
#
# Source once in the Tcl Console, then compile:
#     remove_all_instance_assignments -name LOCATION
#     source quartus/pins_all.tcl

# ---- System clock + reset ----
set_location_assignment PIN_E16 -to clk50
set_location_assignment PIN_B16 -to rst_n

# ---- Video: RGB666 + H/V sync (32I/Os_2 holes 1..20) ----
set_location_assignment PIN_R11 -to vid_r6[5]
set_location_assignment PIN_N12 -to vid_r6[4]
set_location_assignment PIN_P11 -to vid_r6[3]
set_location_assignment PIN_N11 -to vid_r6[2]
set_location_assignment PIN_P9  -to vid_r6[1]
set_location_assignment PIN_N9  -to vid_r6[0]
set_location_assignment PIN_R10 -to vid_g6[5]
set_location_assignment PIN_T11 -to vid_g6[4]
set_location_assignment PIN_R9  -to vid_g6[3]
set_location_assignment PIN_T10 -to vid_g6[2]
set_location_assignment PIN_R8  -to vid_g6[1]
set_location_assignment PIN_T9  -to vid_g6[0]
set_location_assignment PIN_R7  -to vid_b6[5]
set_location_assignment PIN_T8  -to vid_b6[4]
set_location_assignment PIN_R6  -to vid_b6[3]
set_location_assignment PIN_T7  -to vid_b6[2]
set_location_assignment PIN_R5  -to vid_b6[1]
set_location_assignment PIN_T6  -to vid_b6[0]
set_location_assignment PIN_R4  -to vid_hs_n
set_location_assignment PIN_T5  -to vid_vs_n

# ---- FT245 FIFO (32I/Os_2 holes 21..32) ----
set_location_assignment PIN_R3  -to ft_data[0]
set_location_assignment PIN_T4  -to ft_data[1]
set_location_assignment PIN_M9  -to ft_data[2]
set_location_assignment PIN_T3  -to ft_data[3]
set_location_assignment PIN_K9  -to ft_data[4]
set_location_assignment PIN_L9  -to ft_data[5]
set_location_assignment PIN_L8  -to ft_data[6]
set_location_assignment PIN_K8  -to ft_data[7]
set_location_assignment PIN_M7  -to ft_rxf_n
set_location_assignment PIN_M8  -to ft_txe_n
set_location_assignment PIN_M6  -to ft_rd_n
set_location_assignment PIN_L7  -to ft_wr_n

# ---- UART input on its OWN pin: 8I/Os_1 hole 1 = PIN_F11 ----
set_location_assignment PIN_F11 -to uart_rx_pin

# ---- I/O standard: 3.3V LVTTL on all assigned user I/O ----
foreach s {
  clk50 rst_n
  vid_r6[5] vid_r6[4] vid_r6[3] vid_r6[2] vid_r6[1] vid_r6[0]
  vid_g6[5] vid_g6[4] vid_g6[3] vid_g6[2] vid_g6[1] vid_g6[0]
  vid_b6[5] vid_b6[4] vid_b6[3] vid_b6[2] vid_b6[1] vid_b6[0]
  vid_hs_n vid_vs_n
  ft_data[0] ft_data[1] ft_data[2] ft_data[3] ft_data[4] ft_data[5]
  ft_data[6] ft_data[7] ft_rxf_n ft_txe_n ft_rd_n ft_wr_n
  uart_rx_pin
} {
  set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $s
}
