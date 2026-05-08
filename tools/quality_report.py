"""Quality metrics report for a .bin histogram. Prints per-channel maxes,
percentile distribution, density-vs-reference comparison, and the trim
values that would match the reference.

Usage:
  python tools/quality_report.py <bin> [--reference-stats <json>] [--label <name>]
"""
import sys
import struct
import json
import time
import numpy as np

# Reference stats from 16K_blue.png uniform reference (computed previously)
REF_PCT = {
    "R": {"p50": 29, "p99": 200, "p99.99": 248, "p99.999": 254},
    "G": {"p50": 41, "p99": 180, "p99.99": 245, "p99.999": 254},
    "B": {"p50": 65, "p99": 165, "p99.99": 240, "p99.999": 253},
}
REF_DENSITY = 5120  # traj/pixel at 16K_blue uniform reference

if len(sys.argv) < 2:
    print(__doc__); sys.exit(1)
bin_path = sys.argv[1]
label = bin_path.split("/")[-1].replace(".bin", "")
for i, a in enumerate(sys.argv):
    if a == "--label" and i + 1 < len(sys.argv):
        label = sys.argv[i + 1]

with open(bin_path, "rb") as f:
    header = f.read(128)
magic = header[0:4].decode("ascii", errors="replace")
if magic != "BHRA":
    raise RuntimeError(f"bad magic: {magic!r}")
width = struct.unpack_from("<I", header, 8)[0]
height = struct.unpack_from("<I", header, 12)[0]
samples_done = struct.unpack_from("<Q", header, 32)[0]

print("=" * 70)
print(f"Quality report: {label}")
print("=" * 70)
print(f"Resolution      : {width} x {height}  ({width*height:,} pixels)")
print(f"Samples done    : {samples_done:,}")
density = samples_done / (width * height)
print(f"Density         : {density:.1f} traj/pixel  ({density/REF_DENSITY*100:.1f}% of ref {REF_DENSITY})")
print(f"Body effective  : {density*1.5:.0f} traj/pixel  ({density*1.5/REF_DENSITY*100:.1f}% of ref body)")
print(f"Filament effect.: {density*50:.0f} traj/pixel  ({density*50/REF_DENSITY:.1f}x ref filament)")

# Scan for full-resolution channel max
hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                 offset=128, shape=(height, width, 3))
print()
print("Scanning histogram for channel max...")
t0 = time.time()
chunk_rows = 512
ch_max = np.zeros(3, dtype=np.uint64)
for ys in range(0, height, chunk_rows):
    yp = min(ys + chunk_rows, height)
    ch_max = np.maximum(ch_max, hist[ys:yp].reshape(-1, 3).max(axis=0))
r_max, g_max, b_max = (int(x) for x in ch_max)
print(f"  R_max = {r_max:,}")
print(f"  G_max = {g_max:,}")
print(f"  B_max = {b_max:,}")
print(f"  scan took {time.time()-t0:.1f}s")
if r_max == g_max == b_max:
    print("  R=G=B exactly (documented IS body-cusp behavior at this regime)")

# Sample 1M random pixels for full-res percentile readout
print()
print("Sampling 1M random pixels for percentile distribution...")
n_sample = 1_000_000
rng = np.random.default_rng(42)
ys = rng.integers(0, height, n_sample)
xs = rng.integers(0, width, n_sample)
sample = hist[ys, xs, :].astype(np.float64)
print(f"  raw count percentiles per channel:")
for ci, name in enumerate("RGB"):
    s = sample[:, ci]
    p50 = np.percentile(s, 50)
    p99 = np.percentile(s, 99)
    p99_99 = np.percentile(s, 99.99)
    print(f"    {name}  p50={p50:,.0f}  p99={p99:,.0f}  p99.99={p99_99:,.0f}")

# Compute trim values that would match reference per-channel p50
print()
print("Density-correct trims for THIS .bin to match reference p50:")
for ci, name, mx in zip(range(3), "RGB", (r_max, g_max, b_max)):
    p50 = np.percentile(sample[:, ci], 50)
    if p50 <= 0 or mx <= 0:
        print(f"  trim_{name.lower()} = (no signal yet)")
        continue
    # ratio = count_p50 / R_max
    ratio = p50 / mx
    # t_target from inverse gamma
    target_disp = REF_PCT[name]["p50"]
    t_target = 1.0 - (1.0 - target_disp / 255.0) ** 0.25
    trim = ratio / t_target
    print(f"  trim_{name.lower()} = {trim:.3f}  (ratio={ratio:.5f}, t_target={t_target:.4f})")

# Display percentiles at the predicted-correct trims
print()
print("Display percentiles at density-correct trims:")
def tonemap(arr, mx, trim):
    if mx <= 0 or trim <= 0:
        return np.zeros_like(arr, dtype=np.uint8)
    t = arr.astype(np.float64) / (float(mx) * float(trim))
    t = np.clip(t, 0.0, 1.0)
    d = 255.0 * (1.0 - (1.0 - t) ** 4)
    return np.clip(d, 0, 255).astype(np.uint8)

for ci, name, mx in zip(range(3), "RGB", (r_max, g_max, b_max)):
    p50_raw = np.percentile(sample[:, ci], 50)
    if p50_raw <= 0 or mx <= 0:
        continue
    ratio = p50_raw / mx
    target_disp = REF_PCT[name]["p50"]
    t_target = 1.0 - (1.0 - target_disp / 255.0) ** 0.25
    trim = ratio / t_target
    disp = tonemap(sample[:, ci], mx, trim)
    p50d = np.percentile(disp, 50)
    p99d = np.percentile(disp, 99)
    p99_99d = np.percentile(disp, 99.99)
    ref = REF_PCT[name]
    print(f"  {name}  p50={p50d:.0f} (ref {ref['p50']})  p99={p99d:.0f} (ref {ref['p99']})  p99.99={p99_99d:.0f} (ref {ref['p99.99']})")

print()
print("Comparison vs your local 4070 Ti SUPER 80-min run (33.5 B at 16K):")
LOCAL_DENSITY = 33_500_000_000 / (16384 * 12288)
print(f"  Local density          : {LOCAL_DENSITY:.0f} traj/pixel")
print(f"  This .bin density      : {density:.0f} traj/pixel")
print(f"  Improvement factor     : {density/LOCAL_DENSITY:.2f}x more samples per pixel")
print(f"  Body SNR improvement   : {(density/LOCAL_DENSITY)**0.5:.2f}x cleaner (sqrt-N rule)")
