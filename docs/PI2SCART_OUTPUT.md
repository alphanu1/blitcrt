# Pi2SCART output wiring -- DVK600 32I/Os_2 bank

Author: Ben Templeman (alphanu1)
Date:   2026-07-17

Video comes out on the DVK600 **32I/Os_2** bank (holes 1..20). The bank
is fed by the CoreEP4CE10 H_Up header, so the ball map is EXACT (from the
CoreEP4CE10 pin-conf) -- no continuity testing needed. Ribbon is straight:
bank hole N carries signal N.

## Final map (all certain)

  signal      32I/Os_2 hole   EP4CE10 ball   Pi2SCART target
  vid_r6[5]   1               PIN_R11        R7  (Red MSB)
  vid_r6[4]   2               PIN_N12        R6
  vid_r6[3]   3               PIN_P11        R5
  vid_r6[2]   4               PIN_N11        R4
  vid_r6[1]   5               PIN_P9         R3
  vid_r6[0]   6               PIN_N9         R2  (Red LSB)
  vid_g6[5]   7               PIN_R10        G7  (Green MSB)
  vid_g6[4]   8               PIN_T11        G6
  vid_g6[3]   9               PIN_R9         G5
  vid_g6[2]   10              PIN_T10        G4
  vid_g6[1]   11              PIN_R8         G3
  vid_g6[0]   12              PIN_T9         G2  (Green LSB)
  vid_b6[5]   13              PIN_R7         B7  (Blue MSB)
  vid_b6[4]   14              PIN_T8         B6
  vid_b6[3]   15              PIN_R6         B5
  vid_b6[2]   16              PIN_T7         B4
  vid_b6[1]   17              PIN_R5         B3
  vid_b6[0]   18              PIN_T6         B2  (Blue LSB)
  vid_hs_n    19              PIN_R4         GPIO25 (HSync)
  vid_vs_n    20              PIN_T5         GPIO26 (VSync)

  clk50       (on-core osc)   PIN_E16
  rst_n       (RESET key)     PIN_B16

Bank holes 21..32 (PIN_R3,T4,M9,T3,K9,L9,L8,K8,M7,M8,M6,L7) are unused
and free for expansion (sync-FIFO FT2232H signals later, etc.).

## Bank header pinout (from the board silk you photographed)

Looking at the back of 32I/Os_2, the first two pin-pairs are power:
  pair 1: VCC / VCC
  pair 2: GND / GND
then holes 1..32 run down the remaining pairs (odd row 1,3,5..31;
even row 2,4,6..32). Use the bank's GND pins for the Pi2SCART grounds.

## Pi2SCART wiring rules

- Feed the TOP 6 bits of each channel (R7..R2 etc.); the Pi2SCART's 2
  LSB inputs (R1,R0...) stay unconnected.
- Grounds: tie several Pi2SCART GND pins (Pi header 6,9,14,20,25,30,34,39)
  to the bank's GND pins.
- **5V (Pi header pins 2,4): DO NOT CONNECT.** FPGA I/O is 3.3V; 5V
  would destroy a pin. The Pi2SCART ladder is passive and needs no 5V
  from this side.
- Board makes CSync from H/V internally; no separate CSync wire.
- Audio: separate 3.5mm cable, not through this header.

## Import + build

  source quartus/pins_pi2scart.tcl        (Tcl console)
  -- or Assignments > Import Assignments
then Start Compilation.

## First bring-up

Power on with NO Pi2SCART, or with it connected + CRT:
  - Splash (bars + border) should appear -> PLL, timing, DAC, ribbon all OK.
  - Colours wrong = ribbon bit-order (fix cable, not tcl).
  - No sync = check holes 19/20. No image but sync = check pclk/PLL lock.
