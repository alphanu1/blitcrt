/* crt_fpga.h -- FPGA (CRT1) backend detection + drive for video_crt_switch
 *
 * Author: Ben Templeman (alphanu1)
 * Date:   2026-07-17
 *
 * Add to gfx/. Declares the hooks video_crt_switch.c calls to (a) detect
 * a connected fpga15k/CRTPi device at init, (b) push the chosen modeline
 * to it on a resolution switch, and (c) stream frames.
 *
 * When a device is detected, native OS mode-switching is bypassed: the
 * FPGA IS the display, so RetroArch must not also try to switch the host
 * desktop. crt_fpga_active() gates that in video_crt_switch.c.
 *
 * C89, 3-space indent, snprintf only -- matches the RA codebase.
 */
#ifndef CRT_FPGA_H
#define CRT_FPGA_H

#include <retro_common_api.h>
#include <boolean.h>

RETRO_BEGIN_DECLS

/* Probe for a CRT1 device (FTDI VID/PID, or CRTPi USB) at startup.
 * Returns true and latches active state if found. Safe to call when no
 * device/libs are present -- returns false, RA proceeds normally. */
bool crt_fpga_init(void);

/* True if a device was detected and is driving the display. */
bool crt_fpga_active(void);

/* Push a mode to the device. Fields are switchres-computed timings
 * (positions). Also emits SET_PLL for the FPGA (dividers computed here).
 * Returns true on success. No-op returning false if !active. */
bool crt_fpga_switch(unsigned pclock_hz,
                     unsigned hact, unsigned hbeg, unsigned hend, unsigned htot,
                     unsigned vact, unsigned vbeg, unsigned vend, unsigned vtot,
                     bool interlace);

/* Stream one finished frame (called from the video driver / crt switch
 * path). pixels are RGB565 unless the device is in palette mode. */
bool crt_fpga_frame(const void *pixels, unsigned width, unsigned height,
                    unsigned pitch);

void crt_fpga_free(void);

RETRO_END_DECLS

#endif
