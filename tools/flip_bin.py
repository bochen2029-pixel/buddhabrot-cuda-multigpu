"""Rotate a .bin histogram in-place at the math level.

The renderer writes .bin files in raw kernel coordinates (Y axis NOT flipped),
while .png output is Y-flipped by the tonemap kernel for natural Buddhabrot
display orientation. This asymmetry means tools reading .bin directly see an
"upside-down" image unless they apply a display-time flip.

This tool resolves the asymmetry by producing a new .bin file where the
histogram is rotated 180° (or Y-flipped, or X-flipped) at write time. After
running this, all downstream tools (build_viewer_package.py, quality_report,
proper_thumb, etc.) can read the corrected .bin WITHOUT any runtime flip
hack — the math is correct in the file itself.

Memory: uses memmap, so works on .bin files of any size (32K = 19 GB,
64K = 77 GB) without loading the full histogram into RAM. Wallclock:
~40 sec for 32K, ~3 min for 64K on NVMe.

Usage:
    python flip_bin.py <src.bin> <dst.bin> [mode]

Modes:
    180  Rotate 180° (default; equivalent to build_viewer_package.py --flip)
    y    Y-flip only (rows reversed)
    x    X-flip only (columns reversed)

Header is preserved bit-exact (samples_done, view params, iter caps, etc.).
Only the histogram body is reordered.
"""
import sys
import struct
import time
from pathlib import Path

import numpy as np

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)

src_path = sys.argv[1]
dst_path = sys.argv[2]
mode = sys.argv[3] if len(sys.argv) > 3 else "180"

if mode not in ("180", "y", "x"):
    print(f"ERROR: unknown mode '{mode}'. Use 180, y, or x.", file=sys.stderr)
    sys.exit(1)

if Path(src_path).resolve() == Path(dst_path).resolve():
    print("ERROR: src and dst must be different files (this tool doesn't do in-place flip).", file=sys.stderr)
    sys.exit(1)

# Read header (preserve as-is)
with open(src_path, "rb") as f:
    header = f.read(128)
magic = header[0:4].decode("ascii", errors="replace")
if magic != "BHRA":
    raise RuntimeError(f"bad magic in src: {magic!r}")

width = struct.unpack_from("<I", header, 8)[0]
height = struct.unpack_from("<I", header, 12)[0]
samples_done = struct.unpack_from("<Q", header, 32)[0]

print(f"Source: {src_path}")
print(f"  {width} × {height}, samples_done={samples_done:,}")
print(f"  mode: {mode}")
print(f"Destination: {dst_path}")

# Memmap source
src = np.memmap(src_path, dtype=np.uint64, mode="r",
                offset=128, shape=(height, width, 3))

# Pre-allocate destination file (header + body), then memmap for writing
body_bytes = height * width * 3 * 8
total_bytes = 128 + body_bytes
print(f"  destination size: {total_bytes / 1e9:.2f} GB")

with open(dst_path, "wb") as f:
    f.write(header)
    # Sparse-extend the file to full size (cheap on modern filesystems)
    f.seek(total_bytes - 1)
    f.write(b'\x00')

dst = np.memmap(dst_path, dtype=np.uint64, mode="r+",
                offset=128, shape=(height, width, 3))

# Stream the flip row-by-row to keep peak memory bounded.
# 32K: each row = 32768 × 3 × 8 = 768 KB
# 64K: each row = 65536 × 3 × 8 = 1.5 MB
print(f"\nFlipping (mode={mode})...")
t0 = time.time()

if mode == "180":
    # Rotate 180°: dst[y, x] = src[height-1-y, width-1-x]
    # Implement as: for each dst row y, copy src row (height-1-y) reversed in X
    for y in range(height):
        src_y = height - 1 - y
        # [::-1] on axis 1 reverses X within the row; copy to dst
        dst[y] = src[src_y, ::-1, :]
        if y % 1024 == 0 and y > 0:
            elapsed = time.time() - t0
            rate = y / elapsed
            eta = (height - y) / rate
            print(f"  row {y}/{height}  ({y*100/height:.1f}%)  rate {rate:.0f} rows/s  ETA {eta:.0f}s",
                  flush=True)

elif mode == "y":
    # Y-flip only
    for y in range(height):
        dst[y] = src[height - 1 - y]
        if y % 1024 == 0 and y > 0:
            elapsed = time.time() - t0
            rate = y / elapsed
            print(f"  row {y}/{height}  rate {rate:.0f} rows/s", flush=True)

elif mode == "x":
    # X-flip only — preserves Y order
    for y in range(height):
        dst[y] = src[y, ::-1, :]
        if y % 1024 == 0 and y > 0:
            elapsed = time.time() - t0
            rate = y / elapsed
            print(f"  row {y}/{height}  rate {rate:.0f} rows/s", flush=True)

dst.flush()
print(f"  done in {time.time()-t0:.1f}s")

# Verify by reading first and last cells from each file
print(f"\nVerification:")
print(f"  src[0,0,*]                  = {tuple(int(v) for v in src[0, 0])}")
print(f"  dst[height-1,width-1,*]     = {tuple(int(v) for v in dst[height-1, width-1])}")
if mode == "180":
    match = all(src[0, 0, c] == dst[height-1, width-1, c] for c in range(3))
    print(f"  (180° flip expects these to match: {match})")

print(f"\nWrote: {dst_path}")
print(f"\nNext step: build viewer from the flipped .bin WITHOUT --flip:")
print(f"  python build_viewer_package.py {dst_path} viewer_<name> <trim_r> <trim_g> <trim_b>")
