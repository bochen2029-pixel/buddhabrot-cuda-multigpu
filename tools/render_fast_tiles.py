"""Per-region fast tile render -- focused-budget alternative to monolithic.

Architectural premise (verified empirically by user observations):
  - Monolithic 32K/64K with N samples spreads N across W*H pixels.
  - Per-tile rendering with the SAME N total spreads N/n_tiles across each
    tile, BUT each tile has its own view-aware IMap concentrated on its
    c-space subregion. IS efficiency improves substantially because the
    IMap pinpoints rare-orbit cells with 64x higher c-space resolution
    (when each tile is 1/64 the area).
  - At deep zoom in OpenSeadragon, per-pixel density is what matters --
    not absolute total resolution. Per-tile rendering at the desired
    viewing resolution gives sharp deep-zoom even at modest total
    sample budgets.

Workflow:
  1. python render_fast_tiles.py --grid 8x8 --resolution 2048x1536 \
       --seconds-per-tile 60 --output-dir tiles_8x8/
  2. python stitch_fast_tiles.py --input-dir tiles_8x8/ --output stitched.bin
  3. python build_viewer_package.py stitched.bin viewer/ <trims>
  4. Open viewer/LAUNCH.bat

Time budget for default 8x8 @ 2K @ 60s each on home 4070 Ti SUPER:
  - 64 tiles x (~10s IMap build + 60s render + 5s save) = ~80 min total
  - Final image: 16K x 12K = 200 Mpx
  - Per-tile density: ~140 traj/pixel native (vs ~54 traj/pixel for
    a 32K monolithic at the same wallclock)

On H200 (12 M/s):
  - 64 x (~5s IMap + 60s render + 2s save) = ~72 min total
  - Same per-tile density as above
"""
import argparse
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

CANONICAL_CENTER_RE = -0.5935417456742
CANONICAL_CENTER_IM =  0.04166264380232
CANONICAL_ZOOM      =  0.5
CANONICAL_ROTATION  =  90.0
CANONICAL_SAMPLE_R  =  2.5


def parse_grid(s):
    a, b = s.lower().split("x")
    return int(a), int(b)


def parse_resolution(s):
    a, b = s.lower().split("x")
    return int(a), int(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grid", default="8x8", help="tile grid: cols x rows (e.g. 4x4, 8x8, 16x16)")
    ap.add_argument("--resolution", default="2048x1536",
                    help="per-tile pixel resolution (e.g. 2048x1536 -> 16K total at 8x8)")
    ap.add_argument("--seconds-per-tile", type=int, default=60,
                    help="wallclock budget per tile (sample count derived from estimated throughput)")
    ap.add_argument("--throughput-est", type=float, default=10.0,
                    help="estimated samples/second in M (per-GPU IS rate; 7 for 4070 Ti, 12 for H100, 15-20 for H200)")
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--skip-view-imap", action="store_true",
                    help="skip per-tile view-aware IMap build; use shared canonical imap.bin instead")
    ap.add_argument("--canonical-imap", default="imap.bin",
                    help="canonical IMap path (used when --skip-view-imap)")
    ap.add_argument("--canonical-view-center", default=f"{CANONICAL_CENTER_RE},{CANONICAL_CENTER_IM}")
    ap.add_argument("--canonical-zoom", type=float, default=CANONICAL_ZOOM)
    ap.add_argument("--rotation-deg", type=float, default=CANONICAL_ROTATION)
    ap.add_argument("--sample-radius", type=float, default=CANONICAL_SAMPLE_R)
    ap.add_argument("--iter-r", type=int, default=2000)
    ap.add_argument("--iter-g", type=int, default=200)
    ap.add_argument("--iter-b", type=int, default=20)
    ap.add_argument("--trim-r", type=float, default=0.137)
    ap.add_argument("--trim-g", type=float, default=0.098)
    ap.add_argument("--trim-b", type=float, default=0.056)
    ap.add_argument("--imap-samples", type=int, default=500_000_000,
                    help="samples for per-tile view-IMap build (smaller = faster, less accurate)")
    ap.add_argument("--samples-per-thread", type=int, default=8)
    ap.add_argument("--launches-per-round", type=int, default=8)
    ap.add_argument("--devices", type=int, default=1)
    ap.add_argument("--buddhabrot-bin", default="./buddhabrot")
    ap.add_argument("--apron", type=int, default=64,
                    help="overlap apron in pixels (each side). 0 = no blend (visible seams). "
                         "64+ = smooth via compose_blended.py at stitch time.")
    ap.add_argument("--start-tile", type=int, default=0,
                    help="resume from this tile index (skip already-rendered tiles)")
    args = ap.parse_args()

    cols, rows = parse_grid(args.grid)
    tile_w, tile_h = parse_resolution(args.resolution)
    n_tiles = cols * rows
    canonical_cx, canonical_cy = (float(x) for x in args.canonical_view_center.split(","))

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- Tile geometry (same math as tile_orchestrate.py) ---
    canonical_y_span = 4.0 / (2.0 ** args.canonical_zoom)
    canonical_aspect = tile_w / tile_h
    canonical_x_span = canonical_y_span * canonical_aspect

    tile_y_span = canonical_y_span / rows
    tile_x_span = canonical_x_span / cols
    tile_zoom = math.log2(4.0 / tile_y_span)

    rot_rad = math.radians(args.rotation_deg)
    cos_p = math.cos(rot_rad)
    sin_p = math.sin(rot_rad)

    # Apron-extended render dimensions. Apron is in pixels, on each side.
    # Render width/height bumped to tile + 2*apron; zoom adjusted to keep same
    # per-pixel c-resolution. Compatible with stitch_tiles.py + compose_blended.py.
    apron_w = tile_w + 2 * args.apron
    apron_h = tile_h + 2 * args.apron
    apron_y_span = tile_y_span * (apron_h / tile_h)
    apron_zoom = math.log2(4.0 / apron_y_span)

    # Compute per-tile samples from time budget x throughput estimate
    samples_per_tile = int(args.seconds_per_tile * args.throughput_est * 1e6)

    total_samples = samples_per_tile * n_tiles
    total_pixels = cols * tile_w * rows * tile_h
    per_pixel_density = samples_per_tile / (tile_w * tile_h)

    print(f"{'='*60}")
    print(f"Fast-tile render plan")
    print(f"{'='*60}")
    print(f"Grid:              {cols} cols x {rows} rows = {n_tiles} tiles")
    print(f"Per-tile pixels:   {tile_w} x {tile_h} (native) = {tile_w*tile_h/1e6:.1f} Mpx")
    print(f"Render dims:       {apron_w} x {apron_h} (apron={args.apron} each side)")
    print(f"Per-tile zoom:     {tile_zoom:.4f} (apron zoom: {apron_zoom:.4f})")
    print(f"Total stitched:    {cols*tile_w} x {rows*tile_h} = {total_pixels/1e6:.0f} Mpx")
    print(f"Throughput est:    {args.throughput_est} M/s per GPU")
    print(f"Per-tile budget:   {args.seconds_per_tile}s = {samples_per_tile:,} samples")
    print(f"Per-pixel density: {per_pixel_density:.0f} traj/pixel native")
    print(f"Total samples:     {total_samples:,}")
    print(f"Wallclock est:     {n_tiles * (args.seconds_per_tile + 10) / 60:.1f} min")
    print(f"Output dir:        {out_dir.resolve()}")
    print(f"{'='*60}\n")

    # --- Emit tile_spec.json (compatible with stitch_tiles.py) ---
    spec_tiles = []
    for tile_idx in range(n_tiles):
        i = tile_idx % cols
        j = tile_idx // cols
        dx_display = (i - (cols - 1) / 2.0) * tile_x_span
        dy_display = (j - (rows - 1) / 2.0) * tile_y_span
        dx_c = cos_p * dx_display - sin_p * dy_display
        dy_c = sin_p * dx_display + cos_p * dy_display
        spec_tiles.append({
            "id": f"r{j:02d}c{i:02d}",
            "i": i, "j": j,
            "center_re": canonical_cx + dx_c,
            "center_im": canonical_cy + dy_c,
            "zoom_native": tile_zoom,
            "zoom_apron": apron_zoom,
            "width": apron_w,
            "height": apron_h,
            "native_width": tile_w,
            "native_height": tile_h,
            "apron": args.apron,
            "samples": samples_per_tile,
        })
    spec = {
        "grid": [cols, rows],
        "n_tiles": n_tiles,
        "total_samples": total_samples,
        "canonical_view_center": [canonical_cx, canonical_cy],
        "canonical_zoom": args.canonical_zoom,
        "rotation_deg": args.rotation_deg,
        "sample_radius": args.sample_radius,
        "per_tile_width": tile_w,
        "per_tile_height": tile_h,
        "apron": args.apron,
        "iter_r": args.iter_r, "iter_g": args.iter_g, "iter_b": args.iter_b,
        "tiles": spec_tiles,
    }
    spec_path = out_dir / "tile_spec.json"
    with open(spec_path, "w") as f:
        json.dump(spec, f, indent=2)
    print(f"wrote {spec_path}\n")

    # --- Tile-by-tile render loop ---
    t_start = time.time()
    skipped = 0
    rendered = 0

    for tile_idx in range(n_tiles):
        if tile_idx < args.start_tile:
            skipped += 1
            continue
        i = tile_idx % cols
        j = tile_idx // cols
        tile_id = f"r{j:02d}c{i:02d}"
        tile_png = out_dir / f"{tile_id}.png"
        tile_bin = out_dir / f"{tile_id}.bin"
        tile_imap = out_dir / f"{tile_id}_imap.bin"

        # Skip if already rendered
        if tile_bin.exists():
            print(f"[{tile_idx+1}/{n_tiles}] {tile_id}: already exists, skipping")
            skipped += 1
            continue

        # Use precomputed tile spec for center / zoom (apron-extended)
        tile_spec = spec_tiles[tile_idx]
        tile_cx = tile_spec["center_re"]
        tile_cy = tile_spec["center_im"]
        render_zoom = apron_zoom    # apron-extended zoom for the actual buddhabrot render
        render_w = apron_w
        render_h = apron_h

        t_tile = time.time()
        print(f"[{tile_idx+1}/{n_tiles}] {tile_id} @ center ({tile_cx:.10f}, {tile_cy:.10f}) zoom {render_zoom:.3f}")

        # Phase A: build view-aware IMap (or use canonical)
        if args.skip_view_imap:
            imap_arg = args.canonical_imap
            print(f"  (using shared canonical IMap: {imap_arg})")
        else:
            t_imap = time.time()
            print(f"  [A] building view-aware IMap ({args.imap_samples:,} samples)...")
            cmd = [
                args.buddhabrot_bin,
                "--build-view-imap", str(tile_imap),
                "--width", str(render_w),
                "--height", str(render_h),
                "--view-center-x", str(tile_cx),
                "--view-center-y", str(tile_cy),
                "--zoom", str(render_zoom),
                "--rotation-deg", str(args.rotation_deg),
                "--sample-radius", str(args.sample_radius),
                "--imap-samples", str(args.imap_samples),
                "--iter-r", str(args.iter_r),
                "--iter-g", str(args.iter_g),
                "--iter-b", str(args.iter_b),
                "--devices", str(args.devices),
            ]
            ret = subprocess.run(cmd)
            if ret.returncode != 0:
                print(f"  ERROR: IMap build failed for {tile_id}")
                sys.exit(1)
            print(f"      IMap done in {time.time()-t_imap:.1f}s")
            imap_arg = str(tile_imap)

        # Phase B: production render
        t_render = time.time()
        print(f"  [B] rendering ({samples_per_tile:,} samples)...")
        cmd = [
            args.buddhabrot_bin,
            "--width", str(render_w),
            "--height", str(render_h),
            "--samples", str(samples_per_tile),
            "--imap", imap_arg,
            "--view-center-x", str(tile_cx),
            "--view-center-y", str(tile_cy),
            "--zoom", str(render_zoom),
            "--rotation-deg", str(args.rotation_deg),
            "--sample-radius", str(args.sample_radius),
            "--iter-r", str(args.iter_r),
            "--iter-g", str(args.iter_g),
            "--iter-b", str(args.iter_b),
            "--trim-r", str(args.trim_r),
            "--trim-g", str(args.trim_g),
            "--trim-b", str(args.trim_b),
            "--samples-per-thread", str(args.samples_per_thread),
            "--launches-per-round", str(args.launches_per_round),
            "--devices", str(args.devices),
            "--output", str(tile_png),
        ]
        ret = subprocess.run(cmd)
        if ret.returncode != 0:
            print(f"  ERROR: render failed for {tile_id}")
            sys.exit(1)
        print(f"      render done in {time.time()-t_render:.1f}s")
        print(f"      tile total: {time.time()-t_tile:.1f}s")

        rendered += 1
        elapsed = time.time() - t_start
        if rendered > 0:
            rate = rendered / elapsed
            remaining = n_tiles - tile_idx - 1
            eta = remaining / rate if rate > 0 else 0
            print(f"  progress: {rendered}/{n_tiles - skipped} rendered, "
                  f"{remaining} remaining, ETA {eta/60:.1f} min\n")

    total_time = time.time() - t_start
    print(f"\n{'='*60}")
    print(f"DONE -- {rendered} tiles rendered, {skipped} skipped, total {total_time/60:.1f} min")
    print(f"{'='*60}\n")
    print(f"Next: stitch tiles + compose blends, then build viewer:")
    print(f"  python tools/stitch_tiles.py --tile-dir {args.output_dir} \\")
    print(f"      --output-dir {args.output_dir}/stitched/ \\")
    print(f"      --trim-r {args.trim_r} --trim-g {args.trim_g} --trim-b {args.trim_b}")
    print(f"  python tools/compose_blended.py --input-dir {args.output_dir}/stitched/ \\")
    print(f"      --output blended.png")
    print(f"  python tools/build_dz_pyramid.py --stitched-dir {args.output_dir}/stitched/ \\")
    print(f"      --output viewer_fast")
    print(f"")
    print(f"OR for a simple no-blend test (visible seams; quick to evaluate):")
    print(f"  re-run with --apron 0 and stitch manually edge-to-edge")


if __name__ == "__main__":
    main()
