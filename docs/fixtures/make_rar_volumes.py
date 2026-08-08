#!/usr/bin/env python3
"""Genera un RAR 4.x (storing, 0x30) partido en **2 volumenes**, para probar el camino de
lectura multivolumen nativa de libarchive (`archive_read_open_filenames`). Un fichero
("partido.txt") queda partido entre los dos volumenes (LHD_SPLIT_BEFORE/AFTER); un segundo
fichero ("entero.txt") vive entero en el segundo volumen, para ejercitar varias entradas.

Uso: make_rar_volumes.py <vol1.rar> <vol2.rar>
"""
import struct, sys, binascii

def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF

MHD_VOLUME = 0x0001
LHD_SPLIT_BEFORE = 0x0001
LHD_SPLIT_AFTER = 0x0002
LONG_BLOCK = 0x8000

FTIME = (((2026 - 1980) << 25) | (7 << 21) | (1 << 16) | (12 << 11))  # 2026-07-01 12:00

SPLIT_NAME = b"partido.txt"
SPLIT_CONTENT = b"Contenido partido entre dos volumenes RAR nativos, de verdad."
SPLIT_AT = 28   # bytes en el volumen 1; el resto va al volumen 2

WHOLE_NAME = b"entero.txt"
WHOLE_CONTENT = b"Este fichero vive entero en el segundo volumen."


def marker() -> bytes:
    return b"\x52\x61\x72\x21\x1A\x07\x00"


def main_head(flags: int) -> bytes:
    body = struct.pack("<BHHHI", 0x73, flags, 13, 0, 0)
    return struct.pack("<H", crc32(body) & 0xFFFF) + body


def file_head(name: bytes, flags: int, pack_size: int, unp_size: int, content_for_crc: bytes) -> bytes:
    head_size = 32 + len(name)
    body = struct.pack("<BHH", 0x74, flags | LONG_BLOCK, head_size)
    body += struct.pack("<II", pack_size, unp_size)
    body += struct.pack("<B", 0x02)                     # HOST_OS
    body += struct.pack("<I", crc32(content_for_crc))   # FILE_CRC
    body += struct.pack("<I", FTIME)
    body += struct.pack("<B", 20)                       # UNP_VER
    body += struct.pack("<B", 0x30)                     # METHOD storing
    body += struct.pack("<H", len(name))
    body += struct.pack("<I", 0x20)                     # ATTR
    body += name
    return struct.pack("<H", crc32(body) & 0xFFFF) + body


def endarc(flags: int) -> bytes:
    body = struct.pack("<BHH", 0x7b, flags, 7)
    return struct.pack("<H", crc32(body) & 0xFFFF) + body


part1 = SPLIT_CONTENT[:SPLIT_AT]
part2 = SPLIT_CONTENT[SPLIT_AT:]
assert part1 and part2

# --- Volumen 1: marcador + MAIN_HEAD(MHD_VOLUME) + FILE_HEAD(partido.txt, SPLIT_AFTER) + ENDARC ---
vol1 = marker()
vol1 += main_head(MHD_VOLUME)
vol1 += file_head(SPLIT_NAME, LHD_SPLIT_AFTER, len(part1), len(SPLIT_CONTENT), SPLIT_CONTENT) + part1
vol1 += endarc(0x4000 | 0x0001)   # end-of-volume, no es el ultimo volumen (0x0001 = EARC_NEXT_VOLUME)

# --- Volumen 2: marcador + MAIN_HEAD(MHD_VOLUME) + FILE_HEAD(partido.txt, SPLIT_BEFORE) + resto
#     + FILE_HEAD(entero.txt) + ENDARC (ultimo volumen) ---
vol2 = marker()
vol2 += main_head(MHD_VOLUME)
vol2 += file_head(SPLIT_NAME, LHD_SPLIT_BEFORE, len(part2), len(SPLIT_CONTENT), SPLIT_CONTENT) + part2
vol2 += file_head(WHOLE_NAME, 0, len(WHOLE_CONTENT), len(WHOLE_CONTENT), WHOLE_CONTENT) + WHOLE_CONTENT
vol2 += endarc(0x4000)

with open(sys.argv[1], "wb") as f:
    f.write(vol1)
with open(sys.argv[2], "wb") as f:
    f.write(vol2)
print(f"escrito {sys.argv[1]} ({len(vol1)} bytes) y {sys.argv[2]} ({len(vol2)} bytes)")
