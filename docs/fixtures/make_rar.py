#!/usr/bin/env python3
"""Genera un .rar formato RAR 4.x con metodo 'storing' (0x30, sin compresion).
Bloques: marcador + MAIN_HEAD + FILE_HEAD[] + ENDARC. libarchive tiene lector RAR."""
import struct, sys, binascii

def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF

files = [
    ("hola.txt", b"Hola mundo rar"),        # 14 bytes
    ("config.json", b'{"clave":"valor"}'),  # 17 bytes
]

FTIME = (((2026 - 1980) << 25) | (7 << 21) | (1 << 16) | (12 << 11))  # 2026-07-01 12:00

out = b"\x52\x61\x72\x21\x1A\x07\x00"  # marcador "Rar!\x1a\x07\x00"

# --- MAIN_HEAD (0x73) ---
# tras HEAD_CRC(2): HEAD_TYPE(1) HEAD_FLAGS(2) HEAD_SIZE(2) HighPosAV(2) PosAV(4)
main_body = struct.pack("<BHHHI", 0x73, 0x0000, 13, 0, 0)
main_crc = crc32(main_body) & 0xFFFF
out += struct.pack("<H", main_crc) + main_body

# --- FILE_HEAD (0x74) por fichero ---
for name, content in files:
    namebytes = name.encode("ascii")
    head_size = 32 + len(namebytes)
    # cuerpo desde HEAD_TYPE (para el CRC y el bloque), sin los 2 bytes de HEAD_CRC:
    body = struct.pack("<BHH", 0x74, 0x8000, head_size)  # type, flags(LONG_BLOCK), head_size
    body += struct.pack("<II", len(content), len(content))  # PACK_SIZE, UNP_SIZE
    body += struct.pack("<B", 0x02)                       # HOST_OS (2 = Win) — libarchive tolera
    body += struct.pack("<I", crc32(content))             # FILE_CRC
    body += struct.pack("<I", FTIME)                      # FTIME (MS-DOS)
    body += struct.pack("<B", 20)                         # UNP_VER (2.0)
    body += struct.pack("<B", 0x30)                       # METHOD 0x30 = storing
    body += struct.pack("<H", len(namebytes))             # NAME_SIZE
    body += struct.pack("<I", 0x20)                       # ATTR
    body += namebytes
    head_crc = crc32(body) & 0xFFFF
    out += struct.pack("<H", head_crc) + body + content

# --- ENDARC (0x7b) ---
end_body = struct.pack("<BHH", 0x7b, 0x4000, 7)  # flags 0x4000 = end block
end_crc = crc32(end_body) & 0xFFFF
out += struct.pack("<H", end_crc) + end_body

with open(sys.argv[1], "wb") as f:
    f.write(out)
print(f"escrito {sys.argv[1]} ({len(out)} bytes)")
