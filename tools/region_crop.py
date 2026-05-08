"""Crop a region from a .bin histogram, tonemap at full resolution,
then downsample. Output stays under the chat dimension limit (2000px).

Usage:
  python tools/region_crop.py <bin> <out_jpg> <x0> <y0> <x1> <y1> <downsample> \
                              [trim_r trim_g trim_b]
"""
import sys
import struct
import time
import numpy as np
from PIL import Image

if len(sys.argv) < 8:
    print(__doc__); sys.exit(1)

bin_path = sys.argv[1]
out_path = sys.argv[2]
x0, y0, x1, y1 = (int(s) for s in sys.argv[3:7])
downsample = int(sys.argv[7])
trim_r = float(sys.argv[8]) if len(sys.argv) > 8 else 0.27
trim_g = float(sys.argv[9]) if len(sys.argv) > 9 else 0.19
trim_b = float(sys.argv[10]) if len(sys.argv) > 10 else 0.11

with open(bin_path, "rb") as f:
    header = f.read(128)
width = struct.unpack_from("<I", header, 8)[0]
height = struct.unpack_from("<I", header, 12)[0]

# Round crop bounds to multiples of downsample
x0 = (x0 // downsample) * downsample
y0 = (y0 // downsample) * downsample
x1 = (x1 // downsample) * downsample
y1 = (y1 // downsample) * downsample
crop_w = x1 - x0
crop_h = y1 - y0
out_w = crop_w // downsample
out_h = crop_h // downsample
print(f"crop: ({x0},{y0}) -> ({x1},{y1})  size {crop_w}x{crop_h} -> {out_w}x{out_h}")
print(f"trims: R={trim_r} G={trim_g} B={trim_b}")

if max(out_w, out_h) > 2000:
    print(f"WARN: output {out_w}x{out_h} exceeds 2000px limit; chat upload will fail")

hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                 offset=128, shape=(height, width, 3))

# Channel max from full image (so tone is consistent with full-image thumbnails)
print("scanning for channel max (full-image)...")
t0 = time.time()
chunk_rows = 512
ch_max = np.zeros(3, dtype=np.uint64)
for ys in range(0, height, chunk_rows):
    yp = min(ys + chunk_rows, height)
    ch_max = np.maximum(ch_max, hist[ys:yp].reshape(-1, 3).max(axis=0))
r_max, g_max, b_max = (int(x) for x in ch_max)
print(f"  R={r_max:,} G={g_max:,} B={b_max:,}  ({time.time()-t0:.1f}s)")

def tonemap_to_uint8(arr_chunk, mx, trim):
    if mx <= 0 or trim <= 0:
        return np.zeros(arr_chunk.shape, dtype=np.uint8)
    t = arr_chunk.astype(np.float32) / (float(mx) * float(trim))
    np.clip(t, 0.0, 1.0, out=t)
    one_minus = 1.0 - t
    one_minus *= one_minus
    one_minus *= one_minus
    d = 255.0 * (1.0 - one_minus)
    return np.clip(d, 0, 255).astype(np.uint8)

# Tonemap the crop region at full resolution
print("tonemap + downsample crop...")
t1 = time.time()
crop = hist[y0:y1, x0:x1, :]
r8 = tonemap_to_uint8(crop[:, :, 0], r_max, trim_r)
g8 = tonemap_to_uint8(crop[:, :, 1], g_max, trim_g)
b8 = tonemap_to_uint8(crop[:, :, 2], b_max, trim_b)
full = np.stack([r8, g8, b8], axis=-1).astype(np.uint16)
reduced = full.reshape(
    out_h, downsample,
    out_w, downsample,
    3,
).mean(axis=(1, 3)).astype(np.uint8)
Image.fromarray(reduced).save(out_path, quality=92)
print(f"  done in {time.time()-t1:.1f}s")
print(f"wrote {out_path}  ({out_w}x{out_h})")
