"""Buddhabrot post-process: NLM denoising + CLAHE contrast boost.

Designed to address the residual filament-region noise and core-dominance in
the existing tonemapped PNG output. Runs on CPU (OpenCV optimized C++).

Usage:
    python postprocess.py INPUT.png OUTPUT.png [--nlm-h FLOAT] [--clahe-clip FLOAT]
                          [--clahe-tile INT] [--no-nlm] [--no-clahe]
"""
import argparse
import sys
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None


def load_png_8bit(path: Path) -> np.ndarray:
    """Load PNG via PIL (handles 16-bit by downconverting to 8-bit). Returns BGR uint8."""
    t = time.time()
    with Image.open(path) as im:
        if im.mode == "I;16" or im.mode == "I":
            im = im.point(lambda v: v >> 8).convert("RGB")
        elif im.mode != "RGB":
            im = im.convert("RGB")
        rgb = np.asarray(im, dtype=np.uint8)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    print(f"  loaded {path.name} in {time.time()-t:.1f}s  shape={rgb.shape} dtype={rgb.dtype}", flush=True)
    return bgr


def nlm_denoise(bgr: np.ndarray, h: float = 4.0, h_color: float = 6.0) -> np.ndarray:
    """OpenCV fastNlMeansDenoisingColored. h tunes luma denoise strength.
    h_color tunes chroma denoise. Higher = more smoothing. Defaults are conservative
    for buddhabrot's mostly-low-noise regime."""
    t = time.time()
    out = cv2.fastNlMeansDenoisingColored(
        bgr,
        None,
        h=h,
        hColor=h_color,
        templateWindowSize=7,
        searchWindowSize=21,
    )
    print(f"  NLM denoised in {time.time()-t:.1f}s  (h={h}, hColor={h_color})", flush=True)
    return out


def nlm_denoise_tiled(bgr: np.ndarray, tile: int = 4096, overlap: int = 64,
                      h: float = 4.0, h_color: float = 6.0) -> np.ndarray:
    """Tiled NLM for large images. Tile with overlap, denoise each, blend overlaps."""
    H, W, _ = bgr.shape
    if H <= tile and W <= tile:
        return nlm_denoise(bgr, h, h_color)
    t = time.time()
    out = np.empty_like(bgr)
    weight = np.zeros((H, W), dtype=np.float32)
    accum = np.zeros((H, W, 3), dtype=np.float32)
    n_tiles_h = (H + tile - 1) // tile
    n_tiles_w = (W + tile - 1) // tile
    print(f"  NLM tiled {n_tiles_h}x{n_tiles_w} (tile={tile}, overlap={overlap})", flush=True)
    for ty in range(n_tiles_h):
        for tx in range(n_tiles_w):
            y0 = max(0, ty * tile - overlap)
            x0 = max(0, tx * tile - overlap)
            y1 = min(H, (ty + 1) * tile + overlap)
            x1 = min(W, (tx + 1) * tile + overlap)
            patch = bgr[y0:y1, x0:x1].copy()
            denoised = cv2.fastNlMeansDenoisingColored(
                patch, None, h=h, hColor=h_color,
                templateWindowSize=7, searchWindowSize=21,
            )
            # Cosine taper for blend
            ph, pw = denoised.shape[:2]
            wy = np.ones(ph, dtype=np.float32)
            wx = np.ones(pw, dtype=np.float32)
            if ty > 0:        wy[:overlap*2] *= np.linspace(0, 1, overlap*2)
            if ty < n_tiles_h-1: wy[-overlap*2:] *= np.linspace(1, 0, overlap*2)
            if tx > 0:        wx[:overlap*2] *= np.linspace(0, 1, overlap*2)
            if tx < n_tiles_w-1: wx[-overlap*2:] *= np.linspace(1, 0, overlap*2)
            w_patch = (wy[:, None] * wx[None, :]).astype(np.float32)
            accum[y0:y1, x0:x1] += denoised.astype(np.float32) * w_patch[..., None]
            weight[y0:y1, x0:x1] += w_patch
            t_elapsed = time.time() - t
            n_done = ty * n_tiles_w + tx + 1
            n_total = n_tiles_h * n_tiles_w
            eta = t_elapsed * (n_total - n_done) / max(n_done, 1)
            print(f"    tile {n_done}/{n_total} elapsed={t_elapsed:.1f}s eta={eta:.1f}s", flush=True)
    out = (accum / np.maximum(weight[..., None], 1e-6)).clip(0, 255).astype(np.uint8)
    print(f"  NLM tiled total {time.time()-t:.1f}s", flush=True)
    return out


def clahe_per_channel(bgr: np.ndarray, clip_limit: float = 2.0, tile_grid: int = 32) -> np.ndarray:
    """CLAHE on each BGR channel independently."""
    t = time.time()
    clahe = cv2.createCLAHE(clipLimit=clip_limit, tileGridSize=(tile_grid, tile_grid))
    out = np.empty_like(bgr)
    for c in range(3):
        out[..., c] = clahe.apply(bgr[..., c])
    print(f"  CLAHE in {time.time()-t:.1f}s  (clip={clip_limit}, tile={tile_grid}x{tile_grid})", flush=True)
    return out


def save_png(bgr: np.ndarray, path: Path) -> None:
    t = time.time()
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    Image.fromarray(rgb).save(path, optimize=False, compress_level=6)
    print(f"  saved {path.name} in {time.time()-t:.1f}s  ({path.stat().st_size/1e6:.1f} MB)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--nlm-h", type=float, default=4.0)
    ap.add_argument("--nlm-hc", type=float, default=6.0)
    ap.add_argument("--clahe-clip", type=float, default=2.0)
    ap.add_argument("--clahe-tile", type=int, default=32)
    ap.add_argument("--no-nlm", action="store_true")
    ap.add_argument("--no-clahe", action="store_true")
    ap.add_argument("--tile-size", type=int, default=4096)
    args = ap.parse_args()

    print(f"==== {args.input.name} -> {args.output.name}", flush=True)
    img = load_png_8bit(args.input)

    if not args.no_nlm:
        img = nlm_denoise_tiled(img, tile=args.tile_size, h=args.nlm_h, h_color=args.nlm_hc)

    if not args.no_clahe:
        img = clahe_per_channel(img, clip_limit=args.clahe_clip, tile_grid=args.clahe_tile)

    save_png(img, args.output)
    print(f"==== done", flush=True)


if __name__ == "__main__":
    main()
