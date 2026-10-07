#!/usr/bin/env python3
"""Validate a Crystal MRA against ROM zips and (optionally) build the exact ioctl streams it describes.

  python scripts/mra_stream.py "MRA/The Crystal of Kings.mra" --rompath C:/Users/klest/Downloads/mame/roms
        [--out DIR]   write index<N>.bin streams (for simulation; never commit them)

Supports the subset of the MRA format this project uses: <rom index zip>, <part name crc>, <part repeat>,
<part> hex bytes. Prints PASS/FAIL per part and per stream.
"""
import argparse
import pathlib
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mra")
    ap.add_argument("--rompath", default="C:/Users/klest/Downloads/mame/roms")
    ap.add_argument("--out")
    a = ap.parse_args()
    root = ET.parse(a.mra).getroot()
    ok = True
    for rom in root.findall("rom"):
        idx = int(rom.get("index", "0"))
        zips = [z for z in (rom.get("zip") or "").split("|") if z]
        data = bytearray()
        for part in rom.findall("part"):
            if part.get("name"):
                name, crc = part.get("name"), int(part.get("crc"), 16)
                blob = None
                for z in zips:
                    p = pathlib.Path(a.rompath) / z
                    if not p.exists():
                        continue
                    with zipfile.ZipFile(p) as zf:
                        for info in zf.infolist():
                            if info.filename == name or info.CRC == crc:
                                blob = zf.read(info)
                                break
                    if blob is not None:
                        break
                if blob is None:
                    print(f"FAIL index {idx}: {name} not found in {zips}")
                    ok = False
                    continue
                got = zlib.crc32(blob) & 0xFFFFFFFF
                status = "ok" if got == crc else f"CRC MISMATCH {got:08x}"
                ok &= got == crc
                print(f"  index {idx} +0x{len(data):07x} {name:22s} {len(blob):9d} {crc:08x} {status}")
                data += blob
            elif part.get("repeat"):
                n = int(part.get("repeat"), 0)
                data += bytes.fromhex((part.text or "00").strip()) * n
            else:
                data += bytes.fromhex(" ".join((part.text or "").split()))
        print(f"index {idx}: {len(data)} bytes (0x{len(data):x})")
        if a.out:
            out = pathlib.Path(a.out)
            out.mkdir(parents=True, exist_ok=True)
            (out / f"index{idx}.bin").write_bytes(data)
    print("MRA:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
