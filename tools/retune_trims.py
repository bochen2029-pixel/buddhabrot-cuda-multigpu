"""Iterative trim retune from a §B7 .bin file. Re-tonemaps the histogram with
candidate trim values until percentile match against a reference is achieved.

The histogram in .bin is the expensive artifact (hours of compute at 16K). The
tonemap is presentation — re-running it with different trims is cheap (~30 sec
per pass at 16K). This tool exploits that asymmetry: instead of re-rendering
every time the user wants a different tone, iterate at the tonemap layer.

Usage:
    python tools/retune_trims.py \
        --bin buddhabrot_16k_IS.bin \
        --reference-stats reference_calibration.json \
        --output buddhabrot_16k_IS_retuned.png \
        [--max-iter 15] [--initial-trims 0.74,0.74,0.52]

Search: coordinate descent on the three trim values with adaptive step sizes,
optimizing for L2 distance across (p50, p99, p99.99) per channel against the
reference. Quick to converge for tone-shape-similar histograms; will not
converge to pixel-exact match if histogram shape differs from reference (in
which case the trim retune is approximate by construction — see CLAUDE.md).

Requires the .bin file produced by `--output-raw` (§B7). Files predating §B7
(no .bin) cannot use this tool — see PNG-level post-process via postprocess.py.
"""
import argparse
import json
import struct
import sys
import time
from pathlib import Path

import numpy as np


# Match main.cu HistHeader layout
HEADER_FIELDS = [
    ("magic",          0,   "4s"),
    ("version",        4,   "<I"),
    ("width",          8,   "<I"),
    ("height",         12,  "<I"),
    ("reserved0",      16,  "<I"),
    ("reserved_pad0",  20,  "<I"),
    ("hist_count",     24,  "<Q"),
    ("samples_done",   32,  "<Q"),
]


def load_bin(path: Path):
    """Load .bin file: parse header, return (header_dict, hist_array, hist_max_array)."""
    print(f"loading {path}...", flush=True)
    t = time.time()
    with open(path, "rb") as f:
        header_bytes = f.read(128)
    header = {}
    for name, off, fmt in HEADER_FIELDS:
        size = struct.calcsize(fmt)
        v = struct.unpack(fmt, header_bytes[off:off + size])[0]
        if isinstance(v, bytes):
            v = v.rstrip(b"\x00").decode("ascii", errors="replace")
        header[name] = v
    if header["magic"] != "BHRA" or header["version"] != 1:
        raise ValueError(f"invalid .bin header: magic={header['magic']!r} version={header['version']}")
    width = header["width"]
    height = header["height"]
    pixels = width * height
    expected_count = pixels * 3 + 3
    if header["hist_count"] != expected_count:
        raise ValueError(f"hist_count mismatch: header={header['hist_count']}, expected={expected_count}")

    # Memory-map the body (4.83 GB at 16K — too much to read into Python list-of-bytes)
    hist_bytes_count = expected_count * 8
    hist = np.memmap(path, dtype=np.uint64, mode="r", offset=128, shape=(expected_count,))
    pixel_data = hist[:pixels * 3].reshape(height, width, 3)
    max_data = hist[pixels * 3:pixels * 3 + 3]
    print(f"  shape: {pixel_data.shape}, max=[{max_data[0]}, {max_data[1]}, {max_data[2]}]")
    print(f"  loaded in {time.time() - t:.1f}s")
    return header, pixel_data, max_data


def tonemap(pixel_data, max_data, trim_r, trim_g, trim_b, gamma=4.0, normalization_floor=15.0):
    """Replicate main.cu's tonemap_kernel in numpy. Returns (height, width, 3) uint16."""
    t = time.time()
    height, width, _ = pixel_data.shape
    counts = pixel_data.astype(np.float64)  # (H, W, 3) — float64 for precision

    # Per-channel effective max = max * trim, with floor
    trims = np.array([trim_r, trim_g, trim_b], dtype=np.float64)
    effective_max = np.maximum(max_data.astype(np.float64) * trims, normalization_floor)

    # Normalize: count / effective_max, clip to [0, 1]
    t_values = np.clip(counts / effective_max[None, None, :], 0.0, 1.0)

    # Apply gamma curve: 1 - (1 - t)^gamma
    pixels_normalized = 1.0 - np.power(1.0 - t_values, gamma)

    # Quantize to 16-bit
    pixels_u16 = np.clip(np.round(pixels_normalized * 65535.0), 0, 65535).astype(np.uint16)

    # Flip Y axis (main.cu does this in tonemap_kernel)
    pixels_u16 = pixels_u16[::-1, :, :]

    print(f"  tonemap: {time.time() - t:.1f}s with trims=({trim_r:.4f}, {trim_g:.4f}, {trim_b:.4f})")
    return pixels_u16


def compute_percentiles(pixels_u16):
    """Match analyze_reference.py's percentile metric: 8-bit equivalent percentile values
    so we can compare against existing reference_calibration.json data."""
    pixels_u8 = (pixels_u16 >> 8).astype(np.uint8)
    out = {}
    for i, ch in enumerate("RGB"):
        chan = pixels_u8[..., i]
        out[ch] = {
            "p50":     float(np.percentile(chan, 50)),
            "p99":     float(np.percentile(chan, 99)),
            "p99.99":  float(np.percentile(chan, 99.99)),
            "p99.999": float(np.percentile(chan, 99.999)),
        }
    return out


def percentile_distance(actual, target):
    """L2 distance across (p50, p99, p99.99) per channel. Lower is better."""
    keys = ["p50", "p99", "p99.99"]
    dist = 0.0
    for ch in "RGB":
        for k in keys:
            d = actual[ch][k] - target[ch][k]
            dist += d * d
    return dist ** 0.5


def coordinate_descent(pixel_data, max_data, target_percentiles, initial_trims, max_iter=15, tol=1.5):
    """Coordinate-descent optimization on (trim_r, trim_g, trim_b)."""
    trims = list(initial_trims)
    best_dist = float("inf")
    best_pixels = None
    history = []

    for iteration in range(max_iter):
        pixels = tonemap(pixel_data, max_data, *trims)
        actual = compute_percentiles(pixels)
        dist = percentile_distance(actual, target_percentiles)
        history.append((tuple(trims), dist))

        print(f"  iter {iteration}: trims=({trims[0]:.4f},{trims[1]:.4f},{trims[2]:.4f}) dist={dist:.2f}")
        print(f"    R p50/p99/p99.99 = {actual['R']['p50']:.1f}/{actual['R']['p99']:.1f}/{actual['R']['p99.99']:.1f} target={target_percentiles['R']['p50']:.1f}/{target_percentiles['R']['p99']:.1f}/{target_percentiles['R']['p99.99']:.1f}")

        if dist < best_dist:
            best_dist = dist
            best_pixels = pixels.copy()

        if dist < tol:
            print(f"  converged: distance {dist:.2f} < tolerance {tol}")
            break

        # For each channel, compute a multiplicative correction based on p50 ratio.
        # If actual p50 > target p50 by ratio R, we want to increase trim by ~R
        # (larger trim → larger divisor → smaller normalized → lower display).
        new_trims = list(trims)
        for i, ch in enumerate("RGB"):
            actual_p50 = max(actual[ch]["p50"], 0.5)  # avoid div by zero
            target_p50 = max(target_percentiles[ch]["p50"], 0.5)
            # Convert display p50 → normalized t: t = 1 - (1 - p50/255)^(1/gamma)
            # Then count = t × max × trim. New trim = count_actual / (t_target × max).
            # For matching p50: t_target/t_actual = trim_actual/trim_new → trim_new = trim_actual × t_actual/t_target.
            t_actual = 1.0 - (1.0 - actual_p50 / 255.0) ** (1.0 / 4.0)
            t_target = 1.0 - (1.0 - target_p50 / 255.0) ** (1.0 / 4.0)
            if t_target > 1e-9:
                ratio = t_actual / t_target
                # Damped step
                damp = 0.7 + 0.3 / (iteration + 1)
                new_trims[i] = trims[i] * (1.0 + damp * (ratio - 1.0))
                new_trims[i] = max(new_trims[i], 0.01)
                new_trims[i] = min(new_trims[i], 5.0)
        trims = new_trims

    return best_pixels, history


def save_png(pixels_u16, path: Path):
    """Save uint16 RGB as 16-bit PNG via PIL."""
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    h, w, _ = pixels_u16.shape
    # PIL's I;16 mode is grayscale; for 16-bit RGB we need to use mode 'RGB' but that's 8-bit.
    # Workaround: write as 16-bit RGB via raw mode.
    img = Image.frombuffer("RGB", (w, h), (pixels_u16 >> 8).astype(np.uint8).tobytes(), "raw", "RGB", 0, 1)
    img.save(path, optimize=False, compress_level=6)
    print(f"  saved {path.name} ({path.stat().st_size / 1e6:.1f} MB)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True, type=Path, help="Path to §B7 .bin file")
    ap.add_argument("--reference-stats", required=True, type=Path,
                    help="Path to reference_calibration.json (from analyze_reference.py)")
    ap.add_argument("--reference-key", default=None,
                    help="Key inside reference-stats (e.g., buddhabrot_16k_blue.png). If not given, uses first key.")
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--max-iter", type=int, default=15)
    ap.add_argument("--initial-trims", default="0.74,0.74,0.52")
    ap.add_argument("--tolerance", type=float, default=1.5)
    args = ap.parse_args()

    initial = tuple(float(x) for x in args.initial_trims.split(","))
    if len(initial) != 3:
        print("--initial-trims must be three comma-separated floats", file=sys.stderr)
        sys.exit(1)

    ref_data = json.loads(args.reference_stats.read_text())
    if args.reference_key is None:
        ref_key = next(iter(ref_data.keys()))
    else:
        ref_key = args.reference_key
    ref_percentiles = {ch: ref_data[ref_key]["channels"][ch]["percentiles"] for ch in "RGB"}

    print(f"Reference: {ref_key}")
    print(f"  R p50={ref_percentiles['R']['p50']:.1f} p99={ref_percentiles['R']['p99']:.1f} p99.99={ref_percentiles['R']['p99.99']:.1f}")
    print(f"  G p50={ref_percentiles['G']['p50']:.1f} p99={ref_percentiles['G']['p99']:.1f} p99.99={ref_percentiles['G']['p99.99']:.1f}")
    print(f"  B p50={ref_percentiles['B']['p50']:.1f} p99={ref_percentiles['B']['p99']:.1f} p99.99={ref_percentiles['B']['p99.99']:.1f}")
    print()

    header, pixel_data, max_data = load_bin(args.bin)
    print(f"Histogram: {header['width']}x{header['height']}, samples_done={header['samples_done']:,}")
    print()

    print(f"Coordinate-descent search (max {args.max_iter} iter, tol {args.tolerance}):")
    best_pixels, history = coordinate_descent(
        pixel_data, max_data, ref_percentiles, initial,
        max_iter=args.max_iter, tol=args.tolerance,
    )

    print()
    print("History:")
    for trims, dist in history:
        print(f"  trims={trims}, dist={dist:.2f}")

    final_trims, final_dist = min(history, key=lambda x: x[1])
    print()
    print(f"Best trims: ({final_trims[0]:.4f}, {final_trims[1]:.4f}, {final_trims[2]:.4f})")
    print(f"Best distance: {final_dist:.2f}")

    save_png(best_pixels, args.output)


if __name__ == "__main__":
    main()
