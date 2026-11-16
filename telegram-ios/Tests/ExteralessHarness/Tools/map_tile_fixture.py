#!/usr/bin/env python3
"""Generate the small owned OSM tile INPUT, never an expected map/UI rendering."""

import argparse
import binascii
from pathlib import Path
import struct
import zlib


def tile_png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data) & 0xffffffff)

    rows = bytearray()
    for y in range(256):
        rows.append(0)  # PNG filter: none.
        for x in range(256):
            # Two axes and a 32px grid are visible inputs for the real tile renderer.
            colour = ((42, 83, 105) if x in (127, 128) or y in (127, 128) else
                      (106, 148, 160) if x % 32 == 0 or y % 32 == 0 else
                      (202, 227, 229) if (x // 32 + y // 32) % 2 == 0 else (232, 240, 224))
            rows.extend(colour)
    header = struct.pack('>IIBBBBB', 256, 256, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b'')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    data = tile_png()
    if args.check:
        if args.output.read_bytes() != data:
            raise SystemExit('Owned 256px tile input differs from its generator')
    else:
        with args.output.open('xb') as stream:
            stream.write(data)


if __name__ == '__main__':
    main()
