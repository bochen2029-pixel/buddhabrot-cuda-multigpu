"""Write a 16-bit linear PNG from a .bin histogram. NO gamma applied.
Each channel is `count / R_max × 65535`, clamped. Preserves shadow detail
much better than the 8-bit display PNG. Open in Photoshop / Affinity /
darktable / GIMP-2.10+ for HDR-style editing.

Usage:
  python tools/linear_16bit.py <bin> <out_png_16> [downsample] [crop_x0 y0 x1 y1]
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
downsample = int(sys.argv[3]) if len(sys.argv) > 3 else 4
crop = None
if len(sys.argv) >= 8:
    crop = (int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))

with open(bin_path, "rb") as f:
    header = f.read(128)
width = struct.unpack_from("<I", header, 8)[0]
height = struct.unpack_from("<I", header, 12)[0]
hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                 offset=128, shape=(height, width, 3))
print(f"input: {width}x{height}, downsample={downsample}, crop={crop}")

# Channel max scan
print("scanning for channel max...")
t0 = time.time()
chunk_rows = 512
ch_max = np.zeros(3, dtype=np.uint64)
for ys in range(0, height, chunk_rows):
    yp = min(ys + chunk_rows, height)
    ch_max = np.maximum(ch_max, hist[ys:yp].reshape(-1, 3).max(axis=0))
r_max, g_max, b_max = (int(x) for x in ch_max)
print(f"  R={r_max:,} G={g_max:,} B={b_max:,}  ({time.time()-t0:.1f}s)")

# Determine crop bounds
if crop:
    x0, y0, x1, y1 = crop
else:
    x0, y0, x1, y1 = 0, 0, width, height
x0 = (x0 // downsample) * downsample
y0 = (y0 // downsample) * downsample
x1 = (x1 // downsample) * downsample
y1 = (y1 // downsample) * downsample
out_w = (x1 - x0) // downsample
out_h = (y1 - y0) // downsample
print(f"output: {out_w}x{out_h}")

# Linear scale: count / R_max -> 0..65535. NO gamma. Preserves shadow detail.
def linear_chunk(arr_chunk, mx):
    if mx <= 0:
        return np.zeros(arr_chunk.shape, dtype=np.uint16)
    s = arr_chunk.astype(np.float64) * (65535.0 / float(mx))
    return np.clip(s, 0, 65535).astype(np.uint16)

print("converting + downsampling...")
t1 = time.time()
out16 = np.zeros((out_h, out_w, 3), dtype=np.uint16)
strip_rows = (chunk_rows // downsample) * downsample
for ys in range(y0, y1, strip_rows):
    yp = min(ys + strip_rows, y1)
    block = hist[ys:yp, x0:x1, :]
    r16 = linear_chunk(block[:, :, 0], r_max)
    g16 = linear_chunk(block[:, :, 1], g_max)
    b16 = linear_chunk(block[:, :, 2], b_max)
    full = np.stack([r16, g16, b16], axis=-1).astype(np.uint32)  # accumulate u32 for averaging
    rows_in_strip = yp - ys
    blocks_in_strip = rows_in_strip // downsample
    if blocks_in_strip == 0:
        continue
    reduced = full.reshape(
        blocks_in_strip, downsample,
        out_w, downsample,
        3,
    ).mean(axis=(1, 3)).astype(np.uint16)
    row0 = (ys - y0) // downsample
    out16[row0 : row0 + blocks_in_strip] = reduced
print(f"  done in {time.time()-t1:.1f}s")

# PIL's Image.fromarray with mode="RGB" doesn't handle uint16. Use cv2 (BGR) for
# .png or tifffile for .tif. Both produce true 16-bit-per-channel files.
if out_path.lower().endswith((".tif", ".tiff")):
    import tifffile
    tifffile.imwrite(out_path, out16, photometric="rgb")
else:
    import cv2
    # cv2 expects BGR
    bgr16 = out16[:, :, ::-1]
    cv2.imwrite(out_path, bgr16)
print(f"wrote {out_path}  ({out_w}x{out_h}, 16-bit linear, no gamma)")
