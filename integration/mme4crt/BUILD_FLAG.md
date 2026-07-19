# Building MME4CRT with FPGA support (no define -- quick test mode)

Author: Ben Templeman (alphanu1)
Date:   2026-07-17

The HAVE_CRT_FPGA gate has been REMOVED for faster iteration. The CRT1
backend now always compiles; crt_fpga_on is a plain runtime bool, false
until crt_fpga_init() detects a device. Behaviour is unchanged when no
device is attached -- it just also links libftdi1 unconditionally.

## What you must do

Only ONE thing now: link libftdi1 (the code #includes it unconditionally).

Install it:
   Arch:    sudo pacman -S libftdi
   Debian:  sudo apt install libftdi1-dev
   Fedora:  sudo dnf install libftdi-devel

Build, adding the lib to the link line:
   make LIBS="-lftdi1"

or if your tree ignores LIBS overrides, append to LDFLAGS:
   make LDFLAGS="$LDFLAGS -lftdi1"

That's it -- no configure flag, no Makefile.common edit, no define.

## Runtime

- Device attached -> log shows:
     [CRT] FPGA CRT1 device detected; native switching bypassed.
  and modelines + frames stream over CRT1 instead of a host modeswitch.
- No device -> crt_fpga_init() returns false, crt_fpga_on stays false,
  every crt_fpga_* path is skipped, RA switches natively as before.

## Reverting to a proper build gate later

When you want the flag back (so default builds don't require libftdi),
re-wrap the block added to video_crt_switch.c in:
   #ifdef HAVE_CRT_FPGA ... #else <stubs> ... #endif
and add the -DHAVE_CRT_FPGA + $(FTDI_LIBS) Makefile.common block. The
earlier stubbed version is preserved in git history / the prior zip.

## Files

- video_crt_switch.c  -- CRT1 backend (unconditional) + detection + mode
- video_crt_switch.h  -- crt_send_frame prototype
- video_driver.c      -- crt_send_frame() call after vid->frame()

## Verified

Block compiles -std=c89 -Wall -Wextra clean in isolation; init/set_mode/
send_frame/deinit all exercised; PLL search reproduces 6.4MHz exact.
