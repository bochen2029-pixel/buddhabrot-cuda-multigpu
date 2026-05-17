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
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
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


def compute_tile_order(order: str, tile_indices: list, cols: int, rows: int,
                       guide_array, guide_W: int, guide_H: int) -> list:
    """Reorder tile_indices according to the chosen strategy, using the guide
    as the brightness oracle.

    Strategies:
        brightness         - DESC by guide_region_max (renders body cusp first,
                             empty background last; best for crash resilience).
        spiral             - ASC by distance from brightness-weighted centroid
                             (center-out radial; assumes single bright concentration).
        brightness-spiral  - top 25%% by brightness first (in brightness order),
                             remainder by spiral from centroid (hybrid).

    Tiles excluded from the input list (e.g. those skipped by --start-tile)
    are not reintroduced.
    """
    import numpy as np

    def tile_max(tile_idx: int) -> int:
        i = tile_idx % cols
        j = tile_idx // cols
        gx0 = (i      * guide_W) // cols
        gx1 = ((i + 1) * guide_W) // cols
        gy0 = (j      * guide_H) // rows
        gy1 = ((j + 1) * guide_H) // rows
        return int(guide_array[gy0:gy1, gx0:gx1].max())

    if order == "brightness":
        return sorted(tile_indices, key=tile_max, reverse=True)

    # Brightness-weighted centroid in guide-pixel coords, then convert to
    # fractional tile coords. If guide is all-zero (degenerate), centroid
    # falls back to the geometric center.
    weights = guide_array.astype(np.float64)
    total = weights.sum()
    if total > 0:
        ys, xs = np.indices(guide_array.shape)
        cx_guide = float((xs * weights).sum() / total)
        cy_guide = float((ys * weights).sum() / total)
    else:
        cx_guide = guide_W / 2.0
        cy_guide = guide_H / 2.0
    cx_tile = cx_guide / guide_W * cols
    cy_tile = cy_guide / guide_H * rows
    print(f"[order] brightness centroid: guide=({cx_guide:.1f},{cy_guide:.1f}) "
          f"-> tile=({cx_tile:.3f},{cy_tile:.3f}) (cols={cols}, rows={rows})")

    def tile_dist(tile_idx: int) -> float:
        i = tile_idx % cols
        j = tile_idx // cols
        # Tile center in tile-coord space is (i+0.5, j+0.5)
        return (i + 0.5 - cx_tile) ** 2 + (j + 0.5 - cy_tile) ** 2

    if order == "spiral":
        return sorted(tile_indices, key=tile_dist)

    if order == "brightness-spiral":
        n = len(tile_indices)
        n_bright = max(1, n // 4)
        by_brightness = sorted(tile_indices, key=tile_max, reverse=True)
        bright_first = by_brightness[:n_bright]
        bright_set = set(bright_first)
        remaining = [t for t in tile_indices if t not in bright_set]
        remaining_spiral = sorted(remaining, key=tile_dist)
        return bright_first + remaining_spiral

    raise ValueError(f"unknown tile-order: {order}")


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
    ap.add_argument("--devices", type=int, default=1,
                    help="GPU devices PER TILE (almost always 1 — each tile uses a single GPU; "
                         "use --num-gpus to spread DIFFERENT tiles across N cards in parallel)")
    ap.add_argument("--num-gpus", type=int, default=1,
                    help="number of GPUs to use IN PARALLEL across different tiles. "
                         "N workers run concurrently, each pinned to its own GPU via "
                         "CUDA_VISIBLE_DEVICES. Tiles are independent so scaling is near-linear. "
                         "Set to 1 for single-GPU (no parallelism). Set to 8 for 8x H100 rig.")
    ap.add_argument("--buddhabrot-bin", default="./buddhabrot")
    ap.add_argument("--guide-bin", default="",
                    help="optional downsampled guide .gbin for bin-guided IMap construction. "
                         "Use tools/downsample_bin.py to produce from an existing high-quality .bin. "
                         "Concentrates IMap on visually-important regions, 1.5-3x more efficient IS.")
    ap.add_argument("--classify-threshold", type=int, default=2000,
                    help="when --guide-bin is set, tiles whose corresponding guide region max "
                         "is BELOW this value use canonical IMap (--skip-view-imap) instead of "
                         "bin-guided. Prevents extreme tonal islands at tile boundaries from "
                         "over-concentration on dim regions. 0 disables classification. "
                         "Default 2000 (~3%% of uint16 max).")
    ap.add_argument("--guide-min-weight", type=int, default=8,
                    help="floor for bin-guided IMap weights (passed to buddhabrot kernel). "
                         "Each viewport-hit contributes max(guide_value>>8, FLOOR) to IMap. "
                         "0 = pure bin-guided (creates tonal-island artifacts at tile boundaries). "
                         "Default 8 ensures dim viewport regions still get baseline sampling, "
                         "smoothing tile-tile tonal discontinuities. Tunable 0-64.")
    ap.add_argument("--hf-bucket", default="",
                    help="optional HF bucket name (e.g. bochen2079/buddhabrot). When set, the "
                         "script will start a background hf sync loop that uploads each tile's "
                         ".bin + .png as they land on disk. Subdir on HF will match --output-dir name.")
    ap.add_argument("--hf-sync-interval", type=int, default=60,
                    help="seconds between background HF sync passes (default 60)")
    ap.add_argument("--apron", type=int, default=64,
                    help="overlap apron in pixels (each side). 0 = no blend (visible seams). "
                         "64+ = smooth via compose_blended.py at stitch time.")
    ap.add_argument("--start-tile", type=int, default=0,
                    help="resume from this tile index (skip already-rendered tiles)")
    ap.add_argument("--tile-order", default="naive",
                    choices=["naive", "brightness", "spiral", "brightness-spiral"],
                    help="tile rendering order. 'naive' (default) = row-major "
                         "top-to-bottom left-to-right (unchanged existing behavior). "
                         "'brightness' = sort by guide region max DESC (renders body "
                         "cusp + bulbs first, empty background last; best for "
                         "crash-resilience). 'spiral' = sort by distance from "
                         "brightness-weighted centroid ASC (center-out radial). "
                         "'brightness-spiral' = top 25%% by brightness first, then "
                         "remainder spiral from centroid. All non-naive modes require "
                         "--guide-bin; falls back to naive with warning if guide unavailable.")
    args = ap.parse_args()

    cols, rows = parse_grid(args.grid)
    tile_w, tile_h = parse_resolution(args.resolution)
    n_tiles = cols * rows
    canonical_cx, canonical_cy = (float(x) for x in args.canonical_view_center.split(","))

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- Optional: load the guide ONCE for per-tile classification ---
    # When --guide-bin is set AND --classify-threshold > 0, we read the guide
    # header + body, then for each tile look up the max guide value in that
    # tile's image-space region. Tiles where max < threshold use canonical
    # IMap (--skip-view-imap) instead of bin-guided. Prevents the extreme
    # tonal-island problem that creates visible 16x16 grid artifacts at low
    # zoom levels in OpenSeadragon.
    guide_array = None       # 2D uint16 numpy array (lazy-loaded if needed)
    guide_W = 0
    guide_H = 0
    if args.guide_bin and (args.classify_threshold > 0 or args.tile_order != "naive"):
        import numpy as np
        import struct as _struct
        try:
            with open(args.guide_bin, "rb") as gf:
                gheader = gf.read(32)
                if gheader[:4] != b"GBIN":
                    print(f"WARN: guide file bad magic; tile classification DISABLED")
                else:
                    guide_W = _struct.unpack_from("<I", gheader, 8)[0]
                    guide_H = _struct.unpack_from("<I", gheader, 12)[0]
                    n_pixels = guide_W * guide_H
                    raw = gf.read(n_pixels * 2)
                    guide_array = np.frombuffer(raw, dtype=np.uint16).reshape(guide_H, guide_W)
                    print(f"[classify] guide loaded for per-tile classification: "
                          f"{guide_W}x{guide_H}, threshold={args.classify_threshold}")
        except Exception as e:
            print(f"WARN: couldn't load guide for classification: {e}")
            guide_array = None

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

    # --- Optionally start background HF sync loop ---
    # Each pass uploads any new tile .bin / .png since the last sync. Tile-naming
    # convention (rNNcMM) means each upload only includes the matching files for
    # that tile. The loop continues until killed at end of render.
    hf_loop_pid = None
    if args.hf_bucket:
        out_name = out_dir.name
        hf_url = f"hf://buckets/{args.hf_bucket}/{out_name}/"
        log_path = "/tmp/hf_tiles_loop.log"
        sync_cmd = (
            f'cd "{out_dir.resolve()}" && '
            f'while true; do '
            f'echo "[hf-tiles $(date -u +%H:%M:%S)] sync pass"; '
            f'hf sync . "{hf_url}" '
            f'--include "r*c*.bin" --include "r*c*.png" --include "tile_spec.json" '
            f'2>&1 | tail -3; '
            f'sleep {args.hf_sync_interval}; '
            f'done'
        )
        proc = subprocess.Popen(
            ["nohup", "bash", "-c", sync_cmd],
            stdout=open(log_path, "wb"),
            stderr=subprocess.STDOUT,
            preexec_fn=os.setpgrp,  # detach from this process group
        )
        hf_loop_pid = proc.pid
        print(f"[hf] background sync loop PID {hf_loop_pid}")
        print(f"[hf] uploading to {hf_url} every {args.hf_sync_interval}s")
        print(f"[hf] tail loop log: tail -f {log_path}\n")

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

    # --- Per-tile worker (callable from thread pool when --num-gpus > 1) ---
    # Each worker is pinned to ONE GPU via CUDA_VISIBLE_DEVICES. Tiles are
    # independent so N workers fan out across N GPUs with near-linear scaling.
    # On a single-GPU machine (num_gpus=1) the pool size is 1, which gives the
    # same behavior as the previous serial loop.
    print_lock = threading.Lock()

    def render_one_tile(tile_idx: int, gpu_id: int) -> tuple[int, str, float, bool]:
        """Render a single tile on the specified GPU. Returns
        (tile_idx, tile_id, elapsed_sec, did_work) — did_work=False if skipped."""
        i = tile_idx % cols
        j = tile_idx // cols
        tile_id = f"r{j:02d}c{i:02d}"
        tile_png = out_dir / f"{tile_id}.png"
        tile_bin = out_dir / f"{tile_id}.bin"
        tile_imap = out_dir / f"{tile_id}_imap.bin"

        # Skip if already rendered (cheap idempotent resume — tile-level skip is
        # sufficient resilience; we don't need per-tile mid-render resume since
        # tile wallclock is bounded at minutes).
        if tile_bin.exists():
            with print_lock:
                print(f"[{tile_idx+1}/{n_tiles}] {tile_id}: already exists, skipping")
            return tile_idx, tile_id, 0.0, False

        tile_spec_ = spec_tiles[tile_idx]
        tile_cx = tile_spec_["center_re"]
        tile_cy = tile_spec_["center_im"]
        render_zoom = apron_zoom
        render_w = apron_w
        render_h = apron_h

        # CUDA_VISIBLE_DEVICES masks all other GPUs from the spawned process,
        # so the renderer's --devices 1 effectively pins to physical GPU N.
        # If --num-gpus 1, gpu_id is 0 and we don't actually need to set the
        # env var, but doing it unconditionally keeps the code path uniform.
        env = os.environ.copy()
        env["CUDA_VISIBLE_DEVICES"] = str(gpu_id)

        t_tile = time.time()
        with print_lock:
            print(f"[{tile_idx+1}/{n_tiles}] {tile_id} @ GPU{gpu_id} "
                  f"center ({tile_cx:.10f}, {tile_cy:.10f}) zoom {render_zoom:.3f}")

        # --- Per-tile classification (if guide loaded + threshold > 0) ---
        # Look up the max guide value in this tile's image-space region.
        # If below threshold, fall back to canonical IMap (--skip-view-imap):
        # avoids extreme tonal islands from over-concentration on dim regions.
        tile_use_guided = (args.guide_bin and not args.skip_view_imap)
        tile_classify_reason = ""
        if guide_array is not None and tile_use_guided:
            # Tile (i,j) covers image region [i*tile_w:(i+1)*tile_w, j*tile_h:(j+1)*tile_h]
            # in stitched-image coords. Scale to guide-image coords:
            gx0 = (i      * guide_W) // cols
            gx1 = ((i+1)  * guide_W) // cols
            gy0 = (j      * guide_H) // rows
            gy1 = ((j+1)  * guide_H) // rows
            region_max = int(guide_array[gy0:gy1, gx0:gx1].max())
            if region_max < args.classify_threshold:
                tile_use_guided = False
                tile_classify_reason = f"dim (guide_max={region_max} < {args.classify_threshold})"
            else:
                tile_classify_reason = f"bright (guide_max={region_max})"

        # Phase A: build view-aware IMap (or use canonical)
        if args.skip_view_imap or not tile_use_guided:
            imap_arg = args.canonical_imap
            if tile_classify_reason:
                with print_lock:
                    print(f"  [classify] {tile_id}: {tile_classify_reason} -> using canonical IMap")
        else:
            t_imap = time.time()
            with print_lock:
                if tile_classify_reason:
                    print(f"  [classify] {tile_id}: {tile_classify_reason} -> bin-guided view IMap")
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
            if args.guide_bin:
                cmd.extend(["--guide-bin", args.guide_bin])
                if args.guide_min_weight > 0:
                    cmd.extend(["--guide-min-weight", str(args.guide_min_weight)])
            ret = subprocess.run(cmd, env=env)
            if ret.returncode != 0:
                with print_lock:
                    print(f"  ERROR: IMap build failed for {tile_id} (GPU{gpu_id})")
                raise RuntimeError(f"IMap build failed for {tile_id}")
            imap_arg = str(tile_imap)

        # Phase B: production render
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
        ret = subprocess.run(cmd, env=env)
        if ret.returncode != 0:
            with print_lock:
                print(f"  ERROR: render failed for {tile_id} (GPU{gpu_id})")
            raise RuntimeError(f"render failed for {tile_id}")

        elapsed = time.time() - t_tile
        with print_lock:
            print(f"  [{tile_id}] GPU{gpu_id} DONE in {elapsed:.1f}s")
        return tile_idx, tile_id, elapsed, True

    # --- Tile work distribution ---
    t_start = time.time()
    skipped = 0
    rendered = 0
    tile_indices = [t for t in range(args.start_tile, n_tiles)]
    if not tile_indices:
        print("No tiles to render (start_tile >= n_tiles).")
        return

    # --- Optional: reorder tile_indices by --tile-order strategy ---
    # Default 'naive' is row-major (unchanged behavior). Other modes use the
    # guide to bias rendering toward visually-important tiles first; if the
    # render is interrupted, the artifact-so-far is the bright structure not
    # empty background. Submission-order in the ThreadPoolExecutor parallel
    # path determines which tiles get STARTED first, so this works for both
    # serial (num_gpus=1) and parallel (num_gpus>1) execution.
    if args.tile_order != "naive":
        if guide_array is None:
            print(f"WARN: --tile-order {args.tile_order} requires --guide-bin "
                  f"with a loadable guide; falling back to naive ordering")
        else:
            tile_indices = compute_tile_order(
                args.tile_order, tile_indices, cols, rows,
                guide_array, guide_W, guide_H,
            )
            preview = [f"r{t//cols:02d}c{t%cols:02d}" for t in tile_indices[:8]]
            print(f"[order] strategy: {args.tile_order}; "
                  f"first 8 tiles: {preview}")

    if args.num_gpus <= 1:
        # Serial path — preserves original ordering / progress output.
        for k, tile_idx in enumerate(tile_indices):
            try:
                _, tile_id, elapsed, did_work = render_one_tile(tile_idx, 0)
                if did_work:
                    rendered += 1
                else:
                    skipped += 1
            except RuntimeError as e:
                print(f"FATAL: {e}")
                sys.exit(1)
            # ETA on serial path: just based on average per-tile time so far.
            if rendered > 0:
                completed = k + 1
                rate = completed / (time.time() - t_start)
                remaining = len(tile_indices) - completed
                eta_min = remaining / rate / 60 if rate > 0 else 0
                print(f"  progress: {rendered} rendered, {skipped} skipped, "
                      f"{remaining} remaining, ETA {eta_min:.1f} min\n")
    else:
        # Parallel path — N workers, each pinned to one GPU. Tile-to-GPU
        # assignment via round-robin; the ThreadPoolExecutor pools available
        # workers so a fast GPU can naturally grab more tiles than a slow one
        # (since the queue feeds whoever's free).
        print(f"[parallel] launching {args.num_gpus} workers across "
              f"GPUs 0..{args.num_gpus-1}; {len(tile_indices)} tiles to render")
        with ThreadPoolExecutor(max_workers=args.num_gpus) as pool:
            # Assign each tile to a GPU id via modulo. Workers re-use their
            # CUDA context across the tiles they handle (subprocess overhead
            # is ~50 ms per launch, negligible vs ~minute-long tile renders).
            futures = {
                pool.submit(render_one_tile, tile_idx, tile_idx % args.num_gpus): tile_idx
                for tile_idx in tile_indices
            }
            completed = 0
            for fut in as_completed(futures):
                tile_idx = futures[fut]
                try:
                    _, tile_id, elapsed, did_work = fut.result()
                    if did_work:
                        rendered += 1
                    else:
                        skipped += 1
                except RuntimeError as e:
                    print(f"FATAL: tile {tile_idx} failed: {e}")
                    # Cancel pending futures so we don't continue burning GPU
                    # time on a setup that's clearly broken.
                    for f in futures:
                        f.cancel()
                    sys.exit(1)
                completed += 1
                rate = completed / (time.time() - t_start)
                remaining = len(tile_indices) - completed
                eta_min = remaining / rate / 60 if rate > 0 else 0
                with print_lock:
                    print(f"  progress: {rendered} rendered, {skipped} skipped, "
                          f"{remaining} remaining, ETA {eta_min:.1f} min")

    total_time = time.time() - t_start
    print(f"\n{'='*60}")
    print(f"DONE -- {rendered} tiles rendered, {skipped} skipped, total {total_time/60:.1f} min")
    if args.num_gpus > 1 and rendered > 0:
        # Effective speedup vs estimated serial wallclock
        est_serial_min = rendered * (args.seconds_per_tile + 10) / 60
        speedup = est_serial_min / (total_time / 60) if total_time > 0 else 0
        print(f"  multi-GPU speedup: {speedup:.2f}x ({args.num_gpus} workers, "
              f"effective {speedup/args.num_gpus*100:.0f}% of linear)")
    print(f"{'='*60}\n")

    # --- Final HF sync to catch any tiles uploaded mid-pass (atomic completion) ---
    if hf_loop_pid is not None:
        out_name = out_dir.name
        hf_url = f"hf://buckets/{args.hf_bucket}/{out_name}/"
        print(f"[hf] final foreground sync to catch any last tiles...")
        subprocess.run([
            "hf", "sync", str(out_dir.resolve()), hf_url,
            "--include", "r*c*.bin",
            "--include", "r*c*.png",
            "--include", "tile_spec.json",
        ])
        # Stop the background sync loop
        print(f"[hf] stopping background sync loop (PID {hf_loop_pid})")
        try:
            os.killpg(os.getpgid(hf_loop_pid), 15)
        except (ProcessLookupError, OSError):
            pass
        print(f"[hf] all tiles uploaded. View at https://huggingface.co/buckets/{args.hf_bucket}/{out_name}/")
        print(f"")

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
