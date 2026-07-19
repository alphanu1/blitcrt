#!/usr/bin/env python3
# crt1_ftdi_test.py -- fpga15k v2 host client (CRT1 over FT2232H FIFO)
#
# Author: Ben Templeman (alphanu1)
# Date:   2026-07-17
#
# The FPGA twin of crtpi/host/crt1_test.py: same protocol, different
# transport. Computes PLL dividers for the requested pixel clock
# (host-side M/N/C search -- the FPGA has no CPU to do it), sends
# SET_PLL + SET_MODE, prints the achieved clock, pushes color bars.
#
# Requires: pip install pyftdi   (FT2232H channel A in async FIFO mode)
#
# Usage:
#   ./crt1_ftdi_test.py 6400000 320 328 359 407 240 244 247 262
#
import struct
import sys

REF_HZ = 50_000_000          # DVK600 oscillator
VCO_MIN, VCO_MAX = 600e6, 1300e6
M_MAX, N_MAX, C_MAX = 512, 512, 512

MAGIC = 0x31545243
CMD_GET_INFO, CMD_SET_MODE, CMD_SET_PLL = 0x01, 0x10, 0x11
CMD_FRAME, CMD_SET_PAL = 0x20, 0x30

HDR = struct.Struct("<IBBHI")
MODELINE = struct.Struct("<I9HBxQ")


def pll_search(target_hz):
    """Best integer (m, n, c) for pclk = REF*m/(n*c), VCO in range.
    Returns (m, n, c, achieved_hz, error_ppm)."""
    best = None
    for n in range(1, 11):
        pfd = REF_HZ / n
        if pfd < 5_000_000:                     # Cyclone IV PFD floor
            continue
        m_lo = max(1, int(VCO_MIN / pfd))
        m_hi = min(M_MAX, int(VCO_MAX / pfd) + 1)
        for m in range(m_lo, m_hi + 1):
            vco = pfd * m
            if not (VCO_MIN <= vco <= VCO_MAX):
                continue
            c = round(vco / target_hz)
            for cc in (c - 1, c, c + 1):
                if 1 <= cc <= C_MAX:
                    ach = vco / cc
                    err = abs(ach - target_hz)
                    if best is None or err < best[4]:
                        best = (m, n, cc, ach, err)
    m, n, c, ach, err = best
    return m, n, c, ach, 1e6 * err / target_hz


def pkt(cmd, payload=b"", seq=0):
    return HDR.pack(MAGIC, cmd, 0, seq, len(payload)) + payload


def main():
    if len(sys.argv) < 10:
        sys.exit("usage: crt1_ftdi_test.py pclk hact hbeg hend htot "
                 "vact vbeg vend vtot")
    v = [int(a) for a in sys.argv[1:10]]
    target = v[0]

    m, n, c, ach, ppm = pll_search(target)
    print("pll: target %d Hz -> m=%d n=%d c=%d achieved %.1f Hz (%.1f ppm)"
          % (target, m, n, c, ach, ppm))
    hf = ach / v[4]
    vf = hf / v[8]
    print("     => hfreq %.3f kHz  vfreq %.4f Hz" % (hf / 1e3, vf))

    from pyftdi.ftdi import Ftdi
    ftdi = Ftdi()
    ftdi.open(vendor=0x0403, product=0x6010, interface=1)
    ftdi.set_bitmode(0x00, Ftdi.BitMode.RESET)      # async FIFO (EEPROM-set)

    def send(b):
        ftdi.write_data(b)

    # 1. clock first, then geometry (mode latches at next frame boundary)
    send(pkt(CMD_SET_PLL, struct.pack("<III", m, n, c), seq=1))
    mode = MODELINE.pack(target, v[1], v[2], v[3], v[4],
                         v[5], v[6], v[7], v[8], 0, 1, 0xF00D)
    send(pkt(CMD_SET_MODE, mode, seq=2))

    # 2. palette: 8 bar colors into entries 0..7
    bars = [0xFFF, 0xFF0, 0x0FF, 0x0F0, 0xF0F, 0xF00, 0x00F, 0x000]
    for i, rgb in enumerate(bars):
        send(pkt(CMD_SET_PAL, struct.pack("<BBH", i, 0, rgb), seq=3 + i))

    # 3. one full frame, 4bpp packed (two pixels/byte, high nibble first)
    w, h = v[1], v[5]
    row = bytearray()
    for x in range(0, w, 2):
        p0 = x * 8 // w
        p1 = (x + 1) * 8 // w
        row.append((p0 << 4) | p1)
    fhdr = struct.pack("<IIII", 0, 0, w, h)
    send(pkt(CMD_FRAME, fhdr + bytes(row) * h, seq=100))

    print("sent: SET_PLL, SET_MODE, palette, %dx%d frame -- bars on CRT"
          % (w, h))
    # reply parsing (EVT_MODE_RESULT etc.) via ftdi.read_data(): the FPGA
    # answers on the FIFO TX path; left minimal here, mirrored from
    # crtpi/host/crt1_test.py when the TX direction is brought up.


if __name__ == "__main__":
    main()
