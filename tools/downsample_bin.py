"""Downsample a high-res .bin histogram into a compact guide for bin-guided IMap construction.

The full-res 32K .bin (19 GB) is too large to keep in GPU memory during per-tile
IMap construction. This tool downsamples it to a small uint16 single-channel
guide file (e.g., 4K x 3K = 24 MB) that fits easily on any GPU.

Approach:
  1. Read the full-res .bin (uint64, RGB per pixel)
  2. Block-average by factor `--factor` (e.g., 8 → 32K becomes 4K)
  3. Take a single brightness value per output pixel (R channel by default;
     R has iter_cap=2000 so captures the most informative orbit distribution)
  4. Normalize to uint16 range [0, 65535]
  5. Write to disk as: 32-byte header + width*height*uint16

The guide file is then passed to the renderer via --guide-bin <path> during
--build-view-imap to weight IMap cell increments by image-space importance.
Result: per-tile IMaps converge faster and produce sharper renders at the
same time budget.

Guide file format (binary, little-endian):
  offset 0:   magic "GBIN"           4 bytes
  offset 4:   version (= 1)          uint32
  offset 8:   width                  uint32
  offset 12:  height                 uint32
  offset 16:  source_max_value       uint32  (R_max of source, before normalization)
  offset 20:  channel_mode           uint32  (0 = R only, 1 = R+G+B sum)
  offset 24:  reserved               8 bytes
  offset 32:  body                   width * height * uint16

Usage:
    python downsample_bin.py <src.bin> <dst.guide.bin> [--factor 8] [--channels R|RGB]

Examples:
    # 32K -> 4K guide (factor 8)
    python downsample_bin.py cp8320.bin guide_4k.gbin --factor 8

    # 32K -> 2K guide (factor 16)
    python downsample_bin.py cp8320.bin guide_2k.gbin --factor 16
"""
import argparse
import struct
import sys
import time
from pathlib import Path

import numpy as np


def read_bin_header(path):
    with open(path, "rb") as f:
        header = f.read(128)
    magic = header[0:4].decode("ascii", errors="replace")
    if magic != "BHRA":
        raise RuntimeError(f"bad source magic: {magic!r}")
    width = struct.unpack_from("<I", header, 8)[0]
    height = struct.unpack_from("<I", header, 12)[0]
    samples_done = struct.unpack_from("<Q", header, 32)[0]
    return width, height, samples_done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="source .bin file (output of buddhabrot renderer)")
    ap.add_argument("dst", help="destination guide file (typically .gbin extension)")
    ap.add_argument("--factor", type=int, default=8,
                    help="downsample factor (e.g., 8 = 32K -> 4K). Must divide src width AND height.")
    ap.add_argument("--channels", default="R", choices=["R", "RGB"],
                    help="R = use red channel only (captures longest orbits, default). "
                         "RGB = sum R+G+B (captures all orbits)")
    args = ap.parse_args()

    src_width, src_height, src_samples = read_bin_header(args.src)
    print(f"Source: {args.src}")
    print(f"  {src_width} x {src_height}, samples_done={src_samples:,}")

    if src_width % args.factor != 0 or src_height % args.factor != 0:
        print(f"ERROR: factor {args.factor} doesn't evenly divide {src_width}x{src_height}",
              file=sys.stderr)
        sys.exit(1)

    dst_width = src_width // args.factor
    dst_height = src_height // args.factor
    print(f"\nDownsample factor: {args.factor}")
    print(f"Destination: {args.dst}")
    print(f"  {dst_width} x {dst_height} ({dst_width * dst_height * 2 / 1e6:.1f} MB body)")
    print(f"  channels: {args.channels}")

    # Memmap source — only read what we need, in strips
    src = np.memmap(args.src, dtype=np.uint64, mode="r",
                    offset=128, shape=(src_height, src_width, 3))

    # Channel selection
    if args.channels == "R":
        channel_mode = 0
    else:
        channel_mode = 1

    print("\nFirst pass: find R_max for normalization...")
    t0 = time.time()
    src_max = 0
    chunk_rows = 512
    for ys in range(0, src_height, chunk_rows):
        yp = min(ys + chunk_rows, src_height)
        block = src[ys:yp]
        if args.channels == "R":
            chunk_max = int(block[:, :, 0].max())
        else:
            chunk_max = int(block.sum(axis=2).max())
        if chunk_max > src_max:
            src_max = chunk_max
    print(f"  source_max = {src_max:,} ({time.time()-t0:.1f}s)")
    if src_max == 0:
        print("ERROR: source max is 0 (empty histogram?)", file=sys.stderr)
        sys.exit(1)

    print("\nSecond pass: downsample + normalize to uint16...")
    t1 = time.time()
    out = np.zeros((dst_height, dst_width), dtype=np.uint16)

    # Process row-blocks aligned to factor
    chunk = (chunk_rows // args.factor) * args.factor
    if chunk == 0:
        chunk = args.factor
    for ys in range(0, src_height, chunk):
        yp = min(ys + chunk, src_height)
        block = src[ys:yp]
        rows_in_chunk = yp - ys
        out_rows = rows_in_chunk // args.factor
        if out_rows == 0:
            continue

        # Block-average: reshape (out_rows, factor, dst_width, factor, 3) and mean
        if args.channels == "R":
            data = block[:out_rows*args.factor, :, 0].astype(np.float64)
        else:
            data = block[:out_rows*args.factor, :, :].astype(np.float64).sum(axis=2)
        # Block-mean over factor x factor windows
        reduced = data.reshape(
            out_rows, args.factor,
            dst_width, args.factor,
        ).mean(axis=(1, 3))
        # Normalize to uint16
        normalized = np.clip(reduced * (65535.0 / src_max), 0, 65535).astype(np.uint16)
        dst_y0 = ys // args.factor
        out[dst_y0:dst_y0 + out_rows] = normalized

        if (ys // chunk) % 10 == 0:
            print(f"  rows {ys}/{src_height} ({ys*100/src_height:.0f}%)", flush=True)

    print(f"  pass 2 done in {time.time()-t1:.1f}s")

    # Write output
    print(f"\nWriting {args.dst}...")
    header = bytearray(32)
    header[0:4] = b"GBIN"
    struct.pack_into("<I", header, 4, 1)        # version
    struct.pack_into("<I", header, 8, dst_width)
    struct.pack_into("<I", header, 12, dst_height)
    struct.pack_into("<I", header, 16, src_max & 0xFFFFFFFF)  # may truncate if > 4G, fine for diagnostics
    struct.pack_into("<I", header, 20, channel_mode)
    # bytes 24..31 reserved (already zero)

    with open(args.dst, "wb") as f:
        f.write(bytes(header))
        f.write(out.tobytes())

    file_size = Path(args.dst).stat().st_size
    print(f"  wrote {file_size:,} bytes ({file_size / 1e6:.1f} MB)")
    print(f"  guide: {dst_width} x {dst_height}, uint16, source R_max = {src_max:,}")

    # Show some stats
    nonzero_pct = 100 * (out > 0).sum() / out.size
    print(f"\nGuide stats:")
    print(f"  nonzero pixels: {nonzero_pct:.1f}%")
    print(f"  p50: {np.median(out):.0f}")
    print(f"  p99: {np.percentile(out, 99):.0f}")
    print(f"  max: {out.max():,}")

    print(f"\nNext: use this guide during per-tile IMap construction:")
    print(f"  ./buddhabrot --build-view-imap tile_imap.bin --guide-bin {args.dst} \\")
    print(f"      --view-center-x ... --view-center-y ... --zoom ... \\")
    print(f"      --width ... --height ... --imap-samples 50000000")
    print(f"  (smaller --imap-samples is OK with a guide; the guide accelerates convergence)")


if __name__ == "__main__":
    main()
