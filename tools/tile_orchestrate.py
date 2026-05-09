"""Tile-pyramid render orchestration.

Given a canonical view + grid spec + total budget + per-tile IMap mass,
emits the full sequence of buddhabrot.exe invocations needed to render
each tile. Two phases per tile:

    Phase A (build_view_imap): build a tile-specific viewport-aware IMap
                                via --build-view-imap PATH
    Phase B (production):       full render with --imap PATH at proportional
                                sample budget

Per-tile sample allocation is proportional to that tile's IMap mass
(Neyman-style), equalizing variance across tiles. Body-cusp tile gets
more samples than filament tiles automatically.

Usage:
    python tools/tile_orchestrate.py \\
        --grid 4x4 \\
        --total-samples 1000000000000 \\
        --output-dir tiles/ \\
        --apron 256 \\
        [--canonical-view-center -0.5935417456742,0.04166264380232] \\
        [--canonical-zoom 0.5] \\
        [--rotation-deg 90] \\
        [--sample-radius 2.5] \\
        [--per-tile-width 16384 --per-tile-height 12288]

Emits a shell script `tiles/render_all.sh` that runs each tile's two phases.
"""
import argparse
import json
import os
import sys
from pathlib import Path

CANONICAL_CENTER_RE = -0.5935417456742
CANONICAL_CENTER_IM =  0.04166264380232
CANONICAL_ZOOM      =  0.5
CANONICAL_ROTATION  =  90.0
CANONICAL_SAMPLE_R  =  2.5

def parse_grid(s):
    parts = s.lower().split("x")
    if len(parts) != 2:
        raise ValueError(f"bad --grid: {s!r}")
    return int(parts[0]), int(parts[1])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grid", default="4x4", help="cols x rows, e.g. 4x4 or 2x2")
    ap.add_argument("--total-samples", type=int, default=1_000_000_000_000)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--apron", type=int, default=256, help="overlap apron in pixels (each side)")
    ap.add_argument("--canonical-view-center", default=f"{CANONICAL_CENTER_RE},{CANONICAL_CENTER_IM}")
    ap.add_argument("--canonical-zoom", type=float, default=CANONICAL_ZOOM)
    ap.add_argument("--rotation-deg", type=float, default=CANONICAL_ROTATION)
    ap.add_argument("--sample-radius", type=float, default=CANONICAL_SAMPLE_R)
    ap.add_argument("--per-tile-width", type=int, default=16384)
    ap.add_argument("--per-tile-height", type=int, default=12288)
    ap.add_argument("--imap-samples", type=int, default=1_000_000_000)
    ap.add_argument("--imap-resolution", type=int, default=1024)
    ap.add_argument("--iter-r", type=int, default=2000)
    ap.add_argument("--iter-g", type=int, default=200)
    ap.add_argument("--iter-b", type=int, default=20)
    ap.add_argument("--devices", type=int, default=1)
    ap.add_argument("--launches-per-round", type=int, default=8)
    ap.add_argument("--samples-per-thread", type=int, default=32)
    ap.add_argument("--checkpoint-every", type=int, default=0)
    ap.add_argument("--buddhabrot-bin", default="./buddhabrot")
    args = ap.parse_args()

    cols, rows = parse_grid(args.grid)
    n_tiles = cols * rows
    canonical_cx, canonical_cy = (float(x) for x in args.canonical_view_center.split(","))

    # --- Tile geometry ---
    # Canonical view: viewYSpan = 4 / 2^zoom = 4/2^0.5 = 2.828 (zoom=0.5).
    # Aspect = per_tile_w / per_tile_h.
    # In display space, canonical full image extends ±(half_w, half_h) from canonical center.
    # 4×4 grid carves display into 4 columns × 4 rows of equal cells.
    # Each tile's display center is canonical_center + cell_offset.
    # Tile shows 1/cols × 1/rows of the canonical display area at the SAME pixel
    # count → 4× sharper per linear dimension at 4×4.
    canonical_y_span = 4.0 / (2.0 ** args.canonical_zoom)
    canonical_aspect = args.per_tile_width / args.per_tile_height
    canonical_x_span = canonical_y_span * canonical_aspect

    tile_y_span = canonical_y_span / rows
    tile_x_span = canonical_x_span / cols
    # Per-tile zoom: y_span = 4 / 2^z → z = log2(4/y_span)
    import math
    tile_zoom = math.log2(4.0 / tile_y_span)

    # Tile center in DISPLAY space (post-rotation) — relative to canonical center.
    # Then rotate back to c-plane to get the tile's c-plane center.
    rot_rad = math.radians(args.rotation_deg)

    tiles = []
    for j in range(rows):
        for i in range(cols):
            # Display offset from canonical center (cell center).
            dx_display = (i - (cols - 1) / 2.0) * tile_x_span
            dy_display = (j - (rows - 1) / 2.0) * tile_y_span
            # Inverse rotation to convert display offset to c-plane offset.
            # The renderer's world_to_pixel applies rot_neg = -rotation, so
            # to go from display back to c-plane we apply +rotation.
            cos_p = math.cos(rot_rad)
            sin_p = math.sin(rot_rad)
            dx_c = cos_p * dx_display - sin_p * dy_display
            dy_c = sin_p * dx_display + cos_p * dy_display
            cell_cx = canonical_cx + dx_c
            cell_cy = canonical_cy + dy_c

            # Apron-extended pixel dimensions. Apron is in pixels, on each side.
            # We bump width/height to per_tile_+2*apron and adjust scale to keep
            # the same c-plane region per pixel.
            apron_w = args.per_tile_width  + 2 * args.apron
            apron_h = args.per_tile_height + 2 * args.apron
            # Scale up the displayed y_span to cover the apron pixels at the
            # same per-pixel c-resolution.
            apron_y_span = tile_y_span * (apron_h / args.per_tile_height)
            apron_zoom = math.log2(4.0 / apron_y_span)

            tiles.append({
                "id": f"r{j:02d}c{i:02d}",
                "i": i, "j": j,
                "center_re": cell_cx,
                "center_im": cell_cy,
                "zoom_native": tile_zoom,                # zoom for the unaprоned tile (used only for reference)
                "zoom_apron":  apron_zoom,               # actual zoom we render with (apron-extended)
                "width":  apron_w,
                "height": apron_h,
                "native_width":  args.per_tile_width,    # pixels we'll keep after stitcher trims
                "native_height": args.per_tile_height,
                "apron": args.apron,
            })

    # --- Phase 1: Build per-tile view-aware IMaps in parallel-ish ---
    # Then read back the IMap masses, compute proportional allocations.
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    spec_path = out_dir / "tile_spec.json"

    # We can't actually KNOW the IMap mass per tile without running the
    # build pre-pass first. So this orchestrator emits two scripts:
    #   render_imaps.sh    — Phase 1: build all view-aware IMaps
    #   render_tiles.sh    — Phase 2 (run AFTER Phase 1 + read mass): emit
    #                          per-tile production renders
    # The user runs render_imaps.sh, then runs `tile_orchestrate.py
    # --emit-phase2 --output-dir <dir>` to compute proportional allocations
    # and emit render_tiles.sh.

    spec = {
        "grid": [cols, rows],
        "n_tiles": n_tiles,
        "total_samples": args.total_samples,
        "canonical_view_center": [canonical_cx, canonical_cy],
        "canonical_zoom": args.canonical_zoom,
        "rotation_deg": args.rotation_deg,
        "sample_radius": args.sample_radius,
        "per_tile_width": args.per_tile_width,
        "per_tile_height": args.per_tile_height,
        "apron": args.apron,
        "imap_samples": args.imap_samples,
        "imap_resolution": args.imap_resolution,
        "iter_r": args.iter_r, "iter_g": args.iter_g, "iter_b": args.iter_b,
        "devices": args.devices,
        "launches_per_round": args.launches_per_round,
        "samples_per_thread": args.samples_per_thread,
        "checkpoint_every": args.checkpoint_every,
        "buddhabrot_bin": args.buddhabrot_bin,
        "tiles": tiles,
    }
    with open(spec_path, "w") as f:
        json.dump(spec, f, indent=2)
    print(f"wrote {spec_path}")

    # Emit render_imaps.sh: 16 invocations of --build-view-imap.
    imaps_sh = out_dir / "render_imaps.sh"
    with open(imaps_sh, "w", newline="\n") as f:
        f.write("#!/usr/bin/env bash\n")
        f.write("# Phase 1: build per-tile view-aware IMaps. Run this FIRST.\n")
        f.write("# After this completes, run:\n")
        f.write(f"#   python tools/tile_orchestrate.py --emit-phase2 --output-dir {args.output_dir}\n")
        f.write("set -euo pipefail\n")
        f.write(f'cd "$(dirname "$0")"\n\n')
        for t in tiles:
            imap_path = f"tile_{t['id']}.imap"
            f.write(f"echo '=== Phase 1: tile {t['id']} ==='\n")
            f.write(f"{args.buddhabrot_bin} \\\n")
            f.write(f"    --build-view-imap {imap_path} \\\n")
            f.write(f"    --imap-samples {args.imap_samples} \\\n")
            f.write(f"    --imap-resolution {args.imap_resolution} \\\n")
            f.write(f"    --width {t['width']} --height {t['height']} \\\n")
            f.write(f"    --view-center-x {t['center_re']:.16f} \\\n")
            f.write(f"    --view-center-y {t['center_im']:.16f} \\\n")
            f.write(f"    --zoom {t['zoom_apron']:.10f} \\\n")
            f.write(f"    --rotation-deg {args.rotation_deg} \\\n")
            f.write(f"    --sample-radius {args.sample_radius} \\\n")
            f.write(f"    --iter-r {args.iter_r} --iter-g {args.iter_g} --iter-b {args.iter_b} \\\n")
            # MANDATORY samples-per-thread=8 for Windows TDR avoidance.
            # IMap build kernel does count_iterations + orbit replay per sample;
            # 4096*256*1024 = 1B samples/launch at ~7.5 M/s = 134 sec, well over
            # the 2-sec Windows TDR cap. samples-per-thread=8 caps per-launch
            # at ~1 sec, well under TDR. See CLAUDE.md B11.
            f.write(f"    --samples-per-thread 8 \\\n")
            f.write(f"    --devices {args.devices}\n\n")
    print(f"wrote {imaps_sh}")
    print(f"\nNext step:")
    print(f"  cd {args.output_dir} && bash render_imaps.sh")
    print(f"  python tools/tile_orchestrate.py --emit-phase2 --output-dir {args.output_dir}")
    print(f"  cd {args.output_dir} && bash render_tiles.sh")

if __name__ == "__main__":
    # Crude --emit-phase2 dispatch
    if "--emit-phase2" in sys.argv:
        sys.argv.remove("--emit-phase2")
        ap = argparse.ArgumentParser()
        ap.add_argument("--output-dir", required=True)
        args = ap.parse_args()
        out_dir = Path(args.output_dir)
        spec_path = out_dir / "tile_spec.json"
        with open(spec_path) as f:
            spec = json.load(f)
        # Read each tile's IMap, compute total mass.
        import struct
        tile_masses = []
        for t in spec["tiles"]:
            imap_file = out_dir / f"tile_{t['id']}.imap"
            with open(imap_file, "rb") as fh:
                # IMap format from main.cu: 40-byte header + N*N uint32
                header = fh.read(40)
                # Parse total_mass field — exact offset depends on imap format.
                # Per the offline kernel, header is:
                #   magic(8) version(4) cells_x(4) cells_y(4) sample_cx(8 double?) ...
                # Easiest: read all uint32 cells and sum.
                cells_data = fh.read()
            n_cells = spec["imap_resolution"] ** 2
            cells = struct.unpack(f"<{n_cells}I", cells_data[:n_cells*4])
            mass = sum(cells)
            tile_masses.append(mass)
            print(f"  tile {t['id']}: mass = {mass:,}")
        total_mass = sum(tile_masses)
        if total_mass == 0:
            print("ERROR: all tiles have zero mass")
            sys.exit(1)
        # Proportional allocation
        per_tile_samples = []
        for t, m in zip(spec["tiles"], tile_masses):
            frac = m / total_mass
            per_tile_samples.append(int(spec["total_samples"] * frac))
        print(f"\nTotal mass: {total_mass:,}")
        print(f"Sample allocation (proportional to mass):")
        for t, s, m in zip(spec["tiles"], per_tile_samples, tile_masses):
            print(f"  tile {t['id']}: {s:>15,d} samples ({100*m/total_mass:.1f}%)")

        # Emit render_tiles.sh
        render_sh = out_dir / "render_tiles.sh"
        with open(render_sh, "w", newline="\n") as f:
            f.write("#!/usr/bin/env bash\n")
            f.write("# Phase 2: production tile renders with proportional allocation.\n")
            f.write("set -euo pipefail\n")
            f.write(f'cd "$(dirname "$0")"\n\n')
            for t, s in zip(spec["tiles"], per_tile_samples):
                imap_path = f"tile_{t['id']}.imap"
                out_png   = f"tile_{t['id']}.png"
                f.write(f"echo '=== Phase 2: tile {t['id']} ({s:,} samples) ==='\n")
                f.write(f"{spec['buddhabrot_bin']} \\\n")
                f.write(f"    --imap {imap_path} \\\n")
                f.write(f"    --samples {s} \\\n")
                f.write(f"    --width {t['width']} --height {t['height']} \\\n")
                f.write(f"    --view-center-x {t['center_re']:.16f} \\\n")
                f.write(f"    --view-center-y {t['center_im']:.16f} \\\n")
                f.write(f"    --zoom {t['zoom_apron']:.10f} \\\n")
                f.write(f"    --rotation-deg {spec['rotation_deg']} \\\n")
                f.write(f"    --sample-radius {spec['sample_radius']} \\\n")
                f.write(f"    --iter-r {spec['iter_r']} --iter-g {spec['iter_g']} --iter-b {spec['iter_b']} \\\n")
                f.write(f"    --devices {spec['devices']} \\\n")
                f.write(f"    --launches-per-round {spec['launches_per_round']} \\\n")
                f.write(f"    --samples-per-thread {spec['samples_per_thread']} \\\n")
                f.write(f"    --output {out_png}\n\n")
        print(f"\nwrote {render_sh}")
        print(f"Next: cd {args.output_dir} && bash render_tiles.sh")
    else:
        main()
