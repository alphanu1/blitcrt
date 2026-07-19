/* crt1.h -- CRT1 protocol + transport abstraction (C89)
 *
 * Author: Ben Templeman (alphanu1)
 * Date:   2026-07-17
 *
 * Shared by the standalone C test client and the MME4CRT integration.
 * Transport is a function-pointer table so the same packet code drives
 * the FPGA (libftdi) or the Pi (libusb).
 */
#ifndef CRT1_H
#define CRT1_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CRT1_MAGIC        0x31545243u
#define CRT1_CMD_GET_INFO 0x01
#define CRT1_CMD_SET_MODE 0x10
#define CRT1_CMD_SET_PLL  0x11
#define CRT1_CMD_FRAME    0x20
#define CRT1_CMD_SET_PAL  0x30
#define CRT1_EVT_INFO     0x81
#define CRT1_EVT_MODE_RESULT 0x90
#define CRT1_EVT_STATUS   0xA0

#define CRT1_PIXFMT_RGB565   1
#define CRT1_PIXFMT_XRGB8888 2

/* switchres-semantics modeline (positions, not porches) */
struct crt1_modeline {
   unsigned long  pclock_hz;
   unsigned short hactive, hbegin, hend, htotal;
   unsigned short vactive, vbegin, vend, vtotal;
   unsigned short flags;       /* bit0 interlace */
   unsigned char  pixfmt;
};

/* transport: open returns opaque handle or NULL; write returns bytes or <0 */
struct crt1_tx {
   void *ctx;
   int  (*write)(void *ctx, const unsigned char *buf, size_t len);
   int  (*read) (void *ctx, unsigned char *buf, size_t len); /* may be NULL */
   void (*close)(void *ctx);
};

/* PLL divider search for the FPGA (m/n/c for pclk = ref*m/(n*c)).
 * ref_hz e.g. 50000000. Returns achieved Hz; fills m,n,c. */
unsigned long crt1_pll_search(unsigned long ref_hz, unsigned long target_hz,
                              unsigned *m, unsigned *n, unsigned *c);

/* packet senders (return 0 on success) */
int crt1_send_mode (struct crt1_tx *tx, const struct crt1_modeline *ml);
int crt1_send_pll  (struct crt1_tx *tx, unsigned m, unsigned n, unsigned c);
int crt1_send_pal  (struct crt1_tx *tx, unsigned char idx, unsigned short rgb444);
int crt1_send_frame(struct crt1_tx *tx, unsigned x, unsigned y,
                    unsigned w, unsigned h,
                    const unsigned char *pixels, size_t bytes);

#ifdef __cplusplus
}
#endif
#endif /* CRT1_H */
