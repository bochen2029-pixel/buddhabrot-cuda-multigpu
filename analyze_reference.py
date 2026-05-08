"""Scientific characterization of the user-accepted tone reference.

Loads the reference 16K render, computes per-channel + HSV statistics, and
saves a calibration_target.json that downstream checkpoint validators can
match against. Decompression-bomb guard is disabled because the inputs are
known-good user assets, not adversarial uploads.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None


def colorsys_rgb_to_hsv(rgb: np.ndarray) -> np.ndarray:
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    cmax = np.maximum(np.maximum(r, g), b)
    cmin = np.minimum(np.minimum(r, g), b)
    delta = cmax - cmin
    h = np.zeros_like(cmax, dtype=np.float64)
    nz = delta > 0
    rmax = (cmax == r) & nz
    gmax = (cmax == g) & nz
    bmax = (cmax == b) & nz
    h[rmax] = ((g[rmax] - b[rmax]) / delta[rmax]) % 6
    h[gmax] = (b[gmax] - r[gmax]) / delta[gmax] + 2
    h[bmax] = (r[bmax] - g[bmax]) / delta[bmax] + 4
    h = h * 60
    s = np.zeros_like(cmax, dtype=np.float64)
    s[cmax > 0] = delta[cmax > 0] / cmax[cmax > 0]
    v = cmax
    return np.stack([h, s, v], axis=-1)


def channel_stats(arr: np.ndarray) -> dict:
    return {
        "min": int(arr.min()),
        "max": int(arr.max()),
        "mean": float(arr.mean()),
        "median": float(np.median(arr)),
        "std": float(arr.std()),
        "percentiles": {
            f"p{p}": float(np.percentile(arr, p))
            for p in [0.001, 0.01, 0.1, 1, 5, 10, 25, 50, 75, 90, 95, 99, 99.9, 99.99, 99.999]
        },
    }


def histogram_bins(arr: np.ndarray, bins: int = 256) -> list:
    h, _ = np.histogram(arr, bins=bins, range=(0, 256))
    return h.tolist()


def sample_corners(rgb: np.ndarray, win: int = 200) -> dict:
    h, w = rgb.shape[:2]
    corners = {
        "top_left":     rgb[:win, :win],
        "top_right":    rgb[:win, w - win:],
        "bottom_left":  rgb[h - win:, :win],
        "bottom_right": rgb[h - win:, w - win:],
    }
    return {
        name: {
            "mean_rgb": [float(c[..., i].mean()) for i in range(3)],
            "std_rgb":  [float(c[..., i].std())  for i in range(3)],
            "median_rgb": [float(np.median(c[..., i])) for i in range(3)],
        }
        for name, c in corners.items()
    }


def foreground_stats(rgb: np.ndarray, percentile: float = 99.0) -> dict:
    luminance = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
    threshold = np.percentile(luminance, percentile)
    mask = luminance >= threshold
    fg = rgb[mask]
    hsv = colorsys_rgb_to_hsv(fg.astype(np.float64) / 255.0)
    return {
        "luminance_threshold": float(threshold),
        "n_pixels": int(mask.sum()),
        "fraction_of_image": float(mask.mean()),
        "rgb_mean": [float(fg[..., i].mean()) for i in range(3)],
        "rgb_p50": [float(np.percentile(fg[..., i], 50)) for i in range(3)],
        "rgb_p99": [float(np.percentile(fg[..., i], 99)) for i in range(3)],
        "hsv_mean": [float(hsv[..., i].mean()) for i in range(3)],
        "hsv_p50":  [float(np.percentile(hsv[..., i], 50)) for i in range(3)],
        "hsv_p95":  [float(np.percentile(hsv[..., i], 95)) for i in range(3)],
    }


def background_stats(rgb: np.ndarray, percentile: float = 5.0) -> dict:
    luminance = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
    threshold = np.percentile(luminance, percentile)
    mask = luminance <= threshold
    bg = rgb[mask]
    return {
        "luminance_threshold": float(threshold),
        "n_pixels": int(mask.sum()),
        "rgb_mean": [float(bg[..., i].mean()) for i in range(3)],
        "rgb_median": [float(np.median(bg[..., i])) for i in range(3)],
        "rgb_std": [float(bg[..., i].std()) for i in range(3)],
    }


def saturation_check(rgb: np.ndarray) -> dict:
    return {
        "n_fully_white": int(((rgb == 255).all(axis=-1)).sum()),
        "n_any_channel_clipped_at_255": int((rgb == 255).any(axis=-1).sum()),
        "n_fully_black": int(((rgb == 0).all(axis=-1)).sum()),
        "fraction_clipped_at_255": float((rgb == 255).any(axis=-1).mean()),
        "fraction_per_channel_at_255": [float((rgb[..., i] == 255).mean()) for i in range(3)],
    }


def analyze(path: Path) -> dict:
    print(f"loading {path} ...", flush=True)
    with Image.open(path) as im:
        if im.mode != "RGB":
            im = im.convert("RGB")
        rgb = np.asarray(im, dtype=np.uint8)
    h, w, _ = rgb.shape
    print(f"  shape: {rgb.shape}, ~{rgb.nbytes / 1e9:.2f} GB", flush=True)

    out = {
        "file": str(path),
        "width": w,
        "height": h,
        "channels": {
            "R": channel_stats(rgb[..., 0]),
            "G": channel_stats(rgb[..., 1]),
            "B": channel_stats(rgb[..., 2]),
        },
        "histograms_256bin": {
            "R": histogram_bins(rgb[..., 0]),
            "G": histogram_bins(rgb[..., 1]),
            "B": histogram_bins(rgb[..., 2]),
        },
        "corners": sample_corners(rgb),
        "foreground_top1pct": foreground_stats(rgb, 99.0),
        "foreground_top0p1pct": foreground_stats(rgb, 99.9),
        "background_bot5pct": background_stats(rgb, 5.0),
        "saturation": saturation_check(rgb),
    }
    return out


def main():
    if len(sys.argv) < 3:
        print("usage: analyze_reference.py <input.png> <output.json> [more inputs...]")
        sys.exit(2)
    out_path = Path(sys.argv[2])
    inputs = [Path(p) for p in [sys.argv[1], *sys.argv[3:]]]
    results = {}
    for p in inputs:
        results[p.name] = analyze(p)
    out_path.write_text(json.dumps(results, indent=2))
    print(f"wrote {out_path} ({out_path.stat().st_size / 1e3:.1f} KB)", flush=True)


if __name__ == "__main__":
    main()
