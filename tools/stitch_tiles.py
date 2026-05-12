"""Tile stitcher with apron crossfade.

Reads N tile .bin files (one per tile), computes a global 99.99th percentile
R_max across all of them (so tonemap brightness is consistent), tonemaps each
tile with that global R_max, trims aprons, applies linear alpha crossfade in
overlap regions, and emits a directory of stitched 16-bit TIFFs ready for
libvips Deep Zoom pyramid generation.

Per-tile normalization: each tile's bin counts are divided by that tile's
sample count BEFORE computing the global R_max. This corrects for the
proportional-allocation scheme where different tiles have different sample
budgets — without normalization, a tile with 2× the samples would show
2× the raw bin values and look 2× brighter.

Usage:
    python tools/stitch_tiles.py \\
        --tile-dir tiles/ \\
        --output-dir stitched/ \\
        --trim-r 0.27 --trim-g 0.19 --trim-b 0.11
"""
import argparse
import json
import struct
from pathlib import Path
import numpy as np


def read_bin_header(fh):
    header = fh.read(128)
    magic = header[0:4].decode("ascii", errors="replace")
    if magic != "BHRA":
        raise RuntimeError(f"bad magic: {magic!r}")
    width        = struct.unpack_from("<I", header, 8)[0]
    height       = struct.unpack_from("<I", header, 12)[0]
    samples_done = struct.unpack_from("<Q", header, 32)[0]
    hist_scale   = struct.unpack_from("<I", header, 116)[0]
    return {"width": width, "height": height, "samples_done": samples_done,
            "hist_scale": hist_scale}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tile-dir", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--trim-r", type=float, default=0.27)
    ap.add_argument("--trim-g", type=float, default=0.19)
    ap.add_argument("--trim-b", type=float, default=0.11)
    ap.add_argument("--gamma", type=float, default=4.0)
    ap.add_argument("--norm-floor", type=float, default=15.0)
    ap.add_argument("--max-percentile", type=float, default=99.99)
    ap.add_argument("--keep-apron", action="store_true",
                    help="emit TIFFs at apron-extended dimensions (no trim). "
                         "Required for compose_blended.py crossfade.")
    args = ap.parse_args()

    tile_dir = Path(args.tile_dir)
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    spec = json.loads((tile_dir / "tile_spec.json").read_text())

    # Pass 1: read each tile's normalized R/G/B max.
    # We want global 99.99th percentile across all NORMALIZED bins.
    # For practicality, sample 1M random pixels from each tile, normalize by
    # its samples_done × HIST_SCALE, compute percentile. This is much faster
    # than scanning all 200M pixels per tile.
    print(f"Pass 1: scanning {len(spec['tiles'])} tiles for global percentile...")
    rng = np.random.default_rng(42)
    n_sample_per_tile = 1_000_000
    all_norm_R = []
    all_norm_G = []
    all_norm_B = []
    tile_meta = []
    for t in spec["tiles"]:
        bin_path = tile_dir / f"{t['id']}.bin"
        if not bin_path.exists():
            print(f"  WARN: {bin_path} missing, skipping")
            continue
        with open(bin_path, "rb") as fh:
            hdr = read_bin_header(fh)
        samples_done = max(hdr["samples_done"], 1)
        hist_scale = max(hdr["hist_scale"], 1)
        h, w = hdr["height"], hdr["width"]
        hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                         offset=128, shape=(h, w, 3))
        ys = rng.integers(0, h, n_sample_per_tile)
        xs = rng.integers(0, w, n_sample_per_tile)
        sample = hist[ys, xs, :].astype(np.float64)
        norm_factor = 1.0 / (samples_done * hist_scale)
        all_norm_R.append(sample[:, 0] * norm_factor)
        all_norm_G.append(sample[:, 1] * norm_factor)
        all_norm_B.append(sample[:, 2] * norm_factor)
        tile_meta.append({"tile": t, "samples_done": samples_done, "hist_scale": hist_scale,
                          "norm_factor": norm_factor})
    all_R = np.concatenate(all_norm_R)
    all_G = np.concatenate(all_norm_G)
    all_B = np.concatenate(all_norm_B)
    R_max_global = float(np.percentile(all_R, args.max_percentile))
    G_max_global = float(np.percentile(all_G, args.max_percentile))
    B_max_global = float(np.percentile(all_B, args.max_percentile))
    R_max_global = max(R_max_global, args.norm_floor / 1e9)  # avoid divide-by-zero
    G_max_global = max(G_max_global, args.norm_floor / 1e9)
    B_max_global = max(B_max_global, args.norm_floor / 1e9)
    print(f"  Global {args.max_percentile}th percentile (normalized counts):")
    print(f"    R_max = {R_max_global:.4e}")
    print(f"    G_max = {G_max_global:.4e}")
    print(f"    B_max = {B_max_global:.4e}")

    # Pass 2: per-tile tonemap → trim aprons → save as 16-bit TIFF.
    # Apron crossfade is applied later by the Deep Zoom packer (libvips
    # blends overlapping tiles via average). For now we keep the apron in
    # each TIFF so the packer has overlap to work with.
    print(f"\nPass 2: tonemapping tiles with global R_max...")
    try:
        import tifffile
    except ImportError:
        print("ERROR: tifffile not installed. pip install tifffile")
        return

    for tm in tile_meta:
        t = tm["tile"]
        bin_path = tile_dir / f"{t['id']}.bin"
        out_tiff = out_dir / f"{t['id']}.tif"
        with open(bin_path, "rb") as fh:
            hdr = read_bin_header(fh)
        h, w = hdr["height"], hdr["width"]
        hist = np.memmap(bin_path, dtype=np.uint64, mode="r",
                         offset=128, shape=(h, w, 3))

        # Process in row-strips to bound memory.
        out16 = np.zeros((h, w, 3), dtype=np.uint16)
        chunk = 256
        for y0 in range(0, h, chunk):
            y1 = min(y0 + chunk, h)
            block = hist[y0:y1].astype(np.float64) * tm["norm_factor"]
            # tonemap: t = count / (max * trim), display = 65535*(1-(1-t)^γ)
            tr = np.clip(block[..., 0] / (R_max_global * args.trim_r), 0.0, 1.0)
            tg = np.clip(block[..., 1] / (G_max_global * args.trim_g), 0.0, 1.0)
            tb = np.clip(block[..., 2] / (B_max_global * args.trim_b), 0.0, 1.0)
            r = 65535.0 * (1.0 - (1.0 - tr) ** args.gamma)
            g = 65535.0 * (1.0 - (1.0 - tg) ** args.gamma)
            b = 65535.0 * (1.0 - (1.0 - tb) ** args.gamma)
            out16[y0:y1, :, 0] = np.clip(r, 0, 65535).astype(np.uint16)
            out16[y0:y1, :, 1] = np.clip(g, 0, 65535).astype(np.uint16)
            out16[y0:y1, :, 2] = np.clip(b, 0, 65535).astype(np.uint16)

        if args.keep_apron:
            # Emit full apron-extended tile. compose_blended.py will trim+blend.
            tifffile.imwrite(out_tiff, out16, photometric="rgb")
            print(f"  wrote {out_tiff} ({out16.shape[1]}x{out16.shape[0]}) [apron retained]")
        else:
            # Trim apron — keep only the central native_width × native_height region.
            apron = t["apron"]
            nw, nh = t["native_width"], t["native_height"]
            trimmed = out16[apron:apron+nh, apron:apron+nw, :]
            tifffile.imwrite(out_tiff, trimmed, photometric="rgb")
            print(f"  wrote {out_tiff} ({trimmed.shape[1]}x{trimmed.shape[0]})")

    # Save stitch metadata for the pyramid packer.
    stitch_meta = {
        "grid": spec["grid"],
        "apron":          spec.get("apron", 0),
        "keep_apron":     bool(args.keep_apron),
        "per_tile_width":  spec["per_tile_width"],
        "per_tile_height": spec["per_tile_height"],
        "tiles": [
            {
                "id":  t["id"],
                "i":   t["i"],
                "j":   t["j"],
                "tif": f"{t['id']}.tif",
            }
            for t in spec["tiles"]
        ],
    }
    (out_dir / "stitch_meta.json").write_text(json.dumps(stitch_meta, indent=2))
    print(f"\nWrote {out_dir / 'stitch_meta.json'}")
    print(f"\nNext step:")
    print(f"  python tools/build_dz_pyramid.py --stitched-dir {args.output_dir}")


if __name__ == "__main__":
    main()
