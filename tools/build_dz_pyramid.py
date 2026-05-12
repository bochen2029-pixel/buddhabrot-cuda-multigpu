"""Build a Deep Zoom pyramid (.dzi) from per-tile TIFFs using libvips.

Composes the N tile TIFFs into one big virtual image via vips.arrayjoin,
then dzsave to produce the .dzi pyramid. libvips streams data through
demand-paged operations so the giant intermediate is never materialized.

Requires: pyvips (pip install pyvips) — needs libvips installed on the system.
On Windows: download libvips dev binary from libvips.github.io, add bin/ to PATH.
On Linux: apt install libvips-dev or brew install vips.

Usage:
    python tools/build_dz_pyramid.py --stitched-dir stitched/ --output buddhabrot_64k
"""
import argparse
import json
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stitched-dir", required=False,
                    help="directory of per-tile TIFFs + stitch_meta.json (default mode)")
    ap.add_argument("--composite-tif", required=False,
                    help="alternative: path to a SINGLE pre-blended composite TIFF "
                         "(output of compose_blended.py). Skips the arrayjoin step.")
    ap.add_argument("--output", default="buddhabrot_64k",
                    help="output prefix; produces <prefix>.dzi + <prefix>_files/")
    ap.add_argument("--tile-size", type=int, default=256, help="DZI tile size")
    ap.add_argument("--overlap", type=int, default=0, help="DZI tile overlap (0 typical)")
    ap.add_argument("--quality", type=int, default=85, help="JPEG quality for DZI tiles")
    ap.add_argument("--format", default="jpg", choices=["jpg", "png", "webp"])
    args = ap.parse_args()

    if not args.stitched_dir and not args.composite_tif:
        ap.error("Must provide either --stitched-dir OR --composite-tif")

    try:
        import pyvips
    except ImportError:
        print("ERROR: pyvips not installed. Run: pip install pyvips")
        print("Also requires libvips system library:")
        print("  Linux:   apt install libvips-dev")
        print("  macOS:   brew install vips")
        print("  Windows: download from libvips.github.io, add bin/ to PATH")
        return

    # Two input modes: pre-blended single TIFF or per-tile TIFFs + arrayjoin.
    if args.composite_tif:
        # Single-composite mode — input is one big TIFF from compose_blended.py.
        # libvips streams through it for dzsave without materializing the full image.
        print(f"Loading single composite TIFF: {args.composite_tif}")
        composite = pyvips.Image.new_from_file(args.composite_tif, access="sequential")
    else:
        # Multi-tile mode — arrayjoin per-tile TIFFs (legacy path; NO blending).
        # Use --composite-tif from compose_blended.py output for blended seams.
        stitched_dir = Path(args.stitched_dir)
        meta = json.loads((stitched_dir / "stitch_meta.json").read_text())
        cols, rows = meta["grid"]
        n = cols * rows
        if meta.get("keep_apron", False):
            print("WARN: stitch_meta.json says keep_apron=true. This pyramid will include")
            print("      the aprons (visible doubled overlap regions). For a seamless output,")
            print("      run compose_blended.py first then pass --composite-tif here.")

        # Load N tiles in row-major order (j*cols + i).
        tile_imgs = {}
        for t in meta["tiles"]:
            tif_path = stitched_dir / t["tif"]
            if not tif_path.exists():
                raise RuntimeError(f"missing {tif_path}")
            img = pyvips.Image.new_from_file(str(tif_path), access="sequential")
            tile_imgs[(t["i"], t["j"])] = img

        # Compose row-by-row.
        rows_imgs = []
        for j in range(rows):
            row_imgs = [tile_imgs[(i, j)] for i in range(cols)]
            # arrayjoin horizontally
            rows_imgs.append(pyvips.Image.arrayjoin(row_imgs, across=len(row_imgs)))
        composite = pyvips.Image.arrayjoin(rows_imgs, across=1)

    print(f"Composite size: {composite.width} × {composite.height}, {composite.bands} bands, {composite.format}")

    # dzsave: builds the multi-resolution pyramid + tile folder.
    print(f"Generating Deep Zoom pyramid: {args.output}.dzi + {args.output}_files/")
    composite.dzsave(
        args.output,
        suffix=f".{args.format}[Q={args.quality}]",
        tile_size=args.tile_size,
        overlap=args.overlap,
    )
    print(f"\nDone. Open {args.output}.dzi in OpenSeadragon:")
    print(f"  https://openseadragon.github.io/")
    print(f"  var viewer = OpenSeadragon({{")
    print(f"      tileSources: '{args.output}.dzi',")
    print(f"      prefixUrl: '...openseadragon/images/'")
    print(f"  }});")


if __name__ == "__main__":
    main()
