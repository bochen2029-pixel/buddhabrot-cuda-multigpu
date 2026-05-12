# Bin-guided fast-tile pyramid architecture

**Status:** Production, validated end-to-end (2026-05-12). Bin-guided per-tile rendering with full corrected pipeline (classification + weight floor + apron crossfade). Reusable guide hierarchy permanently archived on HF.

---

## TL;DR

A monolithic 32K or 64K Buddhabrot render spreads samples uniformly across all pixels, hitting a per-pixel-density wall regardless of total resolution. A **per-tile rendering** approach with a **bin-guided importance map** beats it by 2-3× per-pixel sharpness at the same wallclock, and runs **~24× faster per atomic-add** due to L2 cache fit. This document captures the architecture, the four insights that make it work, and the toolchain.

The full corrected pipeline produces a seamless OpenSeadragon-ready tile pyramid in ~1.5 hours on an H100 PCIe, with output that's measurably sharper than a 32K monolithic render that took 24 hours.

---

## Why monolithic hits a wall

Three compounding factors limit monolithic Buddhabrot rendering past 32K:

| Factor | Mechanism |
|---|---|
| **Atomic contention** | 19 GB histogram (32K × 24K × 3 × uint64) doesn't fit in any cache. Every `atomicAdd(uint64)` bounces to HBM3 with ~400 cycle latency. Throughput caps around 11-12 M/s on H100. |
| **Sample dilution** | At 24h wallclock = 920 B samples / 800 Mpx = 1140 traj/px native — sounds reasonable, but heavy-tailed orbit distribution means filament pixels see far fewer effective samples than the average suggests. |
| **No focus** | Every sample is treated equally regardless of where its orbit lands. Bright-region pixels and noise-floor pixels get the same sample budget. |

The result: you can throw 24 hours of H100 at 32K and still see visible Monte Carlo noise when you deep-zoom. Going to 64K monolithic spreads the SAME samples across 4× more pixels — empty resolution, not detail.

---

## The four architectural insights

### 1. Per-tile L2 cache locality (the real reason this works)

When the histogram fits in L2 cache (50 MB on H100), atomic adds resolve in cache instead of HBM. **4K tiles produce a ~19 MB stride-relevant working set that's L2-resident**, vs a 32K monolithic's 19 GB that thrashes the cache 100% of the time.

Measured throughput on H100 PCIe:

| Workload | Throughput | Bottleneck |
|---|---|---|
| 32K monolithic IS | 11-12 M/s | HBM atomic latency |
| 8x8 = 64 tiles @ 4K each | ~50 M/s/tile aggregate | Some cache misses |
| **16x16 = 256 tiles @ 4K each** | **262 M/s/tile aggregate** | **L2 hot working set** |

**22× speedup from the same kernel, just smaller histograms.** This is not parallelism — it's algorithmic. You cannot replicate this efficiency by throwing more GPUs at a monolithic workload.

### 2. Per-tile view-aware IMap with bin-guided weighting

Each tile renders a sub-region of the canonical view (e.g., 1/256 of c-space at 16×16 grid). Three importance-map options:

| IMap | Resolution per c-area | IS efficiency |
|---|---|---|
| Canonical orbit-length (`imap.bin`) | Sparse — 1024² cells over full disk | Same as monolithic |
| View-aware (`--build-view-imap`) | Concentrated — 1024² cells over the tile's c-region (64× higher per-area) | 2-3× better than canonical |
| **Bin-guided view-aware** (`--guide-bin guide_*.gbin`) | Same 1024² cells but weighted by the guide's brightness | **3-5× better** for visually-important regions |

The bin-guided variant uses a previously-rendered high-quality `.bin` (downsampled) as a **prior over image-space importance**. During IMap construction, each viewport-hit's contribution to its c-cell is weighted by `guide[orbit_landing_pixel]`. C-values whose orbits hit bright pixels (per the guide) get amplified IMap weight. Result: samples concentrate where they produce visible output.

### 3. Tile classification (prevents over-concentration)

Bin-guided IS amplifies existing density inequality. Bright regions get even more samples; dim regions get nearly zero. **At tile boundaries this creates visible tonal islands** — adjacent tiles can have wildly different brightness distributions, manifesting as 16×16 grid dot patterns at low pyramid zoom levels.

**Fix:** classify tiles by guide-density before rendering. Tiles where `max(guide_region) < threshold` use the canonical IMap (uniform-ish coverage) instead of bin-guided. Bright tiles get full bin-guided treatment.

```python
guide_region_max = guide[tile_y0:tile_y1, tile_x0:tile_x1].max()
if guide_region_max < THRESHOLD:
    # Use canonical IMap — no IS amplification on dim background
    cmd += ["--imap", "imap.bin"]
else:
    # Use bin-guided view-IMap — concentrate on bright structure
    cmd += ["--build-view-imap", f"{tile}_imap.bin", "--guide-bin", "guide.gbin"]
```

Default threshold: 2000 (~3% of uint16 max). Configurable via `--classify-threshold`. Set 0 to disable.

### 4. Weight floor in the kernel (smooths tile-tile discontinuities)

Even bright-classified tiles can have within-tile regions where the guide is zero. The kernel's `--guide-min-weight N` parameter ensures every viewport-hit contributes at least `N` to its IMap cell:

```c
unsigned int w = (guide[pixel] >> 8);  // top-8-bits: range [0, 255]
if (w < guide_min_weight) w = guide_min_weight;  // floor: baseline coverage
weighted_hits += w;
```

Default for tile pyramids: 8. Tunable 0-64. Zero = pure bin-guided (artifact-prone for tile pyramids); higher = smoother but reduces concentration benefit.

---

## The full corrected pipeline

```
Source bin (32K)
    ↓
downsample_bin.py
    ↓
guide_4k/8k/16k/32k.gbin  ← reusable "render cheats", archived on HF
    ↓
render_fast_tiles.py  (--classify-threshold + --guide-min-weight)
    ↓
N × tile_NN_NN.bin  (raw histograms; load-bearing artifacts)
N × tile_NN_NN.png  (per-tile debug images)
N × tile_NN_NN_imap.bin  (per-tile bin-guided IMaps)
    ↓
stitch_tiles.py --keep-apron
    ↓
N × tile_NN_NN.tif  (16-bit, global R_max tonemap, apron retained)
stitch_meta.json
    ↓
compose_blended.py  ← linear-alpha crossfade at apron overlaps
    ↓
composite.tif  (single ~9 GB 16-bit TIFF, seamless)
    ↓
build_dz_pyramid.py --composite-tif
    ↓
viewer.dzi + viewer_files/  (DZI pyramid, ~17 zoom levels)
    ↓
tar + hf sync
    ↓
viewer.tar on HF  (single-file deliverable, ~1-2 GB)
```

**Launcher script:** `run-fast-tiles-blended-h100.sh` runs all stages end-to-end with sensible defaults.

---

## Tool reference

### Source generation

| Tool | Purpose |
|---|---|
| `./buddhabrot` (rendered) | The CUDA renderer. Produces `.bin` + `.png` per run. |
| `run-32k-h100-24h.sh` | Monolithic 32K render, 24h budget — generates the SOURCE for guides. |
| `resume_to_grow_source.sh` | Resume an existing 32K `.bin` to grow it toward a higher sample target. Cleaner source = cleaner guides. |

### Guide generation

| Tool | Purpose |
|---|---|
| `tools/downsample_bin.py <bin> <gbin> --factor N` | Downsample a `.bin` to a uint16 single-channel guide. Factor 8 = 32K→4K, factor 1 = no downsample. |
| `generate_guide_hierarchy.sh` | Produce all four guide resolutions from the latest cp.bin on disk. Upload to HF in `artifacts_v1/`. |

### Tile-pyramid rendering

| Tool | Purpose |
|---|---|
| `tools/render_fast_tiles.py` | Render NxM grid of tiles. Supports `--guide-bin`, `--classify-threshold`, `--guide-min-weight`, multi-GPU, HF auto-sync. |
| `tools/stitch_tiles.py` | Per-tile global-R_max tonemap + write 16-bit TIFFs. Use `--keep-apron` for the blended pipeline. |
| `tools/compose_blended.py` | Linear-alpha crossfade at apron overlaps. Produces single seamless composite TIFF. |
| `tools/build_dz_pyramid.py` | libvips dzsave to produce DZI tile pyramid. `--composite-tif` for single-input mode, `--stitched-dir` for legacy arrayjoin. |

### Launchers (orchestrators)

| Script | Pipeline |
|---|---|
| `run-fast-tiles-h100.sh` | (deprecated, has artifacts) renders tiles + stitch (no blend) → pyramid |
| **`run-fast-tiles-blended-h100.sh`** | **(v2, corrected)** full pipeline with classification + weight floor + compose_blended |

### Utilities

| Tool | Purpose |
|---|---|
| `tools/build_viewer_package.py` | Generate OpenSeadragon viewer HTML + DZI from a single `.bin` (alternate path; tile-pyramid output uses the larger toolchain above) |
| `tools/download_from_hf.ps1` / `.sh` | Bulletproof large-file download from HF buckets via `hf sync` (avoids browser/BITS failures) |
| `tools/flip_bin.py` | 180° rotate a `.bin` in-place at the math level (fixes orientation without runtime --flip hack) |
| `tools/quality_report.py` | Per-channel max + percentile + density-correct trim derivation from a `.bin` |

---

## Operational workflows

### Workflow A: New tile pyramid from existing source

You have a 32K `.bin` on the pod and want a v2 tile pyramid render.

```bash
# On the pod
export HF_TOKEN=$(cat ~/.hf_token)
export HF_BUCKET=bochen2079/buddhabrot

# 1. Generate the guide hierarchy (if not already done)
bash generate_guide_hierarchy.sh

# 2. Render + stitch + blend + pyramid + upload (full pipeline)
bash run-fast-tiles-blended-h100.sh
```

Default config (overridable via env vars):
- 16×16 grid = 256 tiles
- 4K × 3K per tile = 64K stitched
- 60 sec per tile
- guide_4k.gbin
- classify_threshold=2000, guide_min_weight=8

Total time: ~1.5 hr on H100. Output: `viewer.tar` (~1-2 GB) auto-uploaded to HF.

### Workflow B: Grow the source for better guides

You want denser guides for future renders.

```bash
# On the pod (any H100 will do)
bash resume_to_grow_source.sh   # ~14 hr → grows cp9566 to cp22000 (1.5T samples)
bash generate_guide_hierarchy.sh # regenerate all four guides from the cleaner source
```

Source per-pixel σ drops from 3.5% to 2.3%. All guide variants benefit proportionally.

### Workflow C: Local pull + view

After a pod run completes:

```powershell
cd C:\buddhabrot-main
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "viewer.tar"
tar xf viewer.tar
# viewer.dzi + viewer_files/ are now local
```

Save this as `viewer.html` next to the `.dzi`:

```html
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Buddhabrot</title>
<style>body{margin:0;background:#0a0d14;}#osd{width:100vw;height:100vh;}</style>
</head><body><div id="osd"></div>
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
<script>OpenSeadragon({id:"osd",tileSources:"viewer.dzi",prefixUrl:"https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",showNavigator:true});</script>
</body></html>
```

Launch:
```powershell
python -m http.server 8064
# Browser → http://localhost:8064/viewer.html
```

---

## Artifact inventory (HF bucket `bochen2079/buddhabrot`)

The durable archive — these survive any pod, any session, any rebuild:

```
artifacts_v1/
├── guide_4k.gbin              25 MB    coarse, smallest, fastest IMap builds
├── guide_8k.gbin              101 MB   balanced — default for most renders
├── guide_16k.gbin             403 MB   fine — for 128K-256K stitched targets
└── guide_32k.gbin             1.6 GB   finest — for 256K-512K+ stitched

tiles_fast_h100/                         (per-tile raw histograms; recolorable forever)
├── r00c00.bin                 310 MB
├── r00c00.png                 ~65 MB   debug, not load-bearing
├── r00c00_imap.bin            4 MB     per-tile bin-guided IMap
├── ... (256 tiles total = ~100 GB)

viewer_fast_64k.tar             ~1.6 GB  OpenSeadragon DZI pyramid for 64K result
viewer_fast_64k.dzi             207 B    (manifest, if .tar not used)
viewer_fast_64k_files/                   (pyramid tiles, if .tar not used)

buddhabrot_cloud_32k_h100_24h.cp*.bin    Source 32K bins at various sample budgets
                                          (cp9280 = 622B samples = current source)
```

**Why the `.bin` files matter most:** they're the raw uint64 histograms. The PNG and viewer pyramid are derivative — any trim values, any tonemap, any future viewer technology can be re-derived from the `.bin`s. The `.png` files are debug outputs.

---

## Known issues + how they were resolved

### Issue 1: 64K renders produced corrupt histograms

**Root cause:** kernel int32 overflow in pixel indexing. At 64K resolution, `pixels × 3 = 9.66 G` exceeds `unsigned int` max (4.29 G). The histogram-write address wraps around, causing the bottom half of the image to overwrite the top half's memory.

**Fix:** commit `894f4cb` — changed all relevant indexing variables in `main.cu` from `unsigned int` to `size_t` (5 sites total: `increment_pixel_channel`, `sum_pixels_kernel`, `compute_max_kernel`, `tonemap_kernel`, `save_image` launch math).

**Bit-identical at 32K** — `size_t` arithmetic gives same results as `unsigned int` when values fit. **Functional at 64K and beyond.**

### Issue 2: Browser/BITS downloads of 77 GB `.bin` files always fail at ~50%

**Root cause:** HuggingFace Bucket resolve URLs are CDN-fronted. Long-lived TCP connections get reset by ISPs or HF edge nodes. Browsers and `Invoke-WebRequest` / `Start-BitsTransfer` all use single-stream HTTP and lack proper resume.

**Fix:** `hf sync` CLI uses HF's chunked API (small per-request bytes, transparent retry, resumable). Documented in `HF_DOWNLOAD.md`. Also: tar-bundle whole pyramids into single files for one-shot upload/download (avoids per-file HTTP overhead which destroys throughput at 65K+ tile counts).

### Issue 3: Bin-guided IMap created tonal islands at tile boundaries (16×16 dot grid)

**Root cause:** bin-guided weighting amplifies existing density inequality. Adjacent tiles can have wildly different effective brightness distributions, producing visible per-tile averages at low pyramid zoom levels.

**Fix:** commits `ef29229` + `64b2d90` — two orthogonal fixes:
1. `--classify-threshold N` in `render_fast_tiles.py`: tiles with `max(guide_region) < N` use canonical IMap (uniform-ish coverage)
2. `--guide-min-weight N` in `main.cu`: kernel floor ensures every viewport-hit contributes at least N to its IMap cell

### Issue 4: Hard cuts at tile boundaries in stitched output

**Root cause:** `stitch_tiles.py --keep-apron` retains aprons, but the actual crossfade is done by a separate tool (`compose_blended.py`) which was never run in the original pipeline.

**Fix:** `run-fast-tiles-blended-h100.sh` runs the full pipeline including `compose_blended.py` between stitch and dzsave. Plus `build_dz_pyramid.py` gained `--composite-tif` mode to take the single blended composite as input.

### Issue 5: tile filename mismatch between renderer and stitcher

**Root cause:** `render_fast_tiles.py` writes tiles as `r07c07.bin`, but `stitch_tiles.py` was looking for `tile_r07c07.bin` (legacy convention from `tile_orchestrate.py`).

**Fix:** commit `8d3af5b` — drop the `tile_` prefix in stitcher.

### Issue 6: BITS/browser downloads fail on 77 GB checkpoint files

See Issue 2. Mitigation: use `hf sync` CLI. Documented in `HF_DOWNLOAD.md`.

---

## Performance numbers (validated on H100 PCIe)

### Throughput

| Workload | Throughput | Per-pixel density @ 60s/tile |
|---|---|---|
| 32K monolithic | 11 M/s | 0.66 traj/px in 60s (~50 traj/px in 24h) |
| 4K tile @ bin-guided | 262 M/s | **60 traj/px in 60s** |
| 8K tile @ bin-guided | ~180 M/s | 14 traj/px in 60s |

### Wallclock (16×16 grid, 60s/tile)

| Stage | Time |
|---|---|
| Render 256 tiles | ~75 min |
| Stitch (per-tile tonemap → TIFF) | ~5 min |
| Compose_blended | ~5 min |
| Build DZI pyramid (libvips dzsave) | ~5 min |
| Tar + HF upload | ~3 min |
| **Total** | **~95 min** |

### Storage

| Artifact | Size |
|---|---|
| Source 32K `.bin` (cp9280, 622 B samples) | 18 GB |
| Guide hierarchy (4K/8K/16K/32K) | 2.1 GB total |
| 256 tile `.bin` files (4K each) | ~80 GB |
| `viewer.tar` (DZI pyramid for 64K) | ~1.6 GB |

---

## Key insights to internalize

1. **Resolution alone is not quality.** A 64K monolithic at 1 hr is empty pixels around the same content as a 32K monolithic at 1 hr. Per-tile rendering at the visualization scale produces meaningful detail.

2. **The `.bin` is the load-bearing artifact.** PNGs are derivative. Anything you might want to do later (re-tonemap, re-tile, denoise, etc.) is possible from the `.bin`s. Treat them as the durable asset.

3. **The guide is reusable forever.** Once generated from a high-quality source, it powers any future tile pyramid render of the same view. The 1.6 GB `guide_32k.gbin` is the highest-leverage single asset on HF.

4. **L2 cache fit is the architectural fork.** Below ~50 MB working set, atomic adds resolve in cache and throughput skyrockets. Above that, you're bandwidth-bound. Choose tile sizes accordingly.

5. **Bin-guided IS has a downside.** Over-concentration creates tonal islands. Fix at two layers: tile classification (binary decision) + weight floor (continuous smoothing). Both should be active for tile pyramids.

6. **Tar-bundle for HF transfers.** Per-file HTTP overhead destroys throughput when you have 65K+ tiny files. Bundle into a single tar, transfer at ~100 MB/s, extract locally.

---

## Future directions

### 128K stitched (next obvious step)

Same pipeline, 8K tiles instead of 4K:

```bash
GRID=16x16 RESOLUTION=8192x6144 GUIDE=guide_16k.gbin \
    bash run-fast-tiles-blended-h100.sh
```

Expected: ~5 hr on H100, 128K stitched output, 240 traj/px native per tile, 17 OSD zoom levels.

### 256K stitched (the leverage limit before source upgrade)

16×16 grid at 16K tiles. Per-tile compute fits H100 80GB easily. Stitched composite TIFF is ~38 GB — needs disk planning.

```bash
GRID=16x16 RESOLUTION=16384x12288 GUIDE=guide_16k.gbin \
    bash run-fast-tiles-blended-h100.sh
```

Expected: ~20 hr on H100. 18 OSD zoom levels.

Past 256K stitched, guide_16k is too coarse (multiple tile pixels per guide pixel). Either generate a denser source `.bin` first (via `resume_to_grow_source.sh`) or accept the guide-resolution ceiling.

### 512K+ requires denser source

Per-pixel guide noise (3.5% σ at cp9566) becomes the limiter. Path:
1. Grow source to 2-3 T samples (~28 hr H100)
2. Re-generate guide_32k.gbin from cleaner source
3. Then 512K stitched becomes tractable

### Multi-view ambition

The current architecture is hardcoded to the canonical Buddhabrot view (center -0.5935417456742, 0.04166264380232, zoom 0.5, rotation 90°). For zoom-into-features renders (e.g., deep zooms into specific filaments), the guide derived from canonical wouldn't help — would need to render new source for each new view.

**Not a near-term goal.** The canonical view is the artifact target.

---

## References

- `CLAUDE.md` — project operating contract, architectural invariants, banned patterns
- `BUILD_LOG.md` — per-session change log
- `HF_DOWNLOAD.md` — how to reliably download large files from HF
- `cloud_render_plan.md` — detailed wallclock arithmetic, dimensional audit
- Bitterli (2014) — "The Buddhabrot" — importance map architecture
- Munafo's mu-ency catalog — methodology baseline

---

*Last updated: 2026-05-12. Validated on H100 PCIe @ Hyperbolic.xyz. Pipeline produces seamless 64K OpenSeadragon viewer in ~95 min.*
