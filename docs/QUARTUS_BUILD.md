# BlitCRT v2 -- Quartus build guide

Author: Ben Templeman (alphanu1)
Date:   2026-07-17

Everything in rtl/ and sim/ is written and simulated. fb_top_v2.v wires
all modules and elaborates clean (iverilog, megafunctions tied off).
What remains is Quartus-only: generate two Altera megafunctions, connect
them, assign pins, build. Est. 1-2 focused hours.

## 1. Project

- File > New Project Wizard. Name: BlitCRT_v2. Top entity: fb_top_v2.
- Device: EP4CE10F17C8 (CONFIRM the exact marking on your CoreEP4CE10 --
  speed grade may be C8 or C6).
- Add files: fb_top_v2.v and rtl/{ft245_rx, crt1_ft245,
  video_timing_prog, framebuffer, palette, splash_pattern, pll_ctl}.v
- Do NOT add: fb_top.v, video_timing.v, usb_protocol.v (v1, superseded).

## 2. Pixel PLL (ALTPLL) -- generate 'pix_pll'

Tools > IP Catalog > Basic Functions > Clocks;PLLs;Resets > ALTPLL.
- Name: pix_pll
- inclk0 = 50.000 MHz
- c0 = 6.400 MHz  (reset default; splash runs at this)
- Enable 'locked' output.
- **Reconfiguration tab: tick "Create optional inputs for dynamic
  reconfiguration"** (exposes scandata/scanclk/configupdate). Without
  this, runtime clock changes are impossible.
- Finish -> generates pix_pll.qip + wrapper. Add the .qip to the project.

## 3. Reconfig block (ALTPLL_RECONFIG) -- generate 'pix_pll_reconfig'

IP Catalog > ALTPLL_RECONFIG.
- Name: pix_pll_reconfig
- Parameterize to match pix_pll (single C output; accept default
  M/N/C widths). Enable the scan interface that pairs with step 2.
- Finish, add .qip.

## 4. Connect the megafunctions

In fb_top_v2.v, uncomment the pix_pll and pix_pll_reconfig instantiation
blocks at the bottom and DELETE the two TEMP tie lines
(`assign pll_locked = 1'b1;` and `assign pclk = clk50;`). Match the
generated wrapper's exact port names -- Quartus may name them
`.scandata`/`.pll_scandataout` etc. depending on version; the comment
block lists the standard names. The reconfig<->pll nets
(rc_scandata/rc_scanclk/rc_configupdate) are fixed wiring from the
MegaWizard example.

## 5. Pins & timing

- Assignments > Import Assignments > quartus/pins_pi2scart.tcl.
- Fill the PIN_?? location_assignments from the DVK600 schematic (which
  EP4CE10 balls reach the expansion headers you're using).
- FIRST verify the Pi2SCART color-bit map (PI2SCART_OUTPUT.md) -- wrong
  map = scrambled colors.
- Add an SDC: create_clock 50MHz on clk50; derive_pll_clocks for pclk.
  (quartus/fb_top.sdc from v1 is a starting point; update the pll name.)

## 6. Compile & flash

- Processing > Start Compilation. Fix any pin/timing errors.
- Programmer > add BlitCRT_v2.sof > Program (JTAG, volatile), or convert
  to .jic for the config flash (permanent).

## 7. Bring-up order (no CRT needed at first)

1. Power on with NO USB host: the splash (bars + border) should appear
   on the CRT via Pi2SCART -- proves PLL default clock, timing, DAC,
   wiring all at once.
2. Wrong colors -> Pi2SCART bit map. No image but sync -> pclk/PLL. No
   sync -> timing/pins.
3. Connect FT2232H, run host/crt1_ftdi_test.py with the 320x240 battery.
   Watch a mode + bars land under host control.
4. Sync-FIFO conversion (EEPROM + fabric FIFO) before expecting full
   60Hz frame rates -- async FIFO is bandwidth-bound (see VIDEOCARD_V2).

## Notes on the two TEMP ties (must remove in step 4)

- `assign pclk = clk50` runs video at 50MHz (wrong rate) purely so the
  design elaborates before the PLL exists. Removing it and wiring
  pix_pll.c0 gives the real 6.4MHz.
- `assign pll_locked = 1'b1` fakes lock; the real signal comes from
  pix_pll.locked.
