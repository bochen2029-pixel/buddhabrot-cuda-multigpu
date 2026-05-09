"""Compose tile TIFFs (apron-retained) into a single composite with linear
alpha-crossfade across overlap regions. Use with stitcher's --keep-apron mode.

Linear crossfade math:
  Each tile is rendered with apron px of overlap on every side.
  Adjacent tiles share a 2*apron-pixel-wide overlap stripe.
  Within the overlap, linear weight: w_left = (apron + d_from_seam) / (2*apron),
  w_right = 1 - w_left, where d_from_seam ∈ [-apron, +apron].
  Composite pixel = w_left * left_pixel + w_right * right_pixel.

Composes physically uncorrelated noise floors into a smooth gradient,
masking the variance-seam discontinuity that would otherwise be visible
where independent RNG streams from different tiles meet.

Usage:
  python tools/compose_blended.py \\
      --stitched-dir stitched/ \\
      --output composite.tif

Requires apron-retained TIFFs (run stitch_tiles.py with --keep-apron).
"""
import argparse
import json
from pathlib import Path
import numpy as np
import tifffile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stitched-dir", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    sdir = Path(args.stitched_dir)
    meta = json.loads((sdir / "stitch_meta.json").read_text())
    if not meta.get("keep_apron", False):
        print("ERROR: stitch_meta says aprons NOT retained. Re-run stitch_tiles.py with --keep-apron.")
        return

    cols, rows = meta["grid"]
    apron = meta["apron"]
    nw = meta["per_tile_width"]
    nh = meta["per_tile_height"]
    tile_w_full = nw + 2 * apron
    tile_h_full = nh + 2 * apron

    out_w = cols * nw
    out_h = rows * nh
    print(f"composite: {out_w} × {out_h}, apron={apron}, tile_full={tile_w_full}×{tile_h_full}")
    print(f"crossfade region: {2*apron} px wide at each interior seam")

    # Allocate the composite as float64 weighted accumulator + alpha sum.
    # Each pixel: composite[y,x] = sum_i (alpha_i * tile_i_pixel) / sum_i alpha_i
    accum = np.zeros((out_h, out_w, 3), dtype=np.float64)
    alpha = np.zeros((out_h, out_w), dtype=np.float64)

    # Load tiles, compute per-pixel alpha mask (tapered apron, full inside).
    # Mask shape (tile_h_full, tile_w_full), values in [0,1]:
    #   1.0 inside the native region (apron..apron+nh, apron..apron+nw)
    #   linear ramp from 0→1 across the apron on each side
    def make_alpha(h, w, apron, has_left, has_right, has_top, has_bot):
        m = np.ones((h, w), dtype=np.float64)
        # Linear ramp on each side present (i.e., each side that has a neighbor).
        ramp = np.linspace(0.0, 1.0, apron, endpoint=False) + (1.0 / apron) * 0.5
        if has_left:
            m[:, :apron] *= ramp[None, :]
        if has_right:
            m[:, w-apron:] *= ramp[None, ::-1]
        if has_top:
            m[:apron, :] *= ramp[:, None]
        if has_bot:
            m[h-apron:, :] *= ramp[::-1, None]
        return m

    for t in meta["tiles"]:
        i, j = t["i"], t["j"]
        tif_path = sdir / t["tif"]
        img = tifffile.imread(tif_path)
        if img.shape != (tile_h_full, tile_w_full, 3):
            print(f"WARN: {tif_path} shape {img.shape} != expected ({tile_h_full},{tile_w_full},3)")
        a = make_alpha(tile_h_full, tile_w_full, apron,
                       has_left  = (i > 0),
                       has_right = (i < cols - 1),
                       has_top   = (j > 0),
                       has_bot   = (j < rows - 1))
        # Tile placement in composite: tile (i,j) covers
        # composite[j*nh : j*nh+nh, i*nw : i*nw+nw] in NATIVE coords;
        # the apron ext of size 2*apron straddles the boundary.
        x0 = i * nw - apron
        y0 = j * nh - apron
        # Bounds check + clamp to composite extent
        cx0 = max(x0, 0); cx1 = min(x0 + tile_w_full, out_w)
        cy0 = max(y0, 0); cy1 = min(y0 + tile_h_full, out_h)
        tx0 = cx0 - x0;   tx1 = tx0 + (cx1 - cx0)
        ty0 = cy0 - y0;   ty1 = ty0 + (cy1 - cy0)
        # weighted accumulation
        sub_img = img[ty0:ty1, tx0:tx1, :].astype(np.float64)
        sub_a   = a  [ty0:ty1, tx0:tx1]
        accum[cy0:cy1, cx0:cx1, :] += sub_img * sub_a[:, :, None]
        alpha[cy0:cy1, cx0:cx1]    += sub_a
        print(f"  blended tile ({i},{j}) at composite [{cx0}:{cx1}, {cy0}:{cy1}]")

    # Normalize accumulated values by alpha sum.
    alpha_safe = np.where(alpha > 1e-9, alpha, 1.0)
    composite = (accum / alpha_safe[:, :, None]).clip(0, 65535).astype(np.uint16)
    tifffile.imwrite(args.output, composite, photometric="rgb")
    print(f"\nwrote {args.output} ({out_w}×{out_h}, 16-bit RGB)")


if __name__ == "__main__":
    main()
