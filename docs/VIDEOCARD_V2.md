# BlitCRT v2 -- from framebuffer to video card

Author: Ben Templeman (alphanu1)
Date:   2026-07-17

## The idea

v1 was a fixed 320x240p60 framebuffer. v2 makes the FPGA a *video card*
in the CRTPi sense: the host sends arbitrary 15kHz modelines and pixel
data over the **same CRT1 protocol** the Pi speaks -- one wire contract,
two devices:

    CRTPi (Pi 4):  CRT1 over USB bulk  -> KMS/vc4 DPI      -> DAC -> CRT
    BlitCRT v2:    CRT1 over FT245 FIFO-> registers/PLL     -> DAC -> CRT

The host library gains a transport abstraction (usb | ft245) and
everything above it -- switchres integration, test clients -- drives
both identically. Output stage for both: the Pi2SCART hat
(docs/PI2SCART_OUTPUT.md).

## New RTL (simulated, ALL CHECKS PASSED)

- `rtl/video_timing_prog.v` -- runtime-programmable timing generator.
  Switchres POSITION semantics straight off the wire (begin/end are sync
  positions, identical to wire_modeline and DRM -- no conversion in the
  whole stack). Double-buffered loads latch at frame boundaries: no torn
  frames on mode switch. Active-low separate H/V syncs (Pi2SCART feeds).
- `rtl/crt1_ft245.v` -- the CRT1 packet engine: magic hunt + resync,
  CMD_SET_MODE / CMD_SET_PLL / CMD_FRAME (4bpp nibble stream) /
  CMD_SET_PAL / CMD_GET_INFO, with EVT_MODE_RESULT / EVT_STATUS /
  EVT_INFO replies on the TX path. Mode loads cross clock domains via
  toggle + 2FF sync (a 1-cycle strobe is unsampleable by a slow pclk --
  the testbench caught exactly this).

## Pixel clock: honest quantization

Cyclone IV PLLs reconfigure at runtime (M/N/C counters via the
altpll_reconfig scan interface), giving pclk = 50MHz * M / (N * C),
integer dividers only, VCO 600-1300MHz:

    target        dividers (PFD>=5MHz)   achieved        error
    6.400000 MHz  m=16  n=1 c=125         6.400000 MHz    exact
    6.293750 MHz  m=18  n=1 c=143         6.293706 MHz    6.9 ppm
    7.156800 MHz  m=73  n=3 c=170         7.156863 MHz    8.8 ppm
    4.992000 MHz  m=124 n=9 c=138         4.991949 MHz   10.3 ppm

(Computed by pll_search() in host/crt1_ftdi_test.py, VCO 600-1300MHz,
PFD floor 5MHz enforced. Single-digit ppm across the battery -- far
better than first estimated; at 60Hz, 10ppm is ~0.0006Hz of vfreq.)

No fractional-N on this silicon, so v2 adopts the CRTPi contract
verbatim: **apply what's achievable, report the achieved clock** in
EVT_MODE_RESULT. The divider search runs host-side (CMD_SET_PLL carries
m/n/c; the host computes them the same way it computes modelines).
This makes the FPGA the *coarser* of the two devices for exact-refresh
work -- a point for the Pi, stated plainly.

Runtime reconfig is implemented in `rtl/pll_ctl.v`: a sequencer that
decomposes C into the altpll_reconfig counter fields (high/low/odd/
bypass) and drives the megafunction's public scan handshake (Altera
AN 454). The altpll + altpll_reconfig megafunctions themselves are one
Quartus-generated instantiation each (wired in the top level per the
MegaWizard example -- scandata/scanclk/configupdate are fixed nets);
everything controlling them is portable RTL. Simulated: sim/tb_pll.v
(C=125 decomposition + full handshake, ALL CHECKS PASSED).

Genuinely remaining for a bitstream (not writable without Quartus):
generating the two megafunction instances via MegaWizard and connecting
their scan nets to pll_ctl -- a mechanical wiring step, ~10 lines, no
design decisions left.

## Framebuffer budget

EP4CE10: ~414 Kbit M9K. At 4bpp: hact*vact <= ~370 Kbit after palette
and FIFOs. GET_INFO reports MAX 384x288 and SET_MODE rejects larger
actives with ST_ERANGE (the FPGA's version of the profile clamp).

    320x240  307 Kbit  ok      352x288  405 Kbit  marginal
    384x240  368 Kbit  ok      512x224  458 Kbit  rejected

## Integration status

Done: timing core, packet engine, joint simulation (mode switch to the
55Hz-oddity geometry verified by measured hsync period; PLL words
latched; all replies byte-exact including seq echo and max-dims).
Remaining for a bitstream: fb_top_v2 wiring (fb addressing from the
FRAME x/y/w/h rect -- current stream is linear from rect origin),
ft245 TX direction of the FIFO, the pll_ctl megafunction wrapper, and
pin constraints for the Pi2SCART header map (pending the VERIFY items
in PI2SCART_OUTPUT.md).

## Power-on splash (no host connected)

Same behavior as the CRTPi: from power-on the timing core free-runs the
default 320x240p60 mode and `rtl/splash_pattern.v` feeds the DAC SMPTE
bars + a 1px white border, generated combinationally (no RAM, no host).
The top level clears `splash_active` on the first accepted CMD_SET_MODE.
A powered board with no cable therefore proves the FPGA+Pi2SCART+CRT
chain by itself. (No status text on the FPGA -- that's a CPU luxury.)
Simulated: sim/tb_splash.v, ALL CHECKS PASSED.

## Pin assignments

`quartus/pins_pi2scart.tcl`: full signal -> Pi-header-pin table (assumed
vga666 CFG1 map, VERIFY flags inside) with 3.3-V LVTTL I/O standards set
and PIN_?? placeholders to fill from the DVK600 schematic. Visual
reference: `docs/img/pi2scart-pinout.jpg` -- the hat photo with the
color-coded pin map overlaid.

## Host drivers (there are none to install)

The host sees an FT2232H, the most driver-blessed USB silicon there is:
Windows auto-installs FTDI's WHQL-signed driver from Windows Update on
first plug-in (no INF, no Zadig); Linux has in-kernel ftdi_sio, and
pyftdi/libftdi drive it from userspace via libusb (add a udev rule for
unprivileged access). All CRT1 software is pure userspace on both OSes.

One precise limitation, stated plainly: this is an *app-driven* USB
video card (emulators speak CRT1 to it -- the same column CRTPi Lane 1
occupies). It can NEVER be an OS-level display (desktop extension /
display settings): that requires owning USB enumeration as a display-
class device (GUD), which the fixed-function FT2232H bridge cannot do.
That capability is CRTPi Lane 2's alone, courtesy of the Pi's real USB
device controller.

## Clock accuracy upgrades

Two error sources: synthesis quantization (measured <= 11 ppm worst
across a 12-clock arcade corpus) and the reference oscillator itself
(stock crystal: +/-30-50 ppm -- the DOMINANT term as shipped).

Reference-frequency sweep (host/ref_sweep.py): frequency choice is a
wash -- 40MHz "wins" at 10.3 vs stock 50MHz's 11.0 ppm worst; all
sensible values land 10-15 ppm. Heritage frequencies are a trap
(2xNTSC: 320 ppm). Do not chase a magic crystal.

Upgrade ladder:
1. **50MHz TCXO (+/-1 ppm, ~pennies).** Drops total error to
   ~1 + <=11 ppm, temperature-stable. The one to actually do.
2. **Si5351A fractional-N synth as the pixel clock source.** Exact
   rational synthesis (zero ppm for every corpus clock), FPGA takes it
   on a clock input pin, small I2C master programs it, host computes
   registers (CMD_SET_PLL variant). Reference it from the TCXO for
   effectively perfect clocks. ~70 ps jitter: irrelevant at 15kHz.

Perspective: original arcade PCBs ran +/-50-100 ppm crystals. Stock
BlitCRT already beats the hardware the games were designed for; the
ladder is for measurement-grade reference duty (and for benchmarking
the Pi's vc4 against something trustworthy).

## FT2232H link -- RX and TX both implemented

The FT245 FIFO interface is now complete in both directions:
- ft245_rx.v : read engine (host -> device commands). Simulated.
- ft245_tx.v : write engine (device -> host replies: EVT_INFO,
  EVT_MODE_RESULT achieved-clock, EVT_STATUS). Simulated (sim/tb_ft245_tx.v,
  ALL CHECKS PASSED -- 4-byte write handshake + TXE# back-pressure).

fb_top_v2 drives the shared 8-bit FT245 data bus as a true bidirectional
pad: ft_data = ft_oe ? ft_data_out : 8'bz. ft245_tx raises ft_oe only
while it owns the bus (during a WR# pulse); otherwise the bus is an input
for ft245_rx. rd_n and wr_n are never asserted simultaneously by design
(the engines are independent and the FTDI arbitrates RXF#/TXE#).

Pins: 32I/Os_2 holes 21..32 -- ft_data[7:0] on 21..28, ft_rxf_n=29,
ft_txe_n=30, ft_rd_n=31, ft_wr_n=32. Wire to the FT2232H channel-A BDBUS
FIFO pins; share ground with the FTDI board.

Async FIFO (~1MB/s) is the current mode -- ample for GET_INFO, SET_MODE,
SET_PLL, palette, and partial-frame damage. Full-rate 60Hz whole-frame
streaming wants sync FIFO (~40MB/s): replace ft245_rx/ft245_tx with sync
versions, keep the byte_data/byte_valid and tx_data/tx_valid/tx_ready
interfaces identical.

## Bring-up without an FT2232H: UART byte source

For first light you don't need the FT2232H. fb_top_v2 has a USE_UART
parameter (default 1) that swaps the CRT1 byte source from the FT245
FIFO to a plain 8N1 UART (rtl/uart_rx.v) on a single pin -- driven by any
USB-serial adapter you already own. It produces the identical
byte_data/byte_valid stream, so crt1_ft245 and everything downstream is
unchanged.

  USE_UART=1 (default): CRT1 over serial, ~3Mbaud (UART_CLKS_PER_BIT=16
             at 50MHz). Pin: 32I/Os_2 hole 21 (PIN_R3). Host sender:
             host/crt1_uart_test.py PORT pclk hact.. vtot.
  USE_UART=0: CRT1 over the FT2232H FT245 FIFO (holes 21..32).

Simulated: sim/tb_uart_rx.v (decodes 'C','R','T','1' at 8N1, ALL CHECKS
PASSED). For a marginal cable, drop the baud: set 921600 in the Python
AND rebuild with UART_CLKS_PER_BIT=54 (50MHz/921600).

Wiring (UART mode): USB-serial GND -> board GND; USB-serial TX -> hole 21.
Do not also attach an FT2232H while in UART mode (they share hole 21).
Throughput note: serial is ample for SET_PLL/SET_MODE/palette and small
or partial frames. Full 60Hz whole-frame streaming still wants the
sync-FIFO FT2232H path.

## Test card with live resolution, fractional refresh + pixel clock

The test card (rtl/splash_pattern.v) overlays the current mode as two
text lines drawn from an 8x8 font:
    line A:  <hact>x<vact>            e.g. 320x240
    line B:  <vfreq>HZ <pclk>MHZ      e.g. 60.01HZ 6.400MHZ

The resolution comes from the live loaded timing (updates the instant a
SET_MODE lands). The refresh and pixel clock are MEASURED on-device by
rtl/mode_meter.v:
  - it counts clk50 ticks per frame (the frame period),
  - vfreq(centi-Hz) = 50e6*100 / ticks_per_frame  -> 2 decimals (60.01),
  - pclk(kHz)       = htotal*vtotal*50e6 / ticks_per_frame / 1000,
  via a shared sequential divider that runs once per frame during
  blanking (far from the pixel datapath). So the numbers reflect the TRUE
  achieved timing -- including PLL quantization (e.g. 59.94 vs 60.00).

Persistence: the card used to clear on the first SET_MODE. It now persists
through SET_MODE and clears only on the first real CMD_FRAME (actual pixel
data). So you can switch resolutions over UART and SEE each confirmed on
the CRT -- bars + the updated readout -- without streaming a frame.

Simulated:
  sim/tb_mode_meter.v  -- 60.01Hz / 6.400MHz mode -> "60.01" / "6.400",
                          ALL CHECKS PASSED.
  splash renders both text rows + bars in tb.

A rendered mockup of the card is at docs/img/test-card.png.
