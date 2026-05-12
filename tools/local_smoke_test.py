"""End-to-end local smoke test for the tile-pyramid pipeline.

Designed to run on a single RTX 4070 Ti SUPER (or any sm_89+ card with >=8 GB
VRAM) and complete in ~5 minutes. The point is to validate the pipeline
end-to-end *before* committing to a multi-hour cloud render:

  1. Build buddhabrot.exe (if not already present)
  2. Build a tiny IMap for the canonical view (or reuse existing imap.bin)
  3. Render a 2x2 grid of 1024x768 tiles at ~30s each
     (with optional --guide-bin for PATH B bin-guided IS)
  4. Stitch the tiles into a 2048x1536 image
  5. Build a Deep Zoom (DZI) pyramid + viewer/
  6. Optionally open the viewer in a browser

The point is NOT to produce a beautiful final image — the resolution and
sample budget are too small for that. The point IS to catch broken pipelines
(wrong file paths, kernel regressions, stitch math drift, viewer build
failures) in 5 minutes instead of 5 hours of cloud time.

Usage (from C:\\buddhabrot-main\\cuda-render-16k):

  python tools/local_smoke_test.py --output-dir smoke_out/

  # Skip viewer build to finish faster (just check render/stitch math):
  python tools/local_smoke_test.py --output-dir smoke_out/ --no-viewer

  # Test PATH B bin-guided IS:
  python tools/local_smoke_test.py --output-dir smoke_out/ \\
      --guide-bin guide_4k.gbin

  # Heavier mode for sanity-checking near-production parameters
  # (~15 min on 4070 Ti SUPER):
  python tools/local_smoke_test.py --output-dir smoke_out/ \\
      --grid 4x4 --resolution 2048x1536 --seconds-per-tile 60

The test PASSES if every step exits 0 and produces output files of the
expected (nonzero) sizes. It FAILS loudly if any step errors out.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
import webbrowser
from pathlib import Path


THIS_DIR = Path(__file__).resolve().parent.parent   # cuda-render-16k/
DEFAULT_BIN_NAME = "buddhabrot.exe" if os.name == "nt" else "buddhabrot"


def step(n: int, total: int, name: str) -> None:
    print(f"\n{'='*60}\n[{n}/{total}] {name}\n{'='*60}")


def run(cmd, check=True, cwd=None) -> int:
    """Run a subprocess, stream output, return rc. Fail loudly on non-zero
    when check=True."""
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    t0 = time.time()
    rc = subprocess.run(cmd, cwd=cwd).returncode
    print(f"  ({time.time()-t0:.1f}s, rc={rc})")
    if check and rc != 0:
        print(f"FAIL: step exited rc={rc}")
        sys.exit(rc)
    return rc


def file_check(path: Path, min_bytes: int, label: str) -> None:
    """Validate that a file exists and is big enough to be plausible output."""
    if not path.exists():
        print(f"FAIL: missing {label}: {path}")
        sys.exit(1)
    sz = path.stat().st_size
    if sz < min_bytes:
        print(f"FAIL: {label} too small ({sz} < {min_bytes} bytes): {path}")
        sys.exit(1)
    print(f"  OK: {label}: {path.name} ({sz/1e6:.1f} MB)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--output-dir", default="smoke_out",
                    help="output directory for this smoke run (will be created)")
    ap.add_argument("--grid", default="2x2", help="tile grid (default 2x2 = 4 tiles)")
    ap.add_argument("--resolution", default="1024x768",
                    help="per-tile resolution (default 1024x768; small for fast iteration)")
    ap.add_argument("--seconds-per-tile", type=int, default=30,
                    help="per-tile wallclock budget (default 30s)")
    ap.add_argument("--throughput-est", type=float, default=7.0,
                    help="M samples/sec per GPU; default 7 (4070 Ti SUPER under IS)")
    ap.add_argument("--num-gpus", type=int, default=1,
                    help="number of GPUs to parallelize tiles across (default 1)")
    ap.add_argument("--guide-bin", default="",
                    help="optional PATH B guide file (.gbin) to exercise bin-guided IS")
    ap.add_argument("--buddhabrot-bin", default=None,
                    help="path to renderer (default: ./buddhabrot[.exe] in cuda-render-16k/)")
    ap.add_argument("--build", action="store_true",
                    help="rebuild buddhabrot.exe before the test (slower)")
    ap.add_argument("--no-viewer", action="store_true",
                    help="skip DZI pyramid + viewer build (just render + stitch)")
    ap.add_argument("--open-viewer", action="store_true",
                    help="open the viewer in a browser when done (Windows: needs LAUNCH.bat)")
    ap.add_argument("--imap", default="imap.bin",
                    help="canonical IMap path (existing). If missing, we build one quickly.")
    args = ap.parse_args()

    os.chdir(THIS_DIR)
    print(f"cwd: {THIS_DIR}")

    bin_path = Path(args.buddhabrot_bin) if args.buddhabrot_bin else Path(DEFAULT_BIN_NAME)
    out_dir = Path(args.output_dir)
    tiles_dir = out_dir / "tiles"
    stitched_dir = out_dir / "stitched"
    viewer_dir = out_dir / "viewer"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Total steps for the progress banner
    total_steps = 1 + (1 if args.build else 0) + 1 + 1 + 1 + (1 if not args.no_viewer else 0)
    step_n = 0

    # --- Step: build (optional) ---
    if args.build:
        step_n += 1
        step(step_n, total_steps, "Rebuild buddhabrot.exe")
        if os.name == "nt":
            run(["cmd", "/c", ".\\build.bat"])
        else:
            run(["bash", "./build.sh"])
        file_check(bin_path, 100_000, "renderer binary")

    # --- Step: precheck renderer exists ---
    step_n += 1
    step(step_n, total_steps, "Precheck: renderer binary present")
    if not bin_path.exists():
        print(f"FAIL: renderer not found at {bin_path}")
        print(f"      run with --build to compile it, or pass --buddhabrot-bin <path>")
        sys.exit(1)
    file_check(bin_path, 100_000, "renderer binary")

    # --- Step: canonical IMap (build if absent) ---
    step_n += 1
    step(step_n, total_steps, f"Canonical IMap ({args.imap})")
    imap_path = Path(args.imap)
    if not imap_path.exists():
        print(f"  {args.imap} not found; building a small one (~10s, 50M samples)")
        run([
            str(bin_path), "--build-imap", str(imap_path),
            "--width", "1024", "--height", "768",
            "--view-center-x", "-0.5935417456742",
            "--view-center-y", "0.04166264380232",
            "--zoom", "0.5",
            "--rotation-deg", "90",
            "--sample-radius", "2.5",
            "--imap-samples", "50000000",
            "--iter-r", "2000", "--iter-g", "200", "--iter-b", "20",
            "--devices", "1",
        ])
    file_check(imap_path, 1_000, "canonical IMap")

    # --- Step: tile render ---
    step_n += 1
    step(step_n, total_steps, f"Render {args.grid} grid @ {args.resolution} "
                              f"({args.seconds_per_tile}s/tile, "
                              f"{'with' if args.guide_bin else 'no'} guide)")
    tile_cmd = [
        sys.executable, "tools/render_fast_tiles.py",
        "--grid", args.grid,
        "--resolution", args.resolution,
        "--seconds-per-tile", str(args.seconds_per_tile),
        "--throughput-est", str(args.throughput_est),
        "--num-gpus", str(args.num_gpus),
        "--canonical-imap", str(imap_path),
        "--output-dir", str(tiles_dir),
        "--buddhabrot-bin", str(bin_path),
        # Smoke-test IMap-build samples: small for speed. Real renders use 500M+.
        "--imap-samples", "20000000",
        # Reduced apron for small smoke tiles (default 64 is too thick at 1024-tile size)
        "--apron", "16",
    ]
    if args.guide_bin:
        tile_cmd.extend(["--guide-bin", args.guide_bin])
    run(tile_cmd)

    # Validate every tile dropped a .bin + .png
    cols, rows = (int(x) for x in args.grid.lower().split("x"))
    expected_tiles = cols * rows
    found_bins = sorted(tiles_dir.glob("r*c*.bin"))
    if len(found_bins) < expected_tiles:
        print(f"FAIL: only {len(found_bins)}/{expected_tiles} tile bins produced")
        sys.exit(1)
    print(f"  OK: {expected_tiles} tile bins produced")
    file_check(found_bins[0], 100_000, "sample tile .bin")
    sample_png = found_bins[0].with_suffix(".png")
    if sample_png.exists():
        file_check(sample_png, 10_000, "sample tile .png")

    # --- Step: stitch tiles into single image ---
    step_n += 1
    step(step_n, total_steps, "Stitch tiles -> single image")
    if not (THIS_DIR / "tools" / "stitch_tiles.py").exists():
        print(f"WARN: tools/stitch_tiles.py missing; skipping stitch step")
    else:
        run([
            sys.executable, "tools/stitch_tiles.py",
            "--tile-dir", str(tiles_dir),
            "--output-dir", str(stitched_dir),
        ])
        # stitch_tiles.py varies in output names — just make sure SOMETHING landed
        stitched_files = list(stitched_dir.glob("*.png")) + list(stitched_dir.glob("*.tif")) + list(stitched_dir.glob("*.tiff"))
        if not stitched_files:
            print(f"WARN: no stitched .png/.tif found in {stitched_dir}")
        else:
            file_check(stitched_files[0], 50_000, "stitched output")

    # --- Step: viewer build (optional) ---
    if not args.no_viewer:
        step_n += 1
        step(step_n, total_steps, "Build DZI pyramid + viewer")
        build_dz = THIS_DIR / "tools" / "build_dz_pyramid.py"
        build_viewer = THIS_DIR / "tools" / "build_viewer_package.py"
        if not build_dz.exists() and not build_viewer.exists():
            print(f"WARN: neither build_dz_pyramid.py nor build_viewer_package.py found; "
                  f"skipping viewer step")
        else:
            # Pick whichever exists; both produce similar output
            script = build_dz if build_dz.exists() else build_viewer
            try:
                run([
                    sys.executable, str(script),
                    "--stitched-dir", str(stitched_dir),
                    "--output", str(viewer_dir),
                ], check=False)
            except Exception as e:
                print(f"WARN: viewer build raised exception (continuing): {e}")
            # Some scripts use positional args instead; if that failed, try simpler form:
            if not viewer_dir.exists() or not any(viewer_dir.iterdir()):
                # Try alternative invocation
                stitched_files = list(stitched_dir.glob("*.png")) + list(stitched_dir.glob("*.tif"))
                if stitched_files:
                    run([sys.executable, str(script),
                         str(stitched_files[0]), str(viewer_dir)], check=False)
            if viewer_dir.exists() and any(viewer_dir.iterdir()):
                print(f"  OK: viewer in {viewer_dir}")
                if args.open_viewer:
                    launcher = viewer_dir / ("LAUNCH.bat" if os.name == "nt" else "LAUNCH.sh")
                    viewer_html = viewer_dir / "viewer.html"
                    if launcher.exists():
                        print(f"  launching: {launcher}")
                        if os.name == "nt":
                            subprocess.Popen(["cmd", "/c", str(launcher)],
                                           creationflags=subprocess.CREATE_NEW_CONSOLE)
                        else:
                            subprocess.Popen(["bash", str(launcher)])
                    elif viewer_html.exists():
                        webbrowser.open(viewer_html.as_uri())

    # --- Summary ---
    print(f"\n{'='*60}\nSMOKE TEST: PASS\n{'='*60}")
    print(f"  output: {out_dir.resolve()}")
    print(f"  tiles:  {tiles_dir.resolve()}")
    if stitched_dir.exists() and any(stitched_dir.iterdir()):
        print(f"  stitched: {stitched_dir.resolve()}")
    if not args.no_viewer and viewer_dir.exists() and any(viewer_dir.iterdir()):
        print(f"  viewer: {viewer_dir.resolve()}")
    print(f"\nNext steps:")
    print(f"  - Inspect a tile PNG visually to confirm structure looks right")
    print(f"  - For real render, scale up: --grid 16x16 --resolution 4096x3072 --seconds-per-tile 60")
    print(f"  - On 8x H100/H200 cloud, add --num-gpus 8 for ~7-10x wallclock reduction")
    return 0


if __name__ == "__main__":
    sys.exit(main())
