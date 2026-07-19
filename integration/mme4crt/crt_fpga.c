/* crt_fpga.c -- FPGA (CRT1) backend for video_crt_switch.c
 *
 * Author: Ben Templeman (alphanu1)
 * Date:   2026-07-17
 *
 * Build gate: only compiled when HAVE_CRT_FPGA is defined (needs
 * libftdi1 and/or libusb). Without it, the stubs in the #else branch let
 * video_crt_switch.c call the same names as no-ops -- native switching
 * is unaffected.
 *
 * C89, 3-space indent, snprintf only.
 */

#include "crt_fpga.h"

#ifdef HAVE_CRT_FPGA

#include <string.h>
#include <libftdi1/ftdi.h>
#include "../host/c/crt1.h"     /* adjust include path to your tree */

#define CRT_FPGA_REF_HZ 50000000UL
#define CRT_FPGA_VID    0x0403
#define CRT_FPGA_PID    0x6010

static struct ftdi_context *g_ftdi   = NULL;
static bool                 g_active  = false;
static struct crt1_tx       g_tx;

static int fpga_write(void *ctx, const unsigned char *buf, size_t len)
{
   int n = ftdi_write_data((struct ftdi_context *)ctx,
                           (unsigned char *)buf, (int)len);
   return (n == (int)len) ? n : -1;
}

bool crt_fpga_init(void)
{
   if (g_active)
      return true;

   g_ftdi = ftdi_new();
   if (!g_ftdi)
      return false;

   ftdi_set_interface(g_ftdi, INTERFACE_A);
   if (ftdi_usb_open(g_ftdi, CRT_FPGA_VID, CRT_FPGA_PID) < 0)
   {
      /* no device -- clean up, let RA use native switching */
      ftdi_free(g_ftdi);
      g_ftdi = NULL;
      return false;
   }

   ftdi_set_bitmode(g_ftdi, 0x00, BITMODE_RESET);

   g_tx.ctx   = g_ftdi;
   g_tx.write = fpga_write;
   g_tx.read  = NULL;
   g_tx.close = NULL;
   g_active   = true;

   /* optional: CMD_GET_INFO handshake could confirm proto/version here */
   return true;
}

bool crt_fpga_active(void)
{
   return g_active;
}

bool crt_fpga_switch(unsigned pclock_hz,
                     unsigned hact, unsigned hbeg, unsigned hend, unsigned htot,
                     unsigned vact, unsigned vbeg, unsigned vend, unsigned vtot,
                     bool interlace)
{
   struct crt1_modeline ml;
   unsigned m, n, c;

   if (!g_active)
      return false;

   crt1_pll_search(CRT_FPGA_REF_HZ, pclock_hz, &m, &n, &c);
   crt1_send_pll(&g_tx, m, n, c);

   memset(&ml, 0, sizeof(ml));
   ml.pclock_hz = pclock_hz;
   ml.hactive = (unsigned short)hact; ml.hbegin = (unsigned short)hbeg;
   ml.hend    = (unsigned short)hend; ml.htotal = (unsigned short)htot;
   ml.vactive = (unsigned short)vact; ml.vbegin = (unsigned short)vbeg;
   ml.vend    = (unsigned short)vend; ml.vtotal = (unsigned short)vtot;
   ml.flags   = interlace ? 1 : 0;
   ml.pixfmt  = CRT1_PIXFMT_RGB565;

   return crt1_send_mode(&g_tx, &ml) == 0;
}

bool crt_fpga_frame(const void *pixels, unsigned width, unsigned height,
                    unsigned pitch)
{
   const unsigned char *src = (const unsigned char *)pixels;
   unsigned y;

   if (!g_active || !pixels)
      return false;

   /* stream row by row to strip any pitch padding (RGB565 = 2 bytes) */
   if (crt1_send_frame(&g_tx, 0, 0, width, height, NULL, 0) != 0)
      return false;
   for (y = 0; y < height; y++)
      g_tx.write(g_tx.ctx, src + (size_t)y * pitch, (size_t)width * 2);
   return true;
}

void crt_fpga_free(void)
{
   if (g_ftdi)
   {
      ftdi_usb_close(g_ftdi);
      ftdi_free(g_ftdi);
      g_ftdi = NULL;
   }
   g_active = false;
}

#else /* !HAVE_CRT_FPGA -- no-op stubs so callers link unconditionally */

bool crt_fpga_init(void)      { return false; }
bool crt_fpga_active(void)    { return false; }
bool crt_fpga_switch(unsigned a, unsigned b, unsigned c, unsigned d,
                     unsigned e, unsigned f, unsigned g, unsigned h,
                     unsigned i, bool j)
{
   (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;(void)h;
   (void)i;(void)j; return false;
}
bool crt_fpga_frame(const void *p, unsigned w, unsigned h, unsigned pitch)
{
   (void)p;(void)w;(void)h;(void)pitch; return false;
}
void crt_fpga_free(void)      { }

#endif
