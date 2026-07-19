# MME4CRT integration -- FPGA backend detection + drive

Author: Ben Templeman (alphanu1)
Date:   2026-07-17

MME4CRT already computes modelines via switchres in video_crt_switch.c.
This adds an FPGA (CRT1) backend that is auto-detected at init; when
present, the modeline is sent to the device and native OS switching is
bypassed (the FPGA IS the display). When absent, everything behaves
exactly as before -- the stubs make the calls no-ops.

## Files to add (gfx/)

- gfx/crt_fpga.h, gfx/crt_fpga.c   (this directory)
- host/c/crt1.{h,c}                (protocol + PLL search; shared)
Set include path in crt_fpga.c's #include "../host/c/crt1.h" to match
where you place crt1.h in the RA tree (e.g. deps/crt1/ or libretro-common).

## Build wiring (Makefile.common / griffin)

Compile gate: define HAVE_CRT_FPGA and link -lftdi1 only when the user
opts in (configure flag or a CRT_FPGA=1 make var). Without it, the #else
stubs compile and native switching is unaffected. crt1.c always compiles
(no OS deps).

## Edits to video_crt_switch.c

1. Top of file:
      #include "crt_fpga.h"

2. In the init path (where CRT switching is first enabled -- e.g.
   crt_switch_res_switch()'s first-run setup, or an explicit init):
      crt_fpga_init();      /* latches active if a device is found */

3. At the point the modeline is chosen and about to be applied. In
   MME4CRT this is where switchres hands back the timing and the OS
   apply happens inside the #if defined(_WIN32)/__linux__ blocks. Wrap
   that native apply:

      if (crt_fpga_active())
      {
         crt_fpga_switch(pclock_hz,
                         hactive, hbegin, hend, htotal,
                         vactive, vbegin, vend, vtotal,
                         interlace);
      }
      else
      {
         /* existing native switch (#if defined(_WIN32) ... etc.) */
      }

   Use whatever local variable names switchres populates for the timing
   fields; they are the same positions crt_fpga_switch expects.

4. Frame path: from the video driver's frame callback (or the crt switch
   frame hook), when active:
      if (crt_fpga_active())
         crt_fpga_frame(frame_data, width, height, pitch);

5. Teardown (RA exit / CRT disable):
      crt_fpga_free();

## Detection semantics

crt_fpga_init() opens the FTDI VID:PID (0403:6010). Found -> active,
native switching bypassed. Not found -> false, RA proceeds unchanged.
No device, no libftdi, or a stub build all yield the same safe result.

## Notes matching the RA codebase

- C89: no // comments, declarations at block top.
- 3-space indent (not tabs).
- snprintf only, never sprintf.
- All new symbols guarded so a default build (no HAVE_CRT_FPGA) links
  with zero behavior change.

## Standalone C test client

host/c/crt1_ftdi.c is the C replacement for crt1_ftdi_test.py:
   cc -O2 -o crt1_ftdi crt1_ftdi.c crt1.c -lftdi1
   ./crt1_ftdi 6400000 320 328 359 407 240 244 247 262
Verified: crt1.c compiles -std=c89 -Wall -Wextra clean; PLL search
matches the Python reference (0.0/8.8/-7.0/-10.4 ppm on the battery).
