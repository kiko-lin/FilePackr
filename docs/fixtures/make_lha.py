#!/usr/bin/env python3
"""Genera un .lha con cabeceras de nivel 0 y metodo '-lh0-' (almacenado, sin compresion).
libarchive lo lee. Formato clasico LHarc: por fichero, [cabecera + datos]; fin = byte 0x00."""
import struct, sys

def crc16(data: bytes) -> int:
    """CRC-16/ARC (poly reflejado 0xA001), el que usa LHA."""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if (crc & 1) else (crc >> 1)
    return crc & 0xFFFF

files = [
    ("hola.txt", b"Hola mundo lha"),        # 14 bytes
    ("config.json", b'{"clave":"valor"}'),  # 17 bytes
]

# MS-DOS date/time (2026-07-01 12:00:00) empaquetado en 4 bytes LE
dostime = ((12 << 11) | (0 << 5) | 0)
dosdate = (((2026 - 1980) << 9) | (7 << 5) | 1)
mtime = (dosdate << 16) | dostime

out = b""
for name, content in files:
    namebytes = name.encode("ascii")
    size = len(content)
    # Cuerpo de la cabecera desde el byte 2 (tras size+checksum):
    body = b"-lh0-"                                  # metodo (5)
    body += struct.pack("<I", size)                  # tam. comprimido (== original en lh0)
    body += struct.pack("<I", size)                  # tam. original
    body += struct.pack("<I", mtime)                 # fecha/hora MS-DOS
    body += bytes([0x20])                            # atributo
    body += bytes([0x00])                            # nivel de cabecera = 0
    body += bytes([len(namebytes)])                  # longitud del nombre
    body += namebytes                                # nombre
    body += struct.pack("<H", crc16(content))        # CRC-16 del contenido
    header_size = len(body)                          # byte 0
    checksum = sum(body) & 0xFF                      # byte 1
    out += bytes([header_size, checksum]) + body + content

out += b"\x00"   # marcador de fin
with open(sys.argv[1], "wb") as f:
    f.write(out)
print(f"escrito {sys.argv[1]} ({len(out)} bytes)")
