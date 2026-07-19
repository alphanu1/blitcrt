#!/usr/bin/env python3
# ref_sweep.py -- evaluate candidate reference oscillators against a
# corpus of real 15kHz arcade dot clocks (worst/mean synthesis ppm).
#
# Author: Ben Templeman (alphanu1)
# Date:   2026-07-17
#
# Conclusion baked into docs/VIDEOCARD_V2.md: reference FREQUENCY is a
# wash (all sensible values ~10-15ppm worst); reference QUALITY is what
# matters (TCXO), and exactness requires fractional-N (Si5351A).

VCO_MIN, VCO_MAX = 600e6, 1300e6

def pll_search_err_ppm(ref, target):
    best = None
    for n in range(1, 11):
        pfd = ref / n
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
                    if best is None or err < best:
                        best = err
    return 1e6 * best / target

TARGETS = [4992000, 5000000, 5369318, 6000000, 6144000, 6293750,
           6400000, 6710886, 7156800, 7500000, 7670454, 8000000]
REFS = [("50.000 (stock)", 50e6), ("40.000", 40e6), ("33.333", 100e6/3),
        ("27.000 (video)", 27e6), ("26.000", 26e6), ("25.000", 25e6),
        ("24.576 (audio)", 24.576e6), ("28.636 (2xNTSC)", 28.636363e6),
        ("19.200 (telecom)", 19.2e6), ("48.000", 48e6)]

if __name__ == "__main__":
    rows = []
    for name, r in REFS:
        errs = [pll_search_err_ppm(r, t) for t in TARGETS]
        rows.append((max(errs), sum(errs) / len(errs), name))
    print("%-18s %10s %10s" % ("reference MHz", "worst ppm", "mean ppm"))
    for worst, mean, name in sorted(rows):
        print("%-18s %10.2f %10.2f" % (name, worst, mean))
