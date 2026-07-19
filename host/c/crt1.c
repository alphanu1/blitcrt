/* crt1.c -- CRT1 protocol implementation (C89, no OS deps) */

#include "crt1.h"

static void put32(unsigned char *p, unsigned long v)
{
   p[0] = (unsigned char)(v & 0xFF);
   p[1] = (unsigned char)((v >> 8) & 0xFF);
   p[2] = (unsigned char)((v >> 16) & 0xFF);
   p[3] = (unsigned char)((v >> 24) & 0xFF);
}

static void put16(unsigned char *p, unsigned short v)
{
   p[0] = (unsigned char)(v & 0xFF);
   p[1] = (unsigned char)((v >> 8) & 0xFF);
}

static int send_pkt(struct crt1_tx *tx, unsigned char cmd,
                    const unsigned char *payload, unsigned long len)
{
   unsigned char hdr[12];
   put32(hdr + 0, CRT1_MAGIC);
   hdr[4] = cmd;
   hdr[5] = 0;
   hdr[6] = 0;
   hdr[7] = 0;
   put32(hdr + 8, len);
   if (tx->write(tx->ctx, hdr, 12) < 0)
      return -1;
   if (len && tx->write(tx->ctx, payload, (size_t)len) < 0)
      return -1;
   return 0;
}

unsigned long crt1_pll_search(unsigned long ref_hz, unsigned long target_hz,
                              unsigned *m_out, unsigned *n_out, unsigned *c_out)
{
   /* integer M/N/C search, VCO 600-1300MHz, PFD floor 5MHz */
   double best_err = 1e30;
   unsigned bm = 0, bn = 1, bc = 1;
   double best_ach = 0.0;
   unsigned n, m, cc;

   for (n = 1; n <= 10; n++)
   {
      double pfd = (double)ref_hz / n;
      unsigned m_lo, m_hi;
      if (pfd < 5000000.0)
         continue;
      m_lo = (unsigned)(600000000.0 / pfd);
      if (m_lo < 1) m_lo = 1;
      m_hi = (unsigned)(1300000000.0 / pfd) + 1;
      if (m_hi > 512) m_hi = 512;
      for (m = m_lo; m <= m_hi; m++)
      {
         double vco = pfd * m;
         unsigned c0;
         if (vco < 600000000.0 || vco > 1300000000.0)
            continue;
         c0 = (unsigned)(vco / target_hz + 0.5);
         for (cc = (c0 > 1 ? c0 - 1 : 1); cc <= c0 + 1 && cc <= 512; cc++)
         {
            double ach = vco / cc;
            double err = ach - (double)target_hz;
            if (err < 0) err = -err;
            if (err < best_err)
            {
               best_err = err;
               best_ach = ach;
               bm = m; bn = n; bc = cc;
            }
         }
      }
   }
   *m_out = bm; *n_out = bn; *c_out = bc;
   return (unsigned long)(best_ach + 0.5);
}

int crt1_send_mode(struct crt1_tx *tx, const struct crt1_modeline *ml)
{
   unsigned char p[32];
   put32(p + 0, ml->pclock_hz);
   put16(p + 4, ml->hactive);  put16(p + 6, ml->hbegin);
   put16(p + 8, ml->hend);     put16(p + 10, ml->htotal);
   put16(p + 12, ml->vactive); put16(p + 14, ml->vbegin);
   put16(p + 16, ml->vend);    put16(p + 18, ml->vtotal);
   put16(p + 20, ml->flags);
   p[22] = ml->pixfmt ? ml->pixfmt : CRT1_PIXFMT_RGB565;
   p[23] = 0;
   put32(p + 24, 0);
   put32(p + 28, 0);
   return send_pkt(tx, CRT1_CMD_SET_MODE, p, 32);
}

int crt1_send_pll(struct crt1_tx *tx, unsigned m, unsigned n, unsigned c)
{
   unsigned char p[12];
   put32(p + 0, m); put32(p + 4, n); put32(p + 8, c);
   return send_pkt(tx, CRT1_CMD_SET_PLL, p, 12);
}

int crt1_send_pal(struct crt1_tx *tx, unsigned char idx, unsigned short rgb444)
{
   unsigned char p[4];
   p[0] = idx; p[1] = 0;
   put16(p + 2, rgb444);
   return send_pkt(tx, CRT1_CMD_SET_PAL, p, 4);
}

int crt1_send_frame(struct crt1_tx *tx, unsigned x, unsigned y,
                    unsigned w, unsigned h,
                    const unsigned char *pixels, size_t bytes)
{
   unsigned char hdr[12 + 16];
   put32(hdr + 0, CRT1_MAGIC);
   hdr[4] = CRT1_CMD_FRAME; hdr[5] = 0; hdr[6] = 0; hdr[7] = 0;
   put32(hdr + 8, (unsigned long)(16 + bytes));
   put32(hdr + 12, x); put32(hdr + 16, y);
   put32(hdr + 20, w); put32(hdr + 24, h);
   if (tx->write(tx->ctx, hdr, 12 + 16) < 0)
      return -1;
   if (bytes && tx->write(tx->ctx, pixels, bytes) < 0)
      return -1;
   return 0;
}
