"""Build a complete OpenSeadragon viewer package from a .bin checkpoint.
Develops the full resolution image (any size), generates the DZI tile pyramid via pyvips,
writes the HTML viewer, packages everything into a single directory.

Usage:
    python build_viewer_package.py <bin> <output_dir> [trim_r trim_g trim_b] [--flip]

The --flip flag rotates the output image 180° at display time (without
touching the .bin). Use when the canonical render orientation needs to be
inverted for the standard Buddhabrot pose (body bottom, cusp up).
"""
import sys
import struct
import time
import shutil
from pathlib import Path

import numpy as np
import pyvips

bin_path = sys.argv[1]
out_dir = Path(sys.argv[2])
# Skip flags when reading positional trims
positional = [a for a in sys.argv[3:] if not a.startswith("--")]
trim_r = float(positional[0]) if len(positional) > 0 else 0.137
trim_g = float(positional[1]) if len(positional) > 1 else 0.098
trim_b = float(positional[2]) if len(positional) > 2 else 0.056
flip_180 = "--flip" in sys.argv or "--rotate-180" in sys.argv

# Tile-quality controls. Defaults to high-quality JPG (q92). Override via:
#   --png            lossless PNG tiles (5-10x bigger pyramid, archival quality)
#   --jpg-quality N  set JPG quality 1-100 (default 92; was 85 historically)
#   --webp           modern lossy with better quality/size than JPG at same Q
use_png = "--png" in sys.argv
use_webp = "--webp" in sys.argv
jpg_quality = 92
for i, a in enumerate(sys.argv):
    if a == "--jpg-quality" and i + 1 < len(sys.argv):
        jpg_quality = int(sys.argv[i + 1])

if use_png:
    tile_suffix = ".png"
    tile_format_label = "PNG (lossless)"
elif use_webp:
    tile_suffix = f".webp[Q={jpg_quality}]"
    tile_format_label = f"WebP Q={jpg_quality}"
else:
    tile_suffix = f".jpg[Q={jpg_quality}]"
    tile_format_label = f"JPG Q={jpg_quality}"

if out_dir.exists():
    shutil.rmtree(out_dir)
out_dir.mkdir(parents=True)

# -------- Load header + memmap --------
with open(bin_path, "rb") as f:
    header = f.read(128)
width = struct.unpack_from("<I", header, 8)[0]
height = struct.unpack_from("<I", header, 12)[0]
samples_done = struct.unpack_from("<Q", header, 32)[0]
print(f"Source: {bin_path}")
print(f"  {width}×{height}, samples_done={samples_done:,}")
print(f"  trims R={trim_r} G={trim_g} B={trim_b}")
print(f"  flip 180°: {flip_180}")
print(f"  tile format: {tile_format_label}")

hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                 offset=128, shape=(height, width, 3))

# -------- Pass 1: channel max --------
print("\n[1/4] scanning channel max...")
t0 = time.time()
ch_max = np.zeros(3, dtype=np.uint64)
for ys in range(0, height, 512):
    yp = min(ys + 512, height)
    ch_max = np.maximum(ch_max, hist[ys:yp].reshape(-1, 3).max(axis=0))
r_max, g_max, b_max = (int(x) for x in ch_max)
print(f"  R_max={r_max:,} G_max={g_max:,} B_max={b_max:,}  ({time.time()-t0:.1f}s)")

# -------- Pass 2: tonemap to full-res 8-bit RGB --------
print(f"\n[2/4] tonemapping to 8-bit RGB (full {width}x{height})...")
t1 = time.time()
out8 = np.zeros((height, width, 3), dtype=np.uint8)

def tonemap_strip(strip_uint64, mx, trim):
    if mx <= 0 or trim <= 0:
        return np.zeros(strip_uint64.shape, dtype=np.uint8)
    t = strip_uint64.astype(np.float32) / (float(mx) * float(trim))
    np.clip(t, 0.0, 1.0, out=t)
    one_minus = 1.0 - t
    one_minus *= one_minus
    one_minus *= one_minus
    d = 255.0 * (1.0 - one_minus)
    return np.clip(d, 0, 255).astype(np.uint8)

strip = 256
for ys in range(0, height, strip):
    yp = min(ys + strip, height)
    block = hist[ys:yp]
    out8[ys:yp, :, 0] = tonemap_strip(block[:, :, 0], r_max, trim_r)
    out8[ys:yp, :, 1] = tonemap_strip(block[:, :, 1], g_max, trim_g)
    out8[ys:yp, :, 2] = tonemap_strip(block[:, :, 2], b_max, trim_b)
    if (ys // strip) % 16 == 0:
        print(f"  rows {ys}/{height}", flush=True)
print(f"  done in {time.time()-t1:.1f}s")
print(f"  out8 array: {out8.nbytes / 1e9:.2f} GB")

# Optional 180° rotation (display-time only — .bin is untouched).
if flip_180:
    print("\n  applying 180° rotation (--flip)...")
    out8 = np.ascontiguousarray(out8[::-1, ::-1])  # vertical + horizontal flip = 180°

# -------- Pass 3: pyvips DZI pyramid --------
print("\n[3/4] generating DZI tile pyramid via pyvips...")
t2 = time.time()
# Create pyvips image from numpy buffer (zero-copy reference)
img = pyvips.Image.new_from_memory(
    out8.tobytes(),
    width=width,
    height=height,
    bands=3,
    format="uchar",
)
print(f"  pyvips image: {img.width}×{img.height}, {img.bands} bands")

pyramid_prefix = str(out_dir / "pyramid")
img.dzsave(
    pyramid_prefix,
    suffix=tile_suffix,
    tile_size=256,
    overlap=0,
)
print(f"  dzsave done in {time.time()-t2:.1f}s")

# Count tiles
files_dir = Path(pyramid_prefix + "_files")
# Glob pattern matches actual tile extension (.jpg / .png / .webp)
tile_ext = "*.png" if use_png else ("*.webp" if use_webp else "*.jpg")
tile_count = sum(1 for _ in files_dir.rglob(tile_ext))
total_size = sum(p.stat().st_size for p in files_dir.rglob(tile_ext))
print(f"  pyramid: {tile_count} tiles, {total_size / 1e6:.1f} MB total")

# -------- Pass 4: write HTML viewer + launch script --------
print("\n[4/4] writing viewer.html + launch script...")
viewer_html = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Buddhabrot {width}x{height} — cp{cp_label}</title>
<style>
  body {{ margin: 0; padding: 0; background: #000; overflow: hidden; font-family: monospace; color: #888; }}
  #osd {{ width: 100vw; height: 100vh; }}
  #info {{ position: fixed; top: 10px; left: 10px; padding: 8px 12px; background: rgba(0,0,0,0.6); border: 1px solid #333; font-size: 12px; pointer-events: none; }}
  #info span {{ color: #ccc; }}
</style>
</head>
<body>
<div id="osd"></div>
<div id="info">
  Buddhabrot {width}x{height} — <span>cp{cp_label}</span> — <span>{samples}</span> samples<br>
  trims R=<span>{tr}</span> G=<span>{tg}</span> B=<span>{tb}</span><br>
  drag to pan • scroll/pinch to zoom • <span>HOME</span> to reset
</div>
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
<script>
  var viewer = OpenSeadragon({{
    id: "osd",
    tileSources: "pyramid.dzi",
    prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
    showNavigator: true,
    navigatorPosition: "BOTTOM_RIGHT",
    navigatorBackground: "#000",
    navigatorBorderColor: "#333",
    minZoomLevel: 0.5,
    maxZoomPixelRatio: 4.0,
    visibilityRatio: 1.0,
    constrainDuringPan: true,
    animationTime: 0.6,
    blendTime: 0.1,
  }});
</script>
</body>
</html>
"""

# Extract cp label from bin filename
cp_label = "?"
for token in Path(bin_path).stem.split("."):
    if token.startswith("cp"):
        cp_label = token[2:]
        break

(out_dir / "viewer.html").write_text(
    viewer_html.format(
        cp_label=cp_label,
        samples=f"{samples_done:,}",
        tr=trim_r,
        tg=trim_g,
        tb=trim_b,
        width=width,
        height=height,
    ),
    encoding="utf-8",
)

# Pick a unique port per viewer derived from cp_label so different viewers
# don't share browser cache state. cp number → port offset in range 8000-8999.
# This solves the common "I launched a new viewer but it shows the old one's
# tiles" problem caused by browser caching identical tile URLs.
try:
    port = 8000 + (int(cp_label) % 1000)
except (ValueError, TypeError):
    port = 8000
viewer_url = f"http://localhost:{port}/viewer.html"

# Launch script — starts a local HTTP server and opens the browser
launch_bat = f"""@echo off
echo Starting local server on {viewer_url} ...
echo Press Ctrl+C to stop the server when done.
start {viewer_url}
python -m http.server {port}
"""
(out_dir / "LAUNCH.bat").write_text(launch_bat, encoding="utf-8")

launch_sh = f"""#!/usr/bin/env bash
echo "Starting local server on {viewer_url} ..."
echo "Press Ctrl+C to stop the server when done."
python3 -m http.server {port} &
SERVER_PID=$!
sleep 1
if command -v xdg-open >/dev/null; then xdg-open {viewer_url}
elif command -v open >/dev/null; then open {viewer_url}
fi
wait $SERVER_PID
"""
(out_dir / "LAUNCH.sh").write_text(launch_sh, encoding="utf-8")

readme = f"""Buddhabrot Viewer Package ({width} x {height})
================================
Source: {Path(bin_path).name}
Resolution: {width} x {height}
Samples integrated: {samples_done:,}
Trims (density-correct for this checkpoint): R={trim_r} G={trim_g} B={trim_b}

How to use:
  Windows:  Double-click LAUNCH.bat
  Linux/Mac: bash LAUNCH.sh

That starts a local web server and opens your browser to the viewer.
Drag to pan, scroll/pinch to zoom. The pyramid loads tiles on demand,
so it stays responsive even at full {width}x{height} resolution.

Contents:
  viewer.html         OpenSeadragon viewer page
  pyramid.dzi         DZI manifest (XML)
  pyramid_files/      ~{tile_count} JPG tiles ({total_size / 1e6:.0f} MB total)
  LAUNCH.bat/.sh      Launch local server + open browser

The viewer pulls OpenSeadragon JS from a CDN, so it needs internet on
first load. After that, browser cache makes it work offline too.

To share publicly: upload this whole directory to any static host
(GitHub Pages, Cloudflare R2, Netlify, S3). The viewer URL becomes
the share link.
"""
(out_dir / "README.txt").write_text(readme, encoding="utf-8")

print(f"  wrote viewer.html, LAUNCH.bat, LAUNCH.sh, README.txt")

print(f"\n{'='*60}")
print(f"Package ready: {out_dir.resolve()}")
print(f"  Total size: {sum(p.stat().st_size for p in out_dir.rglob('*')) / 1e6:.0f} MB")
print(f"  To launch:  cd {out_dir} && LAUNCH.bat   (Windows)")
print(f"              cd {out_dir} && bash LAUNCH.sh  (Linux/Mac)")
print(f"{'='*60}")
