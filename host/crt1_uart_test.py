#!/usr/bin/env python3
# crt1_uart_test.py -- send CRT1 packets to BlitCRT over a plain USB-serial
# UART (bring-up, no FT2232H needed). Same protocol as crt1_ftdi_test.py.
#
# Author: Ben Templeman (alphanu1)
# Date:   2026-07-17
#
# Requires: pip install pyserial
# Usage:
#   ./crt1_uart_test.py /dev/ttyUSB0 6400000 320 328 359 407 240 244 247 262
#   (on Windows the port is like COM5)
#
# Sends SET_PLL, SET_MODE, a palette, and one 4bpp colour-bar frame.
# NOTE: UART is for TESTING mode changes + static frames only (~2-8 fps
# full-frame). Live video streaming needs the FT2232H sync-FIFO path.
# Default 3,000,000 baud -- must match the FPGA's UART_CLKS_PER_BIT
# (50MHz/3M = 16). For a flaky cable, drop to 921600 here AND rebuild the
# bitstream with UART_CLKS_PER_BIT=54.
import struct
import sys

REF_HZ = 50_000_000
VCO_MIN, VCO_MAX = 600e6, 1300e6
MAGIC = 0x31545243
CMD_SET_MODE, CMD_SET_PLL, CMD_FRAME, CMD_SET_PAL = 0x10, 0x11, 0x20, 0x30
HDR = struct.Struct("<IBBHI")


def pll_search(target):
    best = None
    for n in range(1, 11):
        pfd = REF_HZ / n
        if pfd < 5e6:
            continue
        m_lo = max(1, int(VCO_MIN / pfd))
        m_hi = min(512, int(VCO_MAX / pfd) + 1)
        for m in range(m_lo, m_hi + 1):
            vco = pfd * m
            if not (VCO_MIN <= vco <= VCO_MAX):
                continue
            c = round(vco / target)
            for cc in (c - 1, c, c + 1):
                if 1 <= cc <= 512:
                    err = abs(vco / cc - target)
                    if best is None or err < best[3]:
                        best = (m, n, cc, err, vco / cc)
    m, n, c, _, ach = best
    return m, n, c, ach


def pkt(cmd, payload=b""):
    return HDR.pack(MAGIC, cmd, 0, 0, len(payload)) + payload


def main():
    if len(sys.argv) < 11:
        sys.exit("usage: crt1_uart_test.py PORT pclk hact hbeg hend htot "
                 "vact vbeg vend vtot")
    port = sys.argv[1]
    v = [int(a) for a in sys.argv[2:11]]
    target = v[0]

    m, n, c, ach = pll_search(target)
    print("pll: target %d -> m=%d n=%d c=%d achieved %.1f Hz (%.1f ppm)"
          % (target, m, n, c, ach, 1e6 * (ach - target) / target))

    import serial
    ser = serial.Serial(port, 3_000_000, timeout=1)

    ser.write(pkt(CMD_SET_PLL, struct.pack("<III", m, n, c)))
    mode = struct.pack("<I9HBxQ", target, v[1], v[2], v[3], v[4],
                       v[5], v[6], v[7], v[8], 0, 1, 0)
    ser.write(pkt(CMD_SET_MODE, mode))

    bars = [0xFFF, 0xFF0, 0x0FF, 0x0F0, 0xF0F, 0xF00, 0x00F, 0x000]
    for i, rgb in enumerate(bars):
        ser.write(pkt(CMD_SET_PAL, struct.pack("<BBH", i, 0, rgb)))

    w, h = v[1], v[5]
    row = bytearray()
    for x in range(0, w, 2):
        p0 = x * 8 // w
        p1 = (x + 1) * 8 // w
        row.append((p0 << 4) | p1)
    frame = struct.pack("<IIII", 0, 0, w, h) + bytes(row) * h
    ser.write(pkt(CMD_FRAME, frame))

    ser.flush()
    print("sent SET_PLL, SET_MODE, palette, %dx%d frame over %s" % (w, h, port))
    ser.close()


if __name__ == "__main__":
    main()
