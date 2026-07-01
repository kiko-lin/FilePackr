#!/usr/bin/env python3
"""Genera un .cab MSCF *almacenado* (sin compresión) mínimo pero válido.
libarchive lo lee (typeCompress = 0). Formato: CFHEADER + CFFOLDER + CFFILE[] + CFDATA."""
import struct, sys

# Ficheros del fixture (nombre -> contenido). Nombres ASCII (szName sin flag UTF).
files = [
    ("hola.txt", b"Hola mundo cab"),          # 14 bytes
    ("docs\\anidado.txt", b"contenido anidado"),  # CAB usa '\\' como separador
]

# --- Datos concatenados de la carpeta (un solo bloque CFDATA, store) ---
folder_data = b"".join(c for _, c in files)

# --- CFFILE por fichero ---
# cbFile(4) uoffFolderStart(4) iFolder(2) date(2) time(2) attribs(2) szName(z)
DATE = (2026 - 1980) << 9 | (7 << 5) | 1   # 2026-07-01
TIME = (12 << 11) | (0 << 5) | 0           # 12:00:00 (/2 seg)
cffiles = b""
off = 0
for name, content in files:
    szname = name.encode("ascii") + b"\x00"
    cffiles += struct.pack("<IIHHHH", len(content), off, 0, DATE, TIME, 0x20) + szname
    off += len(content)

# --- CFDATA: csum(4)=0 cbData(2) cbUncomp(2) + datos ---
cfdata = struct.pack("<IHH", 0, len(folder_data), len(folder_data)) + folder_data

# --- CFHEADER (36 bytes, sin campos reservados opcionales) ---
HEADER_SIZE = 36
FOLDER_SIZE = 8
coffFiles = HEADER_SIZE + FOLDER_SIZE            # offset del primer CFFILE
coffCabStart = coffFiles + len(cffiles)          # offset del primer CFDATA
cbCabinet = coffCabStart + len(cfdata)           # tamaño total

# CFFOLDER: coffCabStart(4) cCFData(2) typeCompress(2)=0
cffolder = struct.pack("<IHH", coffCabStart, 1, 0)

# signature(4) reserved1(4) cbCabinet(4) reserved2(4) coffFiles(4) reserved3(4)
# versionMinor(1)=3 versionMajor(1)=1 cFolders(2) cFiles(2) flags(2) setID(2) iCabinet(2)
header = struct.pack("<4sIIIIIBBHHHHH",
                     b"MSCF", 0, cbCabinet, 0, coffFiles, 0,
                     3, 1, 1, len(files), 0, 0x1234, 0)

blob = header + cffolder + cffiles + cfdata
assert len(blob) == cbCabinet, (len(blob), cbCabinet)
with open(sys.argv[1], "wb") as f:
    f.write(blob)
print(f"escrito {sys.argv[1]} ({len(blob)} bytes)")
