# pins_pi2scart.tcl -- fpga15k v2 pin assignments
# Author: Ben Templeman (alphanu1)
# Date:   2026-07-17
#
# Video output on DVK600 32I/Os_2 bank, holes 1..20 (fed by core H_Up).
# Ball map is EXACT (from CoreEP4CE10 pin-conf); ribbon is straight:
# bank hole N carries signal N in the order below.
#
# System clock + reset:
set_location_assignment PIN_E16 -to clk50
set_location_assignment PIN_B16 -to rst_n
#
# Video signals (RGB666 + separate H/V sync):
set_location_assignment PIN_R11  -to vid_r6[5]    ;# 32I/Os_2 hole 1  -> Pi2SCART R7
set_location_assignment PIN_N12  -to vid_r6[4]    ;# 32I/Os_2 hole 2  -> Pi2SCART R6
set_location_assignment PIN_P11  -to vid_r6[3]    ;# 32I/Os_2 hole 3  -> Pi2SCART R5
set_location_assignment PIN_N11  -to vid_r6[2]    ;# 32I/Os_2 hole 4  -> Pi2SCART R4
set_location_assignment PIN_P9   -to vid_r6[1]    ;# 32I/Os_2 hole 5  -> Pi2SCART R3
set_location_assignment PIN_N9   -to vid_r6[0]    ;# 32I/Os_2 hole 6  -> Pi2SCART R2
set_location_assignment PIN_R10  -to vid_g6[5]    ;# 32I/Os_2 hole 7  -> Pi2SCART G7
set_location_assignment PIN_T11  -to vid_g6[4]    ;# 32I/Os_2 hole 8  -> Pi2SCART G6
set_location_assignment PIN_R9   -to vid_g6[3]    ;# 32I/Os_2 hole 9  -> Pi2SCART G5
set_location_assignment PIN_T10  -to vid_g6[2]    ;# 32I/Os_2 hole 10 -> Pi2SCART G4
set_location_assignment PIN_R8   -to vid_g6[1]    ;# 32I/Os_2 hole 11 -> Pi2SCART G3
set_location_assignment PIN_T9   -to vid_g6[0]    ;# 32I/Os_2 hole 12 -> Pi2SCART G2
set_location_assignment PIN_R7   -to vid_b6[5]    ;# 32I/Os_2 hole 13 -> Pi2SCART B7
set_location_assignment PIN_T8   -to vid_b6[4]    ;# 32I/Os_2 hole 14 -> Pi2SCART B6
set_location_assignment PIN_R6   -to vid_b6[3]    ;# 32I/Os_2 hole 15 -> Pi2SCART B5
set_location_assignment PIN_T7   -to vid_b6[2]    ;# 32I/Os_2 hole 16 -> Pi2SCART B4
set_location_assignment PIN_R5   -to vid_b6[1]    ;# 32I/Os_2 hole 17 -> Pi2SCART B3
set_location_assignment PIN_T6   -to vid_b6[0]    ;# 32I/Os_2 hole 18 -> Pi2SCART B2
set_location_assignment PIN_R4   -to vid_hs_n     ;# 32I/Os_2 hole 19 -> Pi2SCART HSync(GPIO25)
set_location_assignment PIN_T5   -to vid_vs_n     ;# 32I/Os_2 hole 20 -> Pi2SCART VSync(GPIO26)
#
# I/O standard: 3.3-V LVTTL on all pins:
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_r6[5]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_r6[4]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_r6[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_r6[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_r6[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_r6[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_g6[5]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_g6[4]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_g6[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_g6[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_g6[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_g6[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_b6[5]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_b6[4]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_b6[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_b6[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_b6[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_b6[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_hs_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to vid_vs_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to clk50
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to rst_n

# ---------------------------------------------------------------------
# FT2232H FT245 async FIFO -- free 32I/Os_2 holes 21..32.
# Wire these to the FT2232H breakout's channel-A FIFO pins (BDBUS):
#   ft_data[7:0] <-> D0..D7,  ft_rxf_n <- RXF#,  ft_txe_n <- TXE#,
#   ft_rd_n -> RD#,  ft_wr_n -> WR#.  Share GND with the FTDI board.
# ---------------------------------------------------------------------
set_location_assignment PIN_R3   -to ft_data[0]   ;# 32I/Os_2 hole 21
set_location_assignment PIN_T4   -to ft_data[1]   ;# 32I/Os_2 hole 22
set_location_assignment PIN_M9   -to ft_data[2]   ;# 32I/Os_2 hole 23
set_location_assignment PIN_T3   -to ft_data[3]   ;# 32I/Os_2 hole 24
set_location_assignment PIN_K9   -to ft_data[4]   ;# 32I/Os_2 hole 25
set_location_assignment PIN_L9   -to ft_data[5]   ;# 32I/Os_2 hole 26
set_location_assignment PIN_L8   -to ft_data[6]   ;# 32I/Os_2 hole 27
set_location_assignment PIN_K8   -to ft_data[7]   ;# 32I/Os_2 hole 28
set_location_assignment PIN_M7   -to ft_rxf_n     ;# 32I/Os_2 hole 29
set_location_assignment PIN_M8   -to ft_txe_n     ;# 32I/Os_2 hole 30
set_location_assignment PIN_M6   -to ft_rd_n      ;# 32I/Os_2 hole 31
set_location_assignment PIN_L7   -to ft_wr_n      ;# 32I/Os_2 hole 32
#
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[4]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[5]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[6]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_data[7]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_rxf_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_txe_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_rd_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ft_wr_n

# ---------------------------------------------------------------------
# UART bring-up pin (used when USE_UART=1). One input line from a plain
# USB-serial adapter's TX. Reuses 32I/Os_2 hole 21 (PIN_R3) -- when
# USE_UART=1 the FT245 pins are not driven, so sharing a hole is fine.
# Wire: USB-serial GND -> board GND, USB-serial TX -> hole 21.
# (Do NOT also connect an FT2232H while in UART mode.)
# ---------------------------------------------------------------------
set_location_assignment PIN_R3  -to uart_rx_pin  ;# 32I/Os_2 hole 21
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to uart_rx_pin
