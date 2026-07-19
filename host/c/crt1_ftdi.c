/* crt1_ftdi.c -- libftdi transport + standalone test client
 *
 * Author: Ben Templeman (alphanu1)
 * Date:   2026-07-17
 *
 * C replacement for crt1_ftdi_test.py. Same behavior: PLL search,
 * SET_PLL + SET_MODE, palette, one color-bar frame.
 *
 * Build: cc -O2 -o crt1_ftdi crt1_ftdi.c crt1.c -lftdi1
 * Usage: ./crt1_ftdi 6400000 320 328 359 407 240 244 247 262
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libftdi1/ftdi.h>

#include "crt1.h"

#define REF_HZ 50000000UL

static int ftdi_tx_write(void *ctx, const unsigned char *buf, size_t len)
{
   struct ftdi_context *f = (struct ftdi_context *)ctx;
   int n = ftdi_write_data(f, (unsigned char *)buf, (int)len);
   return (n == (int)len) ? n : -1;
}

static void ftdi_tx_close(void *ctx)
{
   struct ftdi_context *f = (struct ftdi_context *)ctx;
   ftdi_usb_close(f);
   ftdi_free(f);
}

int main(int argc, char **argv)
{
   struct ftdi_context *ftdi;
   struct crt1_tx tx;
   struct crt1_modeline ml;
   unsigned m, n, c, i;
   unsigned long ach, target;
   unsigned char *row;
   unsigned char *frame;
   unsigned w, h, xb;
   static const unsigned short bars[8] = {
      0xFFF, 0xFF0, 0x0FF, 0x0F0, 0xF0F, 0xF00, 0x00F, 0x000
   };

   if (argc < 10)
   {
      fprintf(stderr, "usage: %s pclk hact hbeg hend htot "
              "vact vbeg vend vtot\n", argv[0]);
      return 2;
   }

   memset(&ml, 0, sizeof(ml));
   target      = strtoul(argv[1], NULL, 0);
   ml.pclock_hz = target;
   ml.hactive  = (unsigned short)atoi(argv[2]);
   ml.hbegin   = (unsigned short)atoi(argv[3]);
   ml.hend     = (unsigned short)atoi(argv[4]);
   ml.htotal   = (unsigned short)atoi(argv[5]);
   ml.vactive  = (unsigned short)atoi(argv[6]);
   ml.vbegin   = (unsigned short)atoi(argv[7]);
   ml.vend     = (unsigned short)atoi(argv[8]);
   ml.vtotal   = (unsigned short)atoi(argv[9]);
   ml.pixfmt   = CRT1_PIXFMT_RGB565;

   ach = crt1_pll_search(REF_HZ, target, &m, &n, &c);
   printf("pll: target %lu -> m=%u n=%u c=%u achieved %lu Hz (%.1f ppm)\n",
          target, m, n, c, ach,
          1e6 * ((double)ach - target) / target);

   if ((ftdi = ftdi_new()) == 0)
   {
      fprintf(stderr, "ftdi_new failed\n");
      return 1;
   }
   ftdi_set_interface(ftdi, INTERFACE_A);
   if (ftdi_usb_open(ftdi, 0x0403, 0x6010) < 0)
   {
      fprintf(stderr, "open failed: %s\n", ftdi_get_error_string(ftdi));
      ftdi_free(ftdi);
      return 1;
   }
   ftdi_set_bitmode(ftdi, 0x00, BITMODE_RESET);   /* FIFO per EEPROM */

   tx.ctx = ftdi;
   tx.write = ftdi_tx_write;
   tx.read = NULL;
   tx.close = ftdi_tx_close;

   crt1_send_pll(&tx, m, n, c);
   crt1_send_mode(&tx, &ml);
   for (i = 0; i < 8; i++)
      crt1_send_pal(&tx, (unsigned char)i, bars[i]);

   /* one 4bpp frame of bars: two pixels per byte */
   w = ml.hactive; h = ml.vactive;
   row = (unsigned char *)malloc(w / 2);
   for (xb = 0; xb < w / 2; xb++)
   {
      unsigned p0 = (xb * 2) * 8 / w;
      unsigned p1 = (xb * 2 + 1) * 8 / w;
      row[xb] = (unsigned char)((p0 << 4) | p1);
   }
   frame = (unsigned char *)malloc((size_t)(w / 2) * h);
   for (i = 0; i < h; i++)
      memcpy(frame + (size_t)i * (w / 2), row, w / 2);
   crt1_send_frame(&tx, 0, 0, w, h, frame, (size_t)(w / 2) * h);

   printf("sent SET_PLL, SET_MODE, palette, %ux%u frame\n", w, h);
   free(row); free(frame);
   tx.close(tx.ctx);
   return 0;
}
