#!/usr/bin/env python3
"""Genera assets/icon.png (1024x1024): una ventana estilo Windows 95 con una onda de audio.
Solo biblioteca estándar. Uso: python3 scripts/make-icon.py"""
import struct, zlib, os

N = 1024
px = bytearray(N * N * 4)  # RGBA, transparente


def rect(x0, y0, x1, y1, c):
    for y in range(max(y0, 0), min(y1, N)):
        row = (y * N + max(x0, 0)) * 4
        for _ in range(max(x0, 0), min(x1, N)):
            px[row:row + 4] = bytes(c)
            row += 4


def rounded(x0, y0, x1, y1, r, c):
    for y in range(y0, y1):
        for x in range(x0, x1):
            cx = min(max(x, x0 + r), x1 - r - 1)
            cy = min(max(y, y0 + r), y1 - r - 1)
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                i = (y * N + x) * 4
                px[i:i + 4] = bytes(c)


TEAL, GRAY, WHITE = (0, 128, 128, 255), (192, 192, 192, 255), (255, 255, 255, 255)
DARK, BLACK, NAVY = (128, 128, 128, 255), (0, 0, 0, 255), (0, 0, 128, 255)

rounded(0, 0, N, N, 200, TEAL)                      # escritorio turquesa
x0, y0, x1, y1 = 130, 190, 894, 834                 # ventana
rect(x0, y0, x1, y1, BLACK)
rect(x0 + 8, y0 + 8, x1 - 8, y1 - 8, WHITE)         # bisel claro
rect(x0 + 16, y0 + 16, x1 - 8, y1 - 8, DARK)        # bisel oscuro
rect(x0 + 16, y0 + 16, x1 - 16, y1 - 16, GRAY)      # cuerpo
rect(x0 + 32, y0 + 32, x1 - 32, y0 + 140, NAVY)     # barra de título
for i in range(3):                                  # botones de la barra
    bx = x1 - 32 - 90 * (i + 1) - 10 * i
    rect(bx, y0 + 48, bx + 90, y0 + 124, GRAY)
    rect(bx, y0 + 48, bx + 90, y0 + 54, WHITE)
    rect(bx, y0 + 118, bx + 90, y0 + 124, DARK)
rect(x0 + 52, y0 + 66, x0 + 250, y0 + 106, WHITE)   # "título"
ix0, iy0, ix1, iy1 = x0 + 48, y0 + 176, x1 - 48, y1 - 48
rect(ix0, iy0, ix1, iy1, DARK)                      # hueco hundido
rect(ix0 + 8, iy0 + 8, ix1, iy1, WHITE)
rect(ix0 + 8, iy0 + 8, ix1 - 8, iy1 - 8, (255, 255, 255, 255))
heights = [90, 170, 260, 340, 240, 380, 300, 200, 320, 150, 220, 100]  # onda
bw, gap = 28, 20
total = len(heights) * bw + (len(heights) - 1) * gap
sx = ix0 + 8 + ((ix1 - ix0 - 16) - total) // 2
mid = (iy0 + iy1) // 2
for i, h in enumerate(heights):
    bx = sx + i * (bw + gap)
    rect(bx, mid - h // 2, bx + bw, mid + h // 2, NAVY if i % 2 == 0 else TEAL)

raw = b"".join(b"\x00" + bytes(px[y * N * 4:(y + 1) * N * 4]) for y in range(N))


def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
out = os.path.join(os.path.dirname(__file__), "..", "assets", "icon.png")
open(out, "wb").write(png)
print("Creado", os.path.normpath(out))
