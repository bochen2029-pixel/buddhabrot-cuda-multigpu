"""Quick thumbnail generator from a .bin histogram dump.

Tonemaps with given trims, downsamples by N×N block-average, saves JPG.
Avoids loading the full image; uses numpy memmap + chunked block reduction.

Usage:
    python tools/quick_thumb.py <bin_path> <out_jpg> [trim_r] [trim_g] [trim_b] [downsample]
"""
import sys
import struct
import numpy as np
from PIL import Image

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(1)

bin_path = sys.argv[1]
out_path = sys.argv[2]
trim_r = float(sys.argv[3]) if len(sys.argv) > 3 else 0.75
trim_g = float(sys.argv[4]) if len(sys.argv) > 4 else 0.52
trim_b = float(sys.argv[5]) if len(sys.argv) > 5 else 0.29
downsample = int(sys.argv[6]) if len(sys.argv) > 6 else 8  # 16K -> 2K

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

# memmap histogram body (skip 128-byte header), shape (H, W, 3) uint64
hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                 offset=128, shape=(height, width, 3))

# Block-average to downsampled resolution.
H2 = height // downsample
W2 = width // downsample
print(f"downsampled: {W2}x{H2}")

# Process row-blocks to avoid full memory pressure.
out = np.zeros((H2, W2, 3), dtype=np.float64)
chunk = max(1, 256 // downsample) * downsample  # process 256 source rows at a time
for y0 in range(0, H2 * downsample, chunk):
    y1 = min(y0 + chunk, H2 * downsample)
    block = hist[y0:y1, :W2*downsample, :].astype(np.float64)
    block = block.reshape(
        (y1 - y0) // downsample, downsample,
        W2, downsample,
        3,
    ).mean(axis=(1, 3))
    out[y0 // downsample : y1 // downsample] = block
    print(f"  rows {y0}-{y1} reduced", flush=True)

# Per-channel max for tonemap.
r_max = out[:, :, 0].max()
g_max = out[:, :, 1].max()
b_max = out[:, :, 2].max()
print(f"channel maxes (downsampled): R={r_max:.0f} G={g_max:.0f} B={b_max:.0f}")

# Tonemap: t = count / (max * trim), clamp [0,1], display = 255*(1 - (1-t)^4).
def tonemap_channel(arr, mx, trim):
    if mx <= 0 or trim <= 0:
        return np.zeros_like(arr, dtype=np.uint8)
    t = arr / (mx * trim)
    t = np.clip(t, 0.0, 1.0)
    d = 255.0 * (1.0 - (1.0 - t) ** 4)
    return np.clip(d, 0, 255).astype(np.uint8)

r = tonemap_channel(out[:, :, 0], r_max, trim_r)
g = tonemap_channel(out[:, :, 1], g_max, trim_g)
b = tonemap_channel(out[:, :, 2], b_max, trim_b)
img = np.stack([r, g, b], axis=-1)

# Quick percentile readout for sanity.
for ch_name, arr in zip("RGB", (r, g, b)):
    p50 = np.percentile(arr, 50)
    p99 = np.percentile(arr, 99)
    p99_99 = np.percentile(arr, 99.99)
    print(f"  {ch_name} p50={p50:.0f} p99={p99:.0f} p99.99={p99_99:.0f}")

Image.fromarray(img).save(out_path, quality=92)
print(f"wrote {out_path}")
