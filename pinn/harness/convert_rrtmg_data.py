#!/usr/bin/env python3
"""Convertit un fichier de donnees RRTMG de WRF (big-endian, record markers 4 octets)
en little-endian natif (record markers 4 octets).

Les fichiers run/RRTMG_{SW,LW}_DATA de WRF sont big-endian (WRF compile avec
-fconvert=big-endian). En simple precision (RWORDSIZE=4, comme le conteneur NCAR)
tous les elements des records font 4 octets (real*4 + integer*4) -> un swap par
mots de 4 octets convertit exactement donnees ET record markers.

Usage: python3 convert_rrtmg_data.py <fichier> [sortie]   (defaut: <fichier>.le)
"""
import struct
import sys


def convert(src, dst):
    data = open(src, "rb").read()
    n = len(data)
    out = bytearray()
    o = 0
    nrec = 0
    while o + 8 <= n:
        m = struct.unpack(">I", data[o:o + 4])[0]  # record marker BE
        if m <= 0 or m % 4 or o + 4 + m + 4 > n:
            raise SystemExit(f"record invalide a l'offset {o} (marqueur={m}, reste={n - o})")
        if struct.unpack(">I", data[o + 4 + m:o + 8 + m])[0] != m:
            raise SystemExit(f"marqueur de fin incoherent a l'offset {o}")
        rec = data[o + 4:o + 4 + m]
        sw = bytearray(m)
        for i in range(0, m, 4):
            sw[i:i + 4] = rec[i:i + 4][::-1]
        out += struct.pack("<I", m) + sw + struct.pack("<I", m)
        o += 4 + m + 4
        nrec += 1
    if o != n:
        raise SystemExit(f"fin inattendue: offset={o} taille={n}")
    open(dst, "wb").write(bytes(out))
    print(f"OK: {src} -> {dst} ({nrec} records, {n} octets, BE->LE)")


if __name__ == "__main__":
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src + ".le"
    convert(src, dst)
