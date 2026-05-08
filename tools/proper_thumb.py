"""Proper thumbnail from a .bin histogram, doing tonemap-at-full-resolution
then downsampling display values. Avoids the R_max distortion of
downsample-then-tonemap.

Two-pass:
  Pass 1: scan full histogram for per-channel max (chunked memmap)
  Pass 2: chunked tonemap → display values → average-block-reduce → JPG

Also samples ~1M random full-resolution pixels for percentile readout.

Usage:
  python tools/proper_thumb.py <bin> <out_jpg> [trim_r] [trim_g] [trim_b] [downsample]
"""
import sys
import struct
import time
import numpy as np
from PIL import Image

if len(sys.argv) < 3:
    print(__doc__); sys.exit(1)

bin_path = sys.argv[1]
out_path = sys.argv[2]
trim_r = float(sys.argv[3]) if len(sys.argv) > 3 else 0.49
trim_g = float(sys.argv[4]) if len(sys.argv) > 4 else 0.34
trim_b = float(sys.argv[5]) if len(sys.argv) > 5 else 0.19
downsample = int(sys.argv[6]) if len(sys.argv) > 6 else 8

with open(bin_path, "rb") as f:
    header = f.read(128)
magic = header[0:4].decode("ascii", errors="replace")
if magic != "BHRA":
    raise RuntimeError(f"bad magic: {magic!r}")
width = struct.unpack_from("<I", header, 8)[0]
height = struct.unpack_from("<I", header, 12)[0]
samples_done = struct.unpack_from("<Q", header, 32)[0]
print(f"width={width} height={height} samples_done={samples_done:,}")
print(f"trims: R={trim_r} G={trim_g} B={trim_b}  downsample={downsample}x")

hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                 offset=128, shape=(height, width, 3))

# -------- Pass 1: compute per-channel max (chunked) --------
t0 = time.time()
print("pass 1: scanning for channel max...")
chunk_rows = 512
ch_max = np.zeros(3, dtype=np.uint64)
for y0 in range(0, height, chunk_rows):
    y1 = min(y0 + chunk_rows, height)
    block = hist[y0:y1]
    ch_max = np.maximum(ch_max, block.reshape(-1, 3).max(axis=0))
    if y0 % (chunk_rows * 4) == 0:
        print(f"  rows {y0}/{height}", flush=True)

r_max, g_max, b_max = (int(x) for x in ch_max)
print(f"  full-res maxes: R={r_max:,} G={g_max:,} B={b_max:,}")
print(f"  pass 1 took {time.time()-t0:.1f}s")

# -------- Pass 2: tonemap then downsample --------
t1 = time.time()
print("pass 2: tonemap + downsample...")
H2 = height // downsample
W2 = width // downsample
out8 = np.zeros((H2, W2, 3), dtype=np.uint8)

# Tonemap formula: t = count / (max * trim), display = 255*(1 - (1-t)^4)
def tonemap_to_uint8(arr_chunk, mx, trim):
    if mx <= 0 or trim <= 0:
        return np.zeros(arr_chunk.shape, dtype=np.uint8)
    t = arr_chunk.astype(np.float32) / (float(mx) * float(trim))
    np.clip(t, 0.0, 1.0, out=t)
    one_minus = 1.0 - t
    one_minus *= one_minus
    one_minus *= one_minus  # ^4
    d = 255.0 * (1.0 - one_minus)
    return np.clip(d, 0, 255).astype(np.uint8)

# Process in row-strips that align to downsample blocks
strip_rows = (chunk_rows // downsample) * downsample
for y0 in range(0, H2 * downsample, strip_rows):
    y1 = min(y0 + strip_rows, H2 * downsample)
    block = hist[y0:y1, :W2*downsample, :]  # uint64 raw counts
    # Tonemap to uint8 at full resolution
    r8 = tonemap_to_uint8(block[:, :, 0], r_max, trim_r)
    g8 = tonemap_to_uint8(block[:, :, 1], g_max, trim_g)
    b8 = tonemap_to_uint8(block[:, :, 2], b_max, trim_b)
    full = np.stack([r8, g8, b8], axis=-1).astype(np.uint16)  # accumulate as u16
    # Downsample by averaging display values across blocks
    rows_in_strip = y1 - y0
    blocks_in_strip = rows_in_strip // downsample
    full_reduced = full.reshape(
        blocks_in_strip, downsample,
        W2, downsample,
        3,
    ).mean(axis=(1, 3))
    out8[y0 // downsample : y0 // downsample + blocks_in_strip] = full_reduced.astype(np.uint8)
    if y0 % (strip_rows * 4) == 0:
        print(f"  rows {y0}/{H2*downsample}", flush=True)
print(f"  pass 2 took {time.time()-t1:.1f}s")

# -------- Sample-based percentile readout (full resolution) --------
print("sampling full-res percentiles...")
n_sample = 1_000_000
rng = np.random.default_rng(42)
ys = rng.integers(0, height, n_sample)
xs = rng.integers(0, width, n_sample)
sample = hist[ys, xs, :].astype(np.float64)
disp_r = tonemap_to_uint8(sample[:, 0], r_max, trim_r)
disp_g = tonemap_to_uint8(sample[:, 1], g_max, trim_g)
disp_b = tonemap_to_uint8(sample[:, 2], b_max, trim_b)
for ch_name, arr in zip("RGB", (disp_r, disp_g, disp_b)):
    p50 = np.percentile(arr, 50)
    p99 = np.percentile(arr, 99)
    p99_99 = np.percentile(arr, 99.99)
    p99_999 = np.percentile(arr, 99.999)
    print(f"  {ch_name} p50={p50:.0f} p99={p99:.0f} p99.99={p99_99:.0f} p99.999={p99_999:.0f}")

Image.fromarray(out8).save(out_path, quality=92)
print(f"wrote {out_path}  ({W2}x{H2})")
