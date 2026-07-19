/* video_crt1.c -- RetroArch video driver: CRT1 over FTDI (fpga15k) or
 *                 USB bulk (CRTPi). Drop into gfx/drivers/ in MME4CRT.
 *
 * Author: Ben Templeman (alphanu1)
 * Date:   2026-07-17
 *
 * This is a headless "display" driver: it does no local rendering.
 * switchres still runs (its modeline is intercepted and sent as
 * CMD_SET_MODE via crt1_set_mode below); each RetroArch frame is
 * packetized as CMD_FRAME and streamed to the device.
 *
 * Transport is abstracted (crt1_tx_*) so the same driver serves the
 * FPGA (libftdi) and the Pi (libusb) by linking a different backend.
 *
 * Minimal, illustrative: error handling and format paths trimmed to
 * show the integration shape, not to be drop-in complete.
 */
#include <stdint.h>
#include <string.h>

#include "../../retroarch.h"
#include "../video_driver.h"
#include "crt1_tx.h"          /* crt1_tx_open/write/close (ftdi or usb) */

#define MAGIC 0x31545243u
enum { CMD_SET_MODE=0x10, CMD_SET_PLL=0x11, CMD_FRAME=0x20 };

typedef struct {
   crt1_tx_t *tx;
   unsigned   width, height;    /* current mode active area */
   uint8_t    seq;
} crt1_video_t;

/* --- packet helper --- */
static void crt1_send(crt1_tx_t *tx, uint8_t cmd, uint8_t seq,
                      const void *payload, uint32_t len)
{
   uint8_t hdr[12];
   hdr[0]=MAGIC&0xFF; hdr[1]=(MAGIC>>8)&0xFF;
   hdr[2]=(MAGIC>>16)&0xFF; hdr[3]=(MAGIC>>24)&0xFF;
   hdr[4]=cmd; hdr[5]=0; hdr[6]=seq; hdr[7]=0;
   hdr[8]=len&0xFF; hdr[9]=(len>>8)&0xFF;
   hdr[10]=(len>>16)&0xFF; hdr[11]=(len>>24)&0xFF;
   crt1_tx_write(tx, hdr, 12);
   if (len) crt1_tx_write(tx, payload, len);
}

/* Called from the switchres integration when a mode is chosen. The
 * modeline fields map 1:1 to wire_modeline (positions, switchres
 * semantics). Also emits CMD_SET_PLL when a device needs host-computed
 * dividers (FPGA); the Pi ignores/uses pclock directly. */
void crt1_set_mode(void *data, const switchres_modeline_t *ml)
{
   crt1_video_t *v = (crt1_video_t*)data;
   uint8_t p[32];
   /* pack wire_modeline (see docs/PROTOCOL.md) */
   uint32_t pclk = ml->pclock;
   memcpy(p+0,  &pclk, 4);
   uint16_t f[8] = { ml->hactive, ml->hbegin, ml->hend, ml->htotal,
                     ml->vactive, ml->vbegin, ml->vend, ml->vtotal };
   memcpy(p+4, f, 16);
   uint16_t flags = (ml->interlace?1:0);
   memcpy(p+20, &flags, 2);
   p[22]=1 /*RGB565*/; p[23]=0;
   memset(p+24, 0, 8);
   crt1_send(v->tx, CMD_SET_MODE, v->seq++, p, 32);
   v->width = ml->hactive; v->height = ml->vactive;
}

/* RetroArch calls this every frame with a finished framebuffer. */
static bool crt1_frame(void *data, const void *frame,
      unsigned width, unsigned height, uint64_t frame_count,
      unsigned pitch, const char *msg, video_frame_info_t *info)
{
   crt1_video_t *v = (crt1_video_t*)data;
   uint8_t fhdr[16];
   uint32_t z=0, w=width, h=height;
   if (!frame) return true;                 /* dupe: device holds last */

   memcpy(fhdr+0,&z,4); memcpy(fhdr+4,&z,4);
   memcpy(fhdr+8,&w,4); memcpy(fhdr+12,&h,4);

   /* header + rows. If pitch==width*bpp we can stream directly;
    * otherwise send row by row to strip padding. RGB565 assumed. */
   crt1_send(v->tx, CMD_FRAME, v->seq++, NULL, 16 + w*h*2);
   crt1_tx_write(v->tx, fhdr, 16);
   {
      const uint8_t *src = (const uint8_t*)frame;
      unsigned y;
      for (y=0; y<height; y++)
         crt1_tx_write(v->tx, src + (size_t)y*pitch, w*2);
   }
   return true;
}

static void *crt1_init(const video_info_t *video,
      input_driver_t **input, void **input_data)
{
   crt1_video_t *v = (crt1_video_t*)calloc(1, sizeof(*v));
   v->tx = crt1_tx_open();          /* ftdi or usb backend */
   (void)video; (void)input; (void)input_data;
   return v;
}

static void crt1_free(void *data)
{
   crt1_video_t *v = (crt1_video_t*)data;
   if (!v) return;
   crt1_tx_close(v->tx);
   free(v);
}

/* remaining vtable entries (set_nonblock_state, alive, focus, ...)
 * are thin stubs; see video_driver.h for the full struct. */
video_driver_t video_crt1 = {
   crt1_init,
   crt1_frame,
   NULL,            /* set_nonblock_state */
   NULL,            /* alive  */
   NULL,            /* focus  */
   NULL,            /* suppress_screensaver */
   NULL,            /* has_windowed */
   NULL,            /* set_shader */
   crt1_free,
   "crt1",
   /* ... */
};
