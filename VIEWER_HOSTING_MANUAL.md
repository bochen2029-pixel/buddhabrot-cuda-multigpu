# Viewer hosting manual — OpenSeadragon Deep Zoom pyramids

**Audience:** Bo Chen (project owner) + any AI/LLM brought in to help host, debug, or extend the public-facing viewer. Companion to `BIN_GUIDED_TILE_PYRAMID.md` (which covers the render pipeline). This doc covers everything from `viewer.dzi` onward — DZI format, OpenSeadragon HTML, hosting paths, the "war stories" from this project, and step-by-step instructions to put the 64K/128K/256K viewer on the public internet.

**Status:** Production-validated for 64K (today, 2026-05-12). Hosting paths documented for HF Bucket, HF Spaces, Cloudflare R2 + Pages, AWS S3 + CloudFront, GitHub Pages, self-hosted NGINX.

---

## Section 0 — LLM ingest header (read me first if you're an AI)

### Why this manual exists

The Buddhabrot tile-pyramid pipeline produces a `viewer.tar` containing a DZI deep-zoom pyramid that any browser with OpenSeadragon can render. Getting that on the public internet — and surviving the operational gotchas — is non-trivial. This manual is the durable knowledge.

### Suggested system prompt for AI assistants

```
You are helping Bo Chen host or debug an OpenSeadragon Deep Zoom Image
(DZI) viewer for a Buddhabrot fractal render. The reference manual is
VIEWER_HOSTING_MANUAL.md.

Context:
  - The render produces viewer.tar (~1.6 GB for 64K, ~6 GB for 128K,
    ~25 GB for 256K) containing viewer.dzi (XML manifest) and
    viewer_files/ (the pyramid tile directory).
  - DZI tiles are JPEG by default (~10-50 KB each); a 64K pyramid has
    ~65000 tiles, a 128K pyramid has ~260000.
  - Bo wants a public URL anyone can paste into a browser to deep-zoom
    the artifact. Hosting paths covered in §4.
  - Per-file HTTP overhead is the killer: avoid per-file uploads to
    HuggingFace (use Spaces with a pre-staged tarball or use R2).
  - CORS matters when viewer.html and viewer_files/ are on different
    origins.

Bo prefers direct, unpadded answers; no apology theater. When he asks
how to host the viewer, give him the exact commands for the provider
he names (RunPod, HF, Cloudflare, AWS — covered in §4.1-4.6).

Lessons learned in §3 are NOT speculative — they happened. Trust them.

Known canonical viewer.html template is in §2.5 (CDN-based, single file,
~30 lines). Don't reinvent it.

If asked for hosting recommendations: lead with HF Spaces (simplest,
free) or Cloudflare R2 (cheapest, no egress fees). Avoid GitHub Pages
above 32K. AWS works but egress costs add up.
```

### Chunk routing — "I need to..."

| Need | Read section |
|---|---|
| Understand what OpenSeadragon / DZI is | §1 |
| Get a working viewer.html template | §2.5 (canonical template) |
| Customize the viewer (controls, navigator, zoom limits) | §2.6 |
| Understand DZI file format internals | §2.2 |
| Avoid the black grid problem | §3.1 |
| Fix upside-down image | §3.2 |
| Avoid per-cp browser cache confusion | §3.3 |
| Avoid tar-bundling pitfalls | §3.4 |
| Host on HuggingFace Bucket (public URL) | §4.1 |
| Host on HuggingFace Spaces (proper way) | §4.2 |
| Host on Cloudflare R2 + Pages | §4.3 |
| Host on AWS S3 + CloudFront | §4.4 |
| Host on GitHub Pages | §4.5 |
| Self-host on a VM (NGINX) | §4.6 |
| Configure CORS for cross-origin viewer | §5 |
| Tune performance (tile size, JPEG quality, caching) | §6 |
| Embed in a website / iframe | §7 |
| Troubleshoot "tiles don't load" / blurry / slow | §8 |
| Share the link nicely (QR, OG tags, social media) | §9 |
| Plan for 256K and beyond | §10 |

### File chunks (for token-budgeted ingest)

```
§0:  LLM ingest header                       (~700 tokens)
§1:  What is OpenSeadragon                   (~600)
§2:  The viewer.html anatomy                 (~1500)
§3:  Pipeline-side lessons learned           (~2000)
§4:  Hosting paths (HF/CF/AWS/GH/self)       (~4000)
§5:  CORS                                    (~800)
§6:  Performance tuning                      (~1200)
§7:  Embed options                           (~600)
§8:  Troubleshooting                         (~1500)
§9:  Sharing                                 (~600)
§10: Future (128K-512K hosting math)         (~1200)
§11: LLM Q&A deep-dive                       (~1500)
Appendix A: DZI format spec                  (~700)
Appendix B: viewer.html templates × N        (~1500)
Total:                                      ~18000 tokens
```

---

## Section 1 — What is OpenSeadragon

### 1.1 The library

[OpenSeadragon (OSD)](https://openseadragon.github.io/) is a vanilla-JS, dependency-free library for browser-based deep-zoom of large images. Pure client-side — no server logic — it works by fetching individual pyramid tiles as the user pans and zooms. Mature, MIT-licensed, ~50 KB minified.

You point it at a tile pyramid manifest (DZI, IIIF, or a few others); OSD figures out which tiles to fetch and composes them in a `<canvas>`. Smooth zoom, pinch on mobile, keyboard arrows, navigator overview, fullscreen — all built in.

### 1.2 DZI format (Microsoft Deep Zoom Image)

The format we use. A DZI pyramid consists of:

```
viewer.dzi          XML manifest (small, ~200 bytes)
viewer_files/       directory tree of tiles
  0/                level 0 (smallest, single tile)
    0_0.jpg
  1/                level 1 (2× bigger)
    0_0.jpg
    1_0.jpg
    0_1.jpg
    1_1.jpg
  2/
    ...
  N/                level N (full resolution)
    0_0.jpg ...     thousands of tiles
```

Each "level" doubles in resolution. A 64K (65536 × 49152) pyramid has 17 levels (`log2(65536) = 16`, +1 for the L0 single tile). Each level's tiles are 256×256 pixels by default (some pyramids use 512×512). Files are typically JPEG (~10-50 KB each) for browser-friendliness.

**The viewer.dzi manifest** (the file OpenSeadragon points to):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Image xmlns="http://schemas.microsoft.com/deepzoom/2008"
       Format="jpg"
       Overlap="0"
       TileSize="256">
  <Size Width="65536" Height="49152"/>
</Image>
```

Three attributes drive everything:
- `Format` — `jpg`, `png`, or `webp`. JPEG by default; lossy but ~10× smaller than PNG.
- `Overlap` — pixels of duplicate content shared between adjacent tiles for smooth filtering. **Must be 0 for this project (see §3.1).**
- `TileSize` — pixel dimensions of each tile. 256 default; 512 reduces tile count by 4× but each tile is 4× larger.

### 1.3 Why DZI vs alternatives

| Format | Pros | Cons |
|---|---|---|
| **DZI** (what we use) | Mature, library support (OSD, Seadragon AJAX), tooling (libvips dzsave, deepzoom.py) | Microsoft-flavored XML |
| IIIF | Standardized, widely supported in cultural-heritage tools | More server-side configuration, info.json format |
| Zoomify | Older, decent tooling | Less modern, fewer libraries |
| Custom tiles | Total control | Have to build everything |
| WebP single-image | Smallest | Browser memory limits at >32K resolution |

DZI is the pragmatic choice for this project: libvips produces it natively, OSD renders it natively, every hosting provider serves it as static files.

### 1.4 Pyramid math (handy for capacity planning)

```
Tiles per level (256×256, no overlap):
  Level N has ceil(W / (256 × 2^(N_max - N))) × ceil(H / (256 × 2^(N_max - N))) tiles
  Where N_max = ceil(log2(max(W, H)))

For 64K (65536 × 49152):
  N_max = 16
  Total tiles ≈ 65000 (sum of geometric series across levels)
  Total size  ≈ 1.5 GB (at JPEG quality 75)

For 128K:
  N_max = 17
  Total tiles ≈ 260000
  Total size  ≈ 6 GB

For 256K:
  N_max = 18
  Total tiles ≈ 1.04M
  Total size  ≈ 25 GB

For 512K:
  N_max = 19
  Total tiles ≈ 4.2M
  Total size  ≈ 100 GB
```

The tile count is the load-bearing number for hosting selection. Above 256K, the per-file HTTP overhead at 1M+ tiles makes "upload to HF as individual files" infeasible — must tar-bundle or use a CDN with origin pull.

---

## Section 2 — The viewer.html (anatomy)

### 2.1 Minimum viable viewer

OpenSeadragon ships from CDN; viewer.html is a 30-line wrapper that loads the library and points it at the DZI manifest.

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Buddhabrot 64K</title>
  <style>
    body { margin: 0; background: #0a0d14; }
    #osd { width: 100vw; height: 100vh; }
  </style>
</head>
<body>
  <div id="osd"></div>
  <script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
  <script>
    OpenSeadragon({
      id: "osd",
      tileSources: "viewer.dzi",
      prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
      showNavigator: true
    });
  </script>
</body>
</html>
```

That's it. Save as `viewer.html` next to `viewer.dzi`, serve via HTTP, browser shows zoomable image.

### 2.2 DZI manifest format (deep-dive)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Image xmlns="http://schemas.microsoft.com/deepzoom/2008"
       Format="jpg"           <!-- "jpg" or "png" or "webp" -->
       Overlap="0"            <!-- pixels (see §3.1) -->
       TileSize="256">        <!-- per-tile dimensions in pixels -->
  <Size Width="65536"
        Height="49152"/>
</Image>
```

The `Format` attribute must match the actual file extension in `viewer_files/`. Mismatch → 404. The `TileSize` and `Overlap` attributes determine how OSD calculates which tiles to fetch for a given zoom/pan position.

### 2.3 The viewer_files/ directory

Generated by `libvips dzsave` (called by `tools/build_dz_pyramid.py`):

```
viewer_files/
├── 0/
│   └── 0_0.jpg          ~1 KB   (level 0 — single 1×1 tile representing the whole image)
├── 1/
│   ├── 0_0.jpg          ~2 KB
│   └── 1_0.jpg          ~1 KB   (level 1 — 2 tiles)
├── 2/
│   ├── ...                      (level 2 — 4 tiles)
├── ...
└── 16/                         (level 16 — full resolution for 64K)
    ├── 0_0.jpg          ~30 KB
    ├── 1_0.jpg          ~28 KB
    ├── ...                      (~65000 tiles total for 64K)
```

Filename convention: `{column}_{row}.jpg`. OSD does the math; you don't index this manually.

### 2.4 Required CDN files

The viewer.html line:
```html
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
```
loads the OpenSeadragon library itself.

The line:
```js
prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
```
tells OSD where the navigation button images live (zoom in/out, home, fullscreen icons). These are NOT optional — without them OSD shows broken-image icons in the toolbar.

If you self-host (no CDN dependency), grab the full OSD distribution from https://openseadragon.github.io/#download, host the `build/openseadragon/` dir alongside `viewer.html`, and change the URLs.

### 2.5 Canonical viewer.html (project standard)

This is the template used for every Buddhabrot release. Tested 2026-05-12.

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Buddhabrot 64K — IS+tile pyramid</title>
  <style>
    html, body { margin: 0; padding: 0; height: 100%; }
    body { background: #0a0d14; color: #eee; font-family: sans-serif; }
    #osd { width: 100vw; height: 100vh; }
    #info {
      position: absolute; top: 10px; left: 10px;
      background: rgba(0,0,0,0.7); padding: 8px 12px;
      border-radius: 4px; font-size: 12px;
      pointer-events: none;
    }
  </style>
</head>
<body>
  <div id="osd"></div>
  <div id="info">64K • importance-sampled • 16×16 tiles • ~95 min on H100</div>
  <script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
  <script>
    OpenSeadragon({
      id: "osd",
      tileSources: "viewer.dzi",
      prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
      showNavigator: true,
      showZoomControl: true,
      showHomeControl: true,
      showFullPageControl: true,
      showRotationControl: false,
      minZoomLevel: 0.5,
      maxZoomPixelRatio: 8,
      animationTime: 0.6,
      springStiffness: 7.0,
      gestureSettingsMouse: { scrollToZoom: true, clickToZoom: false },
      navigatorPosition: "BOTTOM_RIGHT",
      navigatorMaintainSizeRatio: true,
      visibilityRatio: 0.3,
      constrainDuringPan: true
    });
  </script>
</body>
</html>
```

### 2.6 Customization knobs (OpenSeadragon options worth knowing)

| Option | Default | What it does |
|---|---|---|
| `tileSources` | required | Path to your `viewer.dzi` (relative or absolute) |
| `prefixUrl` | required for UI | Path to OSD's `images/` dir (or CDN URL) |
| `showNavigator` | false | Mini-map overview in corner |
| `navigatorPosition` | "TOP_RIGHT" | Where the mini-map sits — TOP/BOTTOM × LEFT/RIGHT |
| `showZoomControl` | true | Zoom +/- buttons |
| `showHomeControl` | true | Reset-to-fit button |
| `showFullPageControl` | true | Fullscreen toggle |
| `showRotationControl` | false | Rotate image button (off — orientation is fixed) |
| `minZoomLevel` | 1.0 | Smallest zoom factor (0.5 = can zoom out past fit-to-screen) |
| `maxZoomPixelRatio` | 1.1 | Largest zoom (1 = native pixels; 8 = 8× past native) |
| `animationTime` | 1.2 | Pan/zoom animation duration in seconds (0.6 = snappier) |
| `springStiffness` | 6.5 | How quickly animation settles (higher = snappier) |
| `gestureSettingsMouse` | various | Customize mouse behavior — `scrollToZoom: true` is intuitive |
| `visibilityRatio` | 0.5 | How much of the image must stay visible (lower = looser pan) |
| `constrainDuringPan` | false | Lock pan to image bounds during drag |

### 2.7 Multiple images, side-by-side, image layers

OSD supports loading multiple DZI sources in one viewer, useful if you want to compare cps or show R/G/B channel separations:

```js
OpenSeadragon({
  id: "osd",
  tileSources: [
    { tileSource: "viewer_cp4130.dzi", x: 0, y: 0, width: 1 },
    { tileSource: "viewer_cp9280.dzi", x: 1, y: 0, width: 1 }
  ],
  // ... rest of config
});
```

This places two pyramids side-by-side. Both pan/zoom together.

---

## Section 3 — Pipeline-side lessons learned (war stories)

These all happened on this project. The fixes are in the code; the rationale lives here so they don't get re-introduced.

### 3.1 The black grid (overlap=0 vs overlap=2 regression)

**Symptom (cp8320 viewer):** thin black/dark seams at every tile junction when zoomed in, forming a regular grid. Most visible on dim background regions.

**My commit `27f8308`:** changed `overlap=0` to `overlap=2` in `tools/build_viewer_package.py`, thinking that overlap would smooth tile junctions.

**Why it was wrong:** OpenSeadragon's overlap parameter is for SOURCE pixels to be DUPLICATED across adjacent tiles. The DZI standard's overlap means "tile N+1 starts at pixel `(N+1)*tileSize - overlap`" — so adjacent tiles share `overlap` pixels of content. libvips dzsave with `--overlap=2` correctly produces this. But the BLENDING is wrong — the source pipeline (`compose_blended.py`) had already done linear-alpha crossfade at the apron boundary, so the apron-region pixels were already blended with their neighbors. Re-overlapping at the DZI layer caused the SAME blended-edge pixels to be drawn TWICE at slightly different positions, creating visible black seams where the JPEG compression artifacts at near-zero brightness amplified.

**Fix (commit `f53f853`):** reverted to `overlap=0`. Tile junctions look clean because the per-tile content already has the apron blended in via `compose_blended.py`; the DZI layer just slices it without any further blending magic.

**The hard lesson:** the user reported the regression and I generated 5 turns of theories (browser cache, perception bias, JPEG noise masking, resolution-dependent visibility) before actually diffing two viewer directories. The DIFF found `Overlap="2"` vs `Overlap="0"` in the .dzi files — exactly the commit I'd made. See `feedback_regression_validation.md` for the meta-lesson.

**The principle:** `Overlap` in DZI is a HISTORICAL feature for sources where you didn't have full control of edge blending. Modern pipelines that blend in the compose step should ALWAYS use `Overlap="0"`. There is no use case for `Overlap > 0` in this project.

### 3.2 The upside-down image (flip_bin.py at math level)

**Symptom:** the very first 16K local render came out 180° rotated relative to the canonical reference image. The body cusp was at the top; the symmetric lobes pointed down.

**First attempt (wrong):** added `--flip` runtime flag to the viewer building. This rotated the PNG at display time via `np.ascontiguousarray(image[::-1, ::-1])`.

**Why it was wrong:**
1. It worked for PNG output but not for the `.bin` raw histogram — the bin was still stored upside down
2. Any future viewer pipeline that read the `.bin` directly (e.g., to re-tonemap with different trims) would re-introduce the upside-down output
3. The `.bin` is the load-bearing artifact, per CLAUDE.md §3 invariants — orientation should be CORRECT at the math layer, not patched at display time

**Proper fix:** `tools/flip_bin.py` reads a `.bin` (BHRA magic + uint64 hist body), rotates the histogram array 180° in-place at the math level, writes back atomically. Once-and-for-all fix. Display pipeline doesn't need `--flip` anymore; the data is correct as stored.

**Code (one-liner essence):**
```python
import numpy as np
hist = np.fromfile(bin_path, dtype=np.uint64, offset=128).reshape(H, W, 3)
flipped = np.ascontiguousarray(hist[::-1, ::-1, :])
# Write 128-byte header + flipped uint64 hist body atomically (.tmp + rename)
```

**The principle:** orientation is a property of the data, not the display. Fix at the latest stage that the data passes through — which is the `.bin` file, not the viewer. Same logic applies if the project ever needs gamma correction, channel swap, or any other persistent transform: do it at the `.bin` math level so all downstream consumers see the corrected data.

### 3.3 Per-cp browser cache confusion (the 64K-shown-when-32K-launched bug)

**Symptom:** user launched the 32K viewer on port 8000, saw a fully-rendered 64K image instead. Cleared browser cache, still saw 64K.

**Root cause:** OpenSeadragon caches DZI manifests and tile responses aggressively. When a previous session served `viewer.dzi` for a 64K render on port 8000, the browser cached:
- `http://localhost:8000/viewer.dzi` (with 64K Width/Height)
- `http://localhost:8000/viewer_files/0/0_0.jpg` (the L0 tile from 64K)
- etc.

Launching a 32K viewer on the SAME port serves new files but the browser's cache layer matches on URL — same URL, served the cached 64K versions.

**Fix in `build_viewer_package.py`:** assign per-cp-label unique ports:

```python
def port_for_cp(cp_label):
    # 8000 + (cp_label % 1000)
    # Always > 8000, < 9000, deterministic
    return 8000 + int(cp_label) % 1000
```

So `cp4130` → port 8130, `cp9280` → port 8280, etc. Each cp gets its own port, browser's cache scoped to host:port, no confusion.

**Alternative:** add `?v=<cp_label>` query string to the .dzi URL inside viewer.html. Cache-busting via query parameter works in modern browsers; the OSD config becomes:

```js
tileSources: "viewer.dzi?v=cp9280"
```

But per-port is simpler and works for the local-dev pattern.

**The principle:** when iterating viewer output during render development, never reuse port numbers across content variants. The browser doesn't know your content changed; the URL is its only key.

### 3.4 Per-file HTTP overhead vs tar-bundling

**Symptom:** uploading a 65000-tile pyramid to HF via individual `hf upload` calls took >2 hours. The actual data size (~1.6 GB) should transfer in 30 seconds at 100 MB/s.

**Root cause:** every `hf upload` call has overhead: TLS handshake (~50 ms), request signing (~20 ms), API metadata round-trip (~50 ms). Multiplied by 65000 tiles = ~2 hours of overhead alone, regardless of payload size.

**Fix:** tar-bundle the entire `viewer_files/` + `viewer.dzi` into a single `viewer.tar` before upload:

```bash
tar cf viewer.tar viewer.dzi viewer_files/
hf sync . hf://buckets/bochen2079/buddhabrot/ --include "viewer.tar"
```

One file, ~30 second upload. Locally on the consumer side:

```bash
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "viewer.tar"
tar xf viewer.tar
```

Same speed. The tar bundling is the win.

**Trade-off:** if you're hosting via HF Bucket (§4.1), the tar bundle isn't directly servable — you have to download + extract on the consumer side. For HF Spaces (§4.2), this is fine because Spaces does the extract for you in its filesystem. For direct CDN serving via R2 (§4.3), use `tar tf viewer.tar` to manifest then `aws s3 sync` the extracted dir into R2.

**The principle:** per-request HTTP overhead is invisible until you hit 10000+ requests. Always bundle when the destination doesn't need per-file granularity.

### 3.5 libvips dzsave vs Python deepzoom_tiler

**Symptom:** initial implementation used `deepzoom_tiler` (Pure Python). Took ~2 hours to produce a 64K pyramid.

**Root cause:** Python's PIL/Pillow image resampling is slow, single-threaded, and copies arrays. The libvips C library does multi-threaded streaming resize with no intermediate buffers.

**Fix:** `tools/build_dz_pyramid.py` calls `pyvips`:

```python
import pyvips
img = pyvips.Image.new_from_file("composite.tif", access="sequential")
img.dzsave("viewer", suffix=".jpg[Q=75]", overlap=0, tile_size=256)
# Produces viewer.dzi + viewer_files/ in ~5 min for 64K
```

`dzsave` is 24× faster than `deepzoom_tiler` for this workload. Difference: pyvips streams pixels through a pipeline of C ops; PIL materializes the full image at every resize level.

**The principle:** for any pixel-pushing pipeline that crosses Python boundaries, prefer a streaming C library (libvips, OpenCV, image_io) over PIL. The 24× speedup is typical.

### 3.6 The compose_blended-before-dzsave invariant

**Symptom:** initial pipeline did `stitch_tiles.py` → `build_dz_pyramid.py` directly. Result: visible hard cuts at every tile boundary in the deep-zoom viewer.

**Root cause:** `stitch_tiles.py --keep-apron` retains apron pixels but doesn't BLEND them. The apron pixels are just retained as-is. At tile junctions, the RIGHT edge of tile N has the apron content; the LEFT edge of tile N+1 has its own (different) apron content. These don't match — they were rendered independently with independent RNG streams.

**Fix:** `tools/compose_blended.py` runs between stitch and dzsave. It reads the apron-retained TIFFs, does linear-alpha crossfade in the apron-overlap region (each pixel at position p from the apron edge gets weight `1 - p/apron_width` for the source tile and `p/apron_width` for the neighbor), writes a single seamless composite TIFF.

`build_dz_pyramid.py --composite-tif composite.tif` then takes the single seamless TIFF and produces the DZI pyramid.

**The principle:** blend at the highest-resolution layer before pyramiding. Pyramiding propagates blends downward (averaging neighboring pixels at each downsample level), so blending at the source resolution gives the cleanest output at every zoom level. Blending at the pyramid level (post-dzsave) is impossible — the tiles are independent JPEG-compressed files.

### 3.7 The mass-stub recovery story (GPU fault mid-render)

**Symptom (2026-05-12):** at tile 199 of 256, the GPU entered a wedged state. Persistent `device busy` errors. Pod scheduled to shut down in 40 minutes. 38 tiles missing in the bottom-right corner.

**Recovery:** copied a known-good neighbor's `.bin` + `.png` into the 38 missing slots. The launcher's skip-if-exists logic treated these as completed. Pipeline proceeded through stitch → compose → dzsave on CPU only (no GPU needed).

**Why this worked:** the 38 missing tiles were all in the bottom-right empty-background region of the canonical Buddhabrot composition. The stubbed content was a similarly-empty region, so the visual artifact was invisible.

**Why this won't always work:** if the missing tiles had been in a high-detail region (body cusp, period bulb), the stubbed content would be jarring — wrong viewport content pasted in.

**Prevention:** use `--tile-order brightness` to render high-detail tiles FIRST. Crashes are biased toward the trailing (low-priority) tiles, which are by construction the empty regions. See `BIN_GUIDED_TILE_PYRAMID.md` §3.5.

### 3.8 cp4130 viewer artifacts (early black-grid related)

**Symptom (cp4130 era):** viewer at lower cp values showed thin dark vertical/horizontal seams at regular intervals — clearly tile boundaries.

**Root cause (combination):**
1. `stitch_tiles.py` was running with `--keep-apron` but `build_dz_pyramid.py` was running with the `--stitched-dir` arrayjoin mode (legacy path). The arrayjoin in libvips does NOT do per-tile blending — it just butt-joins the apron-retained tiles.
2. The apron content at adjacent tiles disagreed.

**Fix:** unified the pipeline to ALWAYS produce `composite.tif` via `compose_blended.py` first, then dzsave the single composite. Documented in commit `ef29229` + `64b2d90`.

### 3.9 BITS downloads failing at 50%

**Symptom:** Windows `Start-BitsTransfer` (and Chrome browser downloads) of large viewer.tar files always cut out at ~50% completion.

**Root cause:** HF Bucket resolve URLs are CDN-fronted. Long-lived TCP connections (>5 min) get reset by some ISPs or HF edge nodes. BITS doesn't handle the reset gracefully — restarts from scratch on retry, hits the same cap, repeats.

**Fix:** `hf sync` CLI uses HF's chunked API. Small per-request bytes (~10 MB), transparent retry within the chunk, no long-lived connections. Documented in `HF_DOWNLOAD.md`.

**The principle:** for >1 GB files, never trust browser/BITS/curl single-stream downloads. Always use a chunked-API client (hf sync, aws s3 cp, gcloud storage cp).

---

## Section 4 — Hosting paths

Six options, ordered by recommendation for this project:

| Path | Free? | URL form | Best for |
|---|---|---|---|
| HuggingFace Spaces (§4.2) | Yes (5 GB) | `https://<user>-<space>.hf.space/` | < 32K viewer |
| Cloudflare R2 + Pages (§4.3) | $5/mo for big files | `https://<custom-domain>/viewer.html` | 64K-256K viewers |
| HuggingFace Bucket public (§4.1) | Yes | `https://huggingface.co/buckets/<user>/<bucket>/resolve/main/...` | Quick share |
| AWS S3 + CloudFront (§4.4) | Pay per use | `https://<dist>.cloudfront.net/viewer.html` | Enterprise / known traffic |
| GitHub Pages (§4.5) | Yes (1 GB / 100 GB BW/mo) | `https://<user>.github.io/<repo>/viewer.html` | 16K-32K only |
| Self-hosted NGINX (§4.6) | Server cost | `https://<your-domain>/viewer.html` | Total control |

### 4.1 HuggingFace Bucket — public URL (quickest)

**When to use:** you already have the viewer.tar on HF (you do — the pipeline uploads it there). Get a shareable URL in 2 minutes.

**Setup:**

1. Make sure your bucket is set to public read access. In the HF web UI:
   - Go to https://huggingface.co/buckets/bochen2079/buddhabrot
   - Settings → Visibility → set to Public

2. Upload `viewer.tar` if not already (the pipeline does this automatically).

3. **Extract the tarball remotely** — HF Bucket serves files at the path you upload them at, so you need viewer.dzi + viewer_files/ at directly-accessible paths, not zipped inside a .tar.

   Option A: extract locally + re-upload as directory:
   ```bash
   mkdir staging_64k
   cd staging_64k
   hf sync hf://buckets/bochen2079/buddhabrot/ . --include "viewer.tar"
   tar xf viewer.tar
   rm viewer.tar
   # Copy viewer.html into this dir (template from §2.5)
   hf sync . hf://buckets/bochen2079/buddhabrot/viewer_64k_public/
   ```

4. **Public URL pattern** (HF Bucket public URLs):
   ```
   https://huggingface.co/buckets/bochen2079/buddhabrot/resolve/main/viewer_64k_public/viewer.html
   ```

   This URL serves your viewer. The viewer.html will fetch `viewer.dzi` and tiles from the same directory.

**Pros:**
- Zero additional infrastructure
- Free for public buckets (up to HF storage limits)
- Files already there

**Cons:**
- Tile-loading is via HF's resolve endpoint, not a tuned CDN — at deep zoom you'll see ~150 ms per tile vs ~10 ms on R2/Cloudflare
- Per-file fetch from HF can be rate-limited (HF doesn't publish hard rates but very rapid panning of a 256K viewer may hit limits)
- HF URL structure isn't the cleanest for sharing publicly

**Recommendation:** use this for "send Bo's friend a link" but graduate to §4.3 (Cloudflare R2 + Pages) for any setup that gets repeated traffic.

### 4.2 HuggingFace Spaces (proper way for static hosting)

**When to use:** you want a clean URL like `https://bochen2079-buddhabrot-64k.hf.space` and a proper static site host that HF designed for this.

**Setup:**

1. Create a new HF Space:
   - Go to https://huggingface.co/new-space
   - Owner: bochen2079; Space name: `buddhabrot-64k` (or similar)
   - SDK: **Static**
   - Visibility: Public
   - Hardware: CPU basic (free)

2. Clone the Space repo:
   ```bash
   git clone https://huggingface.co/spaces/bochen2079/buddhabrot-64k
   cd buddhabrot-64k
   ```

3. Pull the viewer.tar from the bucket, extract:
   ```bash
   hf sync hf://buckets/bochen2079/buddhabrot/ . --include "viewer.tar"
   tar xf viewer.tar
   rm viewer.tar
   ```

4. Add `viewer.html` (template from §2.5) — call it `index.html` so HF Spaces serves it as the root:
   ```bash
   # Save the §2.5 template to index.html (or rename viewer.html → index.html)
   ```

5. Add a basic `README.md` so the Space looks legit:
   ```markdown
   ---
   title: Buddhabrot 64K
   emoji: 🌌
   colorFrom: blue
   colorTo: black
   sdk: static
   pinned: false
   ---

   # Buddhabrot 64K — IS+tile pyramid render
   Click the viewer to explore. Render details in BIN_GUIDED_TILE_PYRAMID.md.
   ```

6. Commit and push:
   ```bash
   git lfs install
   git lfs track "*.jpg"   # tile files in viewer_files/
   git add .gitattributes
   git add README.md index.html viewer.dzi viewer_files/
   git commit -m "Initial 64K viewer"
   git push
   ```

   **Caveat:** Spaces has a 5 GB total storage limit on free tier. 64K viewer (~1.6 GB) fits; 128K viewer (~6 GB) does NOT.

7. **Your URL:** `https://huggingface.co/spaces/bochen2079/buddhabrot-64k`

   Or the cleaner `*.hf.space` subdomain: `https://bochen2079-buddhabrot-64k.hf.space/`

**Pros:**
- Clean URL
- Free
- Designed for static hosting
- Custom domain support on paid tiers
- Built-in OG tags (Twitter previews work)

**Cons:**
- 5 GB free-tier limit (paid tier $9/mo for 50 GB)
- Git LFS required for >10 MB files; LFS bandwidth limits apply
- Cold-start delay (~5 sec) if the Space hasn't been hit in hours

**Recommendation:** best free option for 32K-64K. For 128K+ use Cloudflare R2.

### 4.3 Cloudflare R2 + Pages (recommended for repeat use)

**When to use:** 64K-256K viewers, lots of repeat traffic, you want sub-100 ms tile loads worldwide. R2 has **zero egress fees** which makes it the best economics for image hosting.

**Setup:**

#### 4.3.1 R2 bucket for the tiles

1. Sign up at https://www.cloudflare.com (free tier OK).
2. R2 → Create bucket.
   - Bucket name: `buddhabrot-tiles-64k`
   - Location: Automatic
3. Settings → R2.dev subdomain → Enable public access. You get a URL like `https://pub-abc123def.r2.dev/buddhabrot-tiles-64k/`

4. Upload the extracted viewer dir:
   ```bash
   # Install rclone with R2 support (https://rclone.org)
   rclone config
   # Choose "s3" provider, "Cloudflare R2" subprovider, paste R2 keys
   
   # Upload
   cd staging_64k   # where viewer.dzi + viewer_files/ live
   rclone copy . cf-r2:buddhabrot-tiles-64k/ --progress
   ```

   Or use AWS CLI (R2 is S3-compatible):
   ```bash
   aws configure --profile cf-r2
   # AWS Access Key ID: <R2 token from Cloudflare dashboard>
   # AWS Secret Access Key: <R2 token secret>
   # Default region: auto
   # Default output format: json
   
   aws s3 cp viewer.dzi s3://buddhabrot-tiles-64k/viewer.dzi \
       --endpoint-url https://<account-hash>.r2.cloudflarestorage.com \
       --profile cf-r2
   aws s3 sync viewer_files/ s3://buddhabrot-tiles-64k/viewer_files/ \
       --endpoint-url https://<account-hash>.r2.cloudflarestorage.com \
       --profile cf-r2
   ```

5. **Configure CORS on the R2 bucket** so the viewer (served elsewhere) can fetch from R2:
   Cloudflare dashboard → R2 → buddhabrot-tiles-64k → Settings → CORS Policy:
   ```json
   [{
     "AllowedOrigins": ["*"],
     "AllowedMethods": ["GET", "HEAD"],
     "AllowedHeaders": ["*"],
     "ExposeHeaders": ["ETag"],
     "MaxAgeSeconds": 3600
   }]
   ```

#### 4.3.2 Cloudflare Pages for viewer.html (free, custom domain)

1. Cloudflare dashboard → Pages → Create application → Direct Upload.
2. Project name: `buddhabrot-viewer-64k`.
3. Upload a single file: `index.html` (the viewer.html from §2.5, but change `tileSources: "viewer.dzi"` to point to your R2 URL):

   ```html
   <!DOCTYPE html>
   <html>
   <head>
     <meta charset="utf-8">
     <title>Buddhabrot 64K</title>
     <style>body { margin: 0; background: #0a0d14; } #osd { width: 100vw; height: 100vh; }</style>
   </head>
   <body>
     <div id="osd"></div>
     <script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
     <script>
       OpenSeadragon({
         id: "osd",
         tileSources: "https://pub-abc123def.r2.dev/buddhabrot-tiles-64k/viewer.dzi",
         prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
         showNavigator: true
       });
     </script>
   </body>
   </html>
   ```

4. Deploy. URL: `https://buddhabrot-viewer-64k.pages.dev/`

5. (Optional) Custom domain: dashboard → Pages → Custom domains → Add. Point a CNAME from your domain at the pages.dev URL.

**Pros:**
- Free for typical traffic levels
- **Zero egress fees** — even if your viewer goes viral, R2 doesn't bill for bandwidth
- Sub-100 ms tile loads globally (Cloudflare CDN)
- Easy custom domain
- Versioned deploys (rollback if you break the viewer)

**Cons:**
- Two pieces to set up (R2 + Pages) vs HF Spaces' one-step
- Custom CORS needed
- Cloudflare account required (free OK)

**Recommendation:** the right answer for 64K-256K viewers. Free for most use cases.

### 4.4 AWS S3 + CloudFront

**When to use:** enterprise/known-traffic settings where AWS billing predictability matters. Otherwise use R2 — same architecture, no egress fees.

**Setup:**

1. Create S3 bucket. AWS Console → S3 → Create bucket.
   - Bucket name: `buddhabrot-viewer-64k`
   - Region: us-east-1 (or your closest)
   - Uncheck "Block all public access"
   - Confirm public access risk

2. Upload viewer.dzi + viewer_files/:
   ```bash
   aws s3 cp viewer.dzi s3://buddhabrot-viewer-64k/viewer.dzi
   aws s3 sync viewer_files/ s3://buddhabrot-viewer-64k/viewer_files/
   ```

3. Bucket policy for public read (in Permissions tab):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "PublicReadGetObject",
       "Effect": "Allow",
       "Principal": "*",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::buddhabrot-viewer-64k/*"
     }]
   }
   ```

4. Bucket CORS (Permissions tab → CORS):
   ```json
   [{
     "AllowedHeaders": ["*"],
     "AllowedMethods": ["GET", "HEAD"],
     "AllowedOrigins": ["*"],
     "ExposeHeaders": ["ETag"]
   }]
   ```

5. CloudFront distribution. Console → CloudFront → Create distribution.
   - Origin: select your S3 bucket
   - Viewer protocol policy: Redirect HTTP to HTTPS
   - Default root object: `index.html`
   - Cache key and origin requests: CachingOptimized
6. Deploy. URL: `https://d1234567890abc.cloudfront.net/`

7. Upload viewer.html (point `tileSources` at CloudFront URL):
   ```html
   tileSources: "https://d1234567890abc.cloudfront.net/viewer.dzi",
   ```

**Cost (approximate):**
- S3 storage: $0.023/GB/month → ~$0.04/mo for 1.6 GB
- S3 GET requests: $0.0004 / 1000 → ~$0.03 per 1000 viewers (~65 tiles per session)
- CloudFront egress: $0.085/GB → ~$0.14 per viewer session at full zoom
- CloudFront requests: $0.01 / 1000 → ~$0.65 per 1000 viewers

**Pros:**
- AWS infrastructure (if you already use AWS)
- Mature, predictable
- Easy to integrate into AWS workflows

**Cons:**
- Egress fees add up — 1000 viewers at full zoom on the 64K = ~$140
- More setup than R2

**Recommendation:** only if you're already on AWS or need its specific features (Lambda@Edge, signed URLs, etc).

### 4.5 GitHub Pages (limited)

**When to use:** simplest possible deploy, you're already using GitHub for the project, viewer is < 1 GB.

**Limits:**
- Repo size soft limit: 1 GB (hard: 5 GB)
- Bandwidth: 100 GB/month
- File size: 100 MB per file (max)

So for 32K viewers (~400 MB tiles) it works. 64K (~1.6 GB) is over the soft limit but under hard. 128K+ does NOT fit.

**Setup:**

1. Create a repo on GitHub: `buddhabrot-viewer-32k` (separate from the renderer code repo).
2. Push the extracted viewer dir:
   ```bash
   cd staging_32k
   git init
   git add viewer.dzi viewer_files/ index.html
   git commit -m "32K viewer"
   git branch -M main
   git remote add origin https://github.com/bochen2029-pixel/buddhabrot-viewer-32k.git
   git push -u origin main
   ```
3. Settings → Pages → Source: Deploy from a branch → main / root → Save.
4. URL: `https://bochen2029-pixel.github.io/buddhabrot-viewer-32k/`

**Pros:**
- Free
- Integrates with the project's GitHub workflow
- Custom domain support

**Cons:**
- 1 GB soft / 100 MB per file — 64K is borderline, 128K+ doesn't fit
- Slower CDN than R2/Cloudfront proper
- Git LFS doesn't work for Pages (LFS files aren't served)
- Pushing 65000 tiny tile files via git is slow

**Recommendation:** use only for ≤ 32K viewers. For everything bigger, use R2 or Spaces.

### 4.6 Self-hosted NGINX (total control)

**When to use:** you have a VM (Hetzner, OVH, EC2) and want maximum control over caching/headers/auth.

**Setup:**

1. Provision a small VM (1 CPU, 2 GB RAM is enough; storage = viewer size).
2. Install NGINX:
   ```bash
   sudo apt update
   sudo apt install -y nginx
   ```
3. Copy viewer files to `/var/www/buddhabrot/`:
   ```bash
   sudo mkdir -p /var/www/buddhabrot
   sudo chown $USER /var/www/buddhabrot
   cd /var/www/buddhabrot
   wget https://huggingface.co/buckets/bochen2079/buddhabrot/resolve/main/viewer.tar
   tar xf viewer.tar
   # Add viewer.html (template from §2.5) as index.html
   ```

4. NGINX config `/etc/nginx/sites-available/buddhabrot`:
   ```nginx
   server {
     listen 80;
     server_name buddhabrot.example.com;
     root /var/www/buddhabrot;
     index index.html;

     # CORS for tile fetches
     location ~ \.(jpg|png|webp|dzi)$ {
       add_header Access-Control-Allow-Origin "*";
       add_header Cache-Control "public, max-age=31536000, immutable";
     }
     
     # Force max-age on HTML for easy iteration
     location = /index.html {
       add_header Cache-Control "public, max-age=300";
     }
   }
   ```
   
   ```bash
   sudo ln -s /etc/nginx/sites-available/buddhabrot /etc/nginx/sites-enabled/
   sudo nginx -t   # test config
   sudo systemctl reload nginx
   ```

5. Get HTTPS via Let's Encrypt:
   ```bash
   sudo apt install -y certbot python3-certbot-nginx
   sudo certbot --nginx -d buddhabrot.example.com
   ```

**Pros:**
- Total control over caching, headers, redirects
- No vendor limits
- Standard tooling

**Cons:**
- You operate the server (updates, monitoring, SSL renewal)
- ~$5-10/month for a small VM
- Bandwidth costs (varies by provider)

**Recommendation:** only if you specifically need NGINX features (auth, geo-blocking, rewrites).

---

## Section 5 — CORS configuration

**What is CORS:** Cross-Origin Resource Sharing — browser security feature that blocks JS on origin A from fetching from origin B unless B explicitly allows it.

**Why it matters:** when viewer.html is on origin A (say `https://example.com`) and tiles are on origin B (`https://pub-abc.r2.dev/...`), the browser blocks the fetches unless B sends `Access-Control-Allow-Origin: *` (or echoes the specific origin).

**When you DON'T need CORS:** viewer.html + viewer.dzi + viewer_files/ all on the SAME origin (HF Spaces, GitHub Pages, single self-hosted server). Browser treats them as same-origin, no CORS needed.

**When you DO need CORS:** viewer.html on one origin (Cloudflare Pages), tiles on another (R2). Or any cross-origin setup.

**Required headers on the tile/dzi origin:**

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, HEAD
Access-Control-Allow-Headers: *
Access-Control-Max-Age: 3600
```

**Per-provider CORS setup:**

| Provider | How to set CORS |
|---|---|
| R2 | Bucket → Settings → CORS Policy (JSON shown in §4.3.1) |
| S3 | Bucket → Permissions → CORS configuration (JSON shown in §4.4) |
| HF Bucket | Public buckets allow all origins by default (no setup needed) |
| HF Spaces | Same-origin (no setup needed) |
| GitHub Pages | Same-origin (no setup needed) |
| NGINX | `add_header Access-Control-Allow-Origin "*"` in location block |

**Common mistake:** setting CORS on the VIEWER origin instead of the TILE origin. CORS is configured on the origin that's BEING fetched FROM, not the one doing the fetching.

**Debugging CORS issues:**

Browser DevTools → Network tab → click on a failed tile fetch → Headers tab. Look at response headers:
- No `Access-Control-Allow-Origin` header → CORS not configured on tile origin
- `Access-Control-Allow-Origin: https://example.com` (specific) and your origin doesn't match → too-restrictive policy
- 200 OK with the header → CORS works, the failure is something else

---

## Section 6 — Performance tuning

### 6.1 Tile size selection

| Tile size | Tile count for 64K | Avg tile bytes | Pros | Cons |
|---|---|---|---|---|
| 256 (default) | ~65000 | ~25 KB | Best for incremental zoom | More HTTP requests |
| 512 | ~16000 | ~85 KB | Fewer requests | More bandwidth per pan |
| 128 | ~260000 | ~8 KB | Smallest payload per request | 4× more requests |

**Recommendation:** 256 for most cases. Bump to 512 if hosting on a slow-RTT provider (where each request has > 100 ms overhead).

### 6.2 JPEG quality

`build_dz_pyramid.py` defaults to JPEG Q=75 (`suffix=".jpg[Q=75]"`). Tradeoffs:

| Q | Size factor | Visible artifacts at 100% zoom |
|---|---|---|
| 60 | 0.7× | Yes, blocking on dim regions |
| 75 (default) | 1.0× | Barely visible on flat regions |
| 85 | 1.5× | None |
| 95 | 2.5× | None (effectively lossless) |
| PNG | 6× | None (lossless) |

For Buddhabrot specifically — dim regions and gradient transitions show JPEG compression artifacts at Q=60 but not Q=75. For a viewer where users will deep-zoom, Q=85 is the safe choice. For a viewer optimized for share-on-social, Q=75 is fine.

**Override at build time:**
```python
img.dzsave("viewer", suffix=".jpg[Q=85]", overlap=0, tile_size=256)
```

### 6.3 Browser cache headers

For tiles, set aggressive caching since the content never changes (tiles are immutable):

```nginx
# NGINX
location ~ \.(jpg|png|webp)$ {
  add_header Cache-Control "public, max-age=31536000, immutable";
}
```

For Cloudflare R2: the Cache-Control header isn't set by default; either:
- Set it per-file at upload time (`aws s3 cp ... --cache-control "max-age=31536000"`)
- Use Cloudflare Page Rule to override (`Cache Level: Cache Everything` + custom Edge Cache TTL of 1 month)

For S3: similarly, set `--cache-control` at upload.

**Impact:** without aggressive tile caching, every pan/zoom re-fetches tiles. With it, the second visit is instant from browser cache.

### 6.4 Preload settings

OpenSeadragon options that affect perceived speed:

```js
OpenSeadragon({
  ...
  preserveViewport: true,
  preserveOverlays: true,
  immediateRender: true,         // don't fade-in tiles, draw immediately
  blendTime: 0,                  // no blend animation
  alwaysBlend: false,
  
  // Preload behavior
  preload: true,                 // start loading tiles at level above current
  
  // Tile cache size
  maxImageCacheCount: 200,       // tiles kept in memory (RAM cost ~200 × 25 KB = 5 MB)
});
```

`maxImageCacheCount: 200` is enough for smooth panning at a single zoom level. Increase if your users zoom-pan rapidly.

### 6.5 Pre-warming the CDN

If you launch a viral share, the CDN has cold caches at all edge nodes. First fetch from each region pays the origin-fetch RTT (could be 500-1000 ms). After a few hundred fetches, the CDN is warm.

To pre-warm Cloudflare R2:
```bash
# Hit all 17 levels of the pyramid from a few global locations
for region in us-east us-west eu-west asia-east; do
  curl -s -o /dev/null \
    https://your-bucket.r2.dev/viewer.dzi \
    -H "CF-IPCountry: <region code>"
done
```

In practice, a viral share to ~1000 viewers will warm the cache organically within minutes.

### 6.6 Mobile pixelDensity (for Retina screens)

OpenSeadragon by default fetches tiles at logical pixel resolution. On a 3× Retina display, this means each rendered pixel is 1/3 of a tile pixel — sharp at 100% zoom but downscale-fuzzy when zoomed out.

To request DPR-aware tiles:
```js
OpenSeadragon({
  ...
  imageLoaderLimit: 8,
  visibilityRatio: 0.8,
});
```

The library handles DPR automatically in v4+. If you see blurry tiles on mobile, upgrade OpenSeadragon to v4 (the canonical viewer.html in §2.5 already uses v4).

---

## Section 7 — Embed options

### 7.1 iframe (simplest)

For external sites that want to embed the viewer:

```html
<iframe
  src="https://buddhabrot-viewer-64k.pages.dev/"
  width="100%"
  height="600"
  frameborder="0"
  allowfullscreen>
</iframe>
```

Pros: zero setup, works anywhere. Cons: doesn't blend with host site styling.

### 7.2 React component

For React sites:

```jsx
import { useEffect, useRef } from "react";

export function BuddhabrotViewer({ src = "https://pub-abc.r2.dev/.../viewer.dzi" }) {
  const containerRef = useRef(null);
  
  useEffect(() => {
    // OpenSeadragon needs to be loaded — add to <head> via CDN, or npm install
    if (!window.OpenSeadragon) return;
    const viewer = window.OpenSeadragon({
      element: containerRef.current,
      tileSources: src,
      prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
      showNavigator: true,
    });
    return () => viewer.destroy();
  }, [src]);
  
  return <div ref={containerRef} style={{ width: "100%", height: "600px", background: "#0a0d14" }} />;
}
```

### 7.3 Standalone fullscreen mode

For "open viewer in new tab" UX, link to the viewer.html directly:

```html
<a href="https://buddhabrot-viewer-64k.pages.dev/" target="_blank">
  Open 64K viewer
</a>
```

The viewer.html is already fullscreen via the CSS in §2.5.

---

## Section 8 — Troubleshooting

### "Tiles don't load" — most common issues

1. **CORS error** (see DevTools console for "Access-Control-Allow-Origin" errors)
   - Fix: configure CORS on the tile origin per §5

2. **404 on tile URLs**
   - Check actual URL in DevTools Network tab
   - Compare against your `viewer.dzi`'s implicit tile paths
   - DZI tile URL format: `<base>/viewer_files/<level>/<col>_<row>.<format>`
   - Fix: ensure your tile origin has files at exactly these paths

3. **viewer.dzi has wrong path/dimensions**
   - Open viewer.dzi in browser, check `Width`/`Height`/`TileSize`/`Format` attributes
   - Mismatch with actual files → 404s
   - Fix: regenerate dzi via libvips dzsave

4. **HTTPS mixed content**
   - viewer.html on https://, tiles on http:// → browser blocks
   - Fix: serve tiles via HTTPS (all major hosting paths do)

### "Some tiles are black/dark/seamed" — see §3.1 (overlap=2 regression)

Check viewer.dzi for `Overlap="0"`. If it says `Overlap="2"` or higher, regenerate the pyramid:

```python
img.dzsave("viewer", suffix=".jpg[Q=75]", overlap=0, tile_size=256)
#                                          ^^^^^^^^^ MUST be 0 for this project
```

### "Image is upside down" — see §3.2

Run `tools/flip_bin.py` on the source `.bin`, regenerate the pyramid from the flipped bin. Don't patch at viewer layer.

### "Blurry at 100% zoom"

- Check `maxZoomPixelRatio` in OSD config (set to 8 to allow zoom past native)
- Check the final level of the pyramid actually exists (count viewer_files/<max>/)
- For Retina displays, ensure OSD v4+ (v3 has DPR bugs)

### "Slow loading on first visit"

- CDN cold start — see §6.5 (pre-warming)
- Check tile cache headers — should be `max-age=31536000`
- Check tile origin RTT from your geo — HF Bucket is slow outside US-East

### "OSD throws error on init"

- Browser console: look for "Could not load tilesource" → check viewer.dzi URL
- Look for "OpenSeadragon is not defined" → CDN failed to load; check Network tab
- Look for syntax error in viewer.html → JSON probably malformed (comma after last property)

### "Tiles load but image is wrong / shows old version"

- Browser cache. Hard refresh (Ctrl+F5 / Cmd+Shift+R).
- Or DevTools → Network tab → check "Disable cache" + reload.
- Or use cache-busting URL: `viewer.dzi?v=2`.
- Or assign a new port (see §3.3).

### "Pinch-to-zoom doesn't work on mobile"

- OSD v4 supports it natively. Check `gestureSettingsTouch` config:
  ```js
  gestureSettingsTouch: {
    scrollToZoom: true,
    clickToZoom: true,
    dblClickToZoom: true,
    pinchToZoom: true,
    flickEnabled: true
  }
  ```

---

## Section 9 — Sharing the viewer

### 9.1 Permanent URL

Use HF Spaces (`*.hf.space`) or Cloudflare Pages with custom domain. These give you a stable URL that doesn't change between renders.

### 9.2 QR code for the URL

For physical sharing (prints, exhibits):

```bash
pip install qrcode
python -c "
import qrcode
img = qrcode.make('https://buddhabrot-viewer-64k.pages.dev/')
img.save('buddhabrot_qr.png')
"
```

### 9.3 Social media OG tags

Add to viewer.html `<head>` so Twitter/X/Discord/Slack show a nice preview:

```html
<meta property="og:title" content="Buddhabrot 64K — deep zoom">
<meta property="og:description" content="Importance-sampled Buddhabrot fractal at 64K resolution. Zoom and pan.">
<meta property="og:image" content="https://buddhabrot-viewer-64k.pages.dev/preview.jpg">
<meta property="og:url" content="https://buddhabrot-viewer-64k.pages.dev/">
<meta name="twitter:card" content="summary_large_image">
```

For the `og:image`, save a 1200×630 JPEG screenshot of the viewer at a representative zoom level.

### 9.4 Twitter/X embed (auto-rendering)

If your domain has proper OG tags, just paste the URL into a tweet — Twitter renders the preview card automatically.

For an interactive embed (the viewer playable inside Twitter), you'd need Twitter Player Cards, which require domain approval. Usually not worth it; the OG card + click-through is sufficient.

### 9.5 Discord embed

Discord renders OG previews by default. Same as Twitter — paste the URL.

For richer Discord behavior (e.g., the viewer playable in a Discord bot's response), use a Discord Webhook with embed JSON pointing at your URL.

---

## Section 10 — Future: 128K and beyond

### 10.1 Tile count math

| Resolution | Tile count (256×256) | Total pyramid size | Per-request cost |
|---|---|---|---|
| 32K | ~16000 | ~400 MB | ~$0 / load |
| 64K | ~65000 | ~1.6 GB | ~$0 / load |
| 128K | ~260000 | ~6 GB | $0.001 / load |
| 256K | ~1.04M | ~25 GB | $0.005 / load (CloudFront), $0 (R2) |
| 512K | ~4.2M | ~100 GB | infeasible without R2 |

Per-load cost = tiles fetched × per-request cost. For a deep-zoom session: ~200 tiles fetched (across all zoom levels visited). With R2 (no egress) and free request tier: $0 per session.

### 10.2 Choosing a host by resolution

| Resolution | Recommended host |
|---|---|
| ≤ 32K | GitHub Pages or HF Spaces |
| 64K (this project's current target) | HF Spaces (free tier) or R2+Pages |
| 128K | R2+Pages (HF Spaces hits 5 GB limit) |
| 256K | R2+Pages (Cloudflare's egress-free + global CDN is the only sane option) |
| 512K+ | R2+Pages + custom shard strategy (split pyramid across buckets) |

### 10.3 CDN bandwidth at viral scale

If your share gets 100K views, each loading ~200 tiles at ~25 KB:
- 100K × 200 × 25 KB = 500 GB total
- Cloudflare R2 cost: $0 (no egress)
- AWS CloudFront cost: $42.50 (at $0.085/GB)
- HuggingFace Bucket cost: $0 (free tier, may rate-limit)
- GitHub Pages cost: $0 but you'll hit the 100 GB/month soft limit at ~50K views

R2 wins decisively at scale.

### 10.4 Pre-warming for known launches

If you announce the viewer on a specific date:

```bash
# 24 hours before launch, hit every L<max-3> tile from several global regions
# This warms the CDN edge cache for the most-viewed zoom levels.

for level in 13 14 15 16; do
  # Programmatically enumerate tile paths at this level
  python -c "
import math
W, H = 65536, 49152
level_w = math.ceil(W / 256 / (2 ** (16 - $level)))
level_h = math.ceil(H / 256 / (2 ** (16 - $level)))
for x in range(level_w):
    for y in range(level_h):
        print(f'$level/{x}_{y}.jpg')
" | xargs -P 8 -I{} curl -s -o /dev/null https://your-cdn/viewer_files/{}
done
```

This isn't necessary in practice — CDNs warm organically — but it's the move if you have a Twitter campaign at a fixed time.

---

## Section 11 — LLM Q&A deep-dive

This section is meant for AI assistants brought in to help with viewer-related tasks. Common questions + the canonical answers.

### Q: Bo wants to host the viewer on Cloudflare. What do I do?

A: Two pieces — R2 for tiles, Pages for HTML. See §4.3 for step-by-step. Key gotchas:
1. Enable R2.dev subdomain on the bucket (Settings → R2.dev subdomain)
2. Configure CORS on R2 (JSON shown in §4.3.1)
3. In viewer.html, change `tileSources` to the R2 URL pointing at `viewer.dzi`
4. Pages serves just the viewer.html

### Q: The viewer shows a black grid at tile boundaries. What broke?

A: Almost certainly `Overlap="2"` (or higher) in viewer.dzi. Required value is `Overlap="0"`. See §3.1 for the full story. Fix: regenerate the pyramid via `python tools/build_dz_pyramid.py --composite-tif composite.tif --output viewer` (which uses overlap=0 by default).

### Q: The image is upside down. How do I rotate it?

A: NOT at viewer layer. Use `python tools/flip_bin.py <source.bin>` to rotate at the histogram level. Then regenerate stitched → composite → pyramid. See §3.2.

### Q: How big does the viewer.tar get?

A: ~1.6 GB for 64K, ~6 GB for 128K, ~25 GB for 256K. See §10.1 for the full table.

### Q: How do I make a public URL?

A: Easiest: HF Spaces (§4.2). Best: Cloudflare R2 + Pages (§4.3). Avoid: paid AWS unless you specifically need it.

### Q: The browser caches old tiles, how do I bust the cache?

A: Three options:
1. Per-cp unique ports for local dev (see §3.3)
2. Cache-busting query string: `viewer.dzi?v=2` in the OSD `tileSources`
3. New URL entirely for new content

### Q: Why is there no overlap and how does compose_blended fit in?

A: `compose_blended.py` does linear-alpha crossfade at apron boundaries BEFORE pyramiding. The output of compose_blended is a single seamless `composite.tif`. The DZI pyramider just slices this without adding any further blending. If you set `Overlap > 0` in DZI, you'd cause the blending to happen TWICE (once at compose, once at DZI), which produces the black grid. See §3.1.

### Q: How do I know if CORS is the issue?

A: Browser DevTools → Network tab → click a failed tile fetch → Response Headers. Look for `Access-Control-Allow-Origin: *`. If absent, CORS is the problem. Configure on the TILE origin (not the viewer origin). See §5.

### Q: The viewer is slow on first load. Why?

A: CDN cold-cache. First fetch from each region's edge node hits the origin. Second visit is fast. Pre-warming (§6.5) helps for known launches. Tile cache headers (`Cache-Control: max-age=31536000`) make repeat visits instant.

### Q: How do I make it work offline?

A: Service Worker that caches viewer.dzi + all of viewer_files/ at first visit. For a 64K pyramid (~1.6 GB) this is borderline — most browsers cap origin storage at 50 GB but warn at 1 GB. For an offline-first 32K viewer, the SW pattern works cleanly.

### Q: Can I show multiple Buddhabrots side-by-side (different cps, or different views)?

A: Yes — OSD supports multiple `tileSources`. See §2.7. Both pyramids pan/zoom in lockstep.

### Q: How do I add overlays (annotations, hotspots)?

A: OSD's `addOverlay` API:
```js
viewer.addOverlay({
  element: document.createElement("div"),  // styled HTML element
  location: new OpenSeadragon.Point(0.5, 0.5),
  placement: OpenSeadragon.Placement.CENTER
});
```
The `Point(x, y)` is normalized — `(0,0)` is top-left, `(1,1)` is bottom-right of the image.

---

## Appendix A — DZI file format spec

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Image xmlns="http://schemas.microsoft.com/deepzoom/2008"
       Format="jpg"
       Overlap="0"
       TileSize="256">
  <Size Width="65536" Height="49152"/>
</Image>
```

| Attribute | Required | Values | Meaning |
|---|---|---|---|
| `xmlns` | Yes | The Microsoft schema URI | Identifies as DZI |
| `Format` | Yes | `jpg`, `png`, `webp` | Tile file extension |
| `Overlap` | Yes | non-negative integer | Pixels duplicated between adjacent tiles (**MUST be 0 for Buddhabrot**) |
| `TileSize` | Yes | positive integer | Tile dimensions in pixels |
| `Size/Width` | Yes | positive integer | Full image width at finest level |
| `Size/Height` | Yes | positive integer | Full image height at finest level |

The pyramid is implicit from `Size` + `TileSize`. Total levels = `ceil(log2(max(W, H)))` + 1.

---

## Appendix B — viewer.html templates per scenario

### B.1 Single image, simple

```html
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Buddhabrot</title>
<style>body{margin:0;background:#0a0d14;}#osd{width:100vw;height:100vh;}</style>
</head><body><div id="osd"></div>
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
<script>OpenSeadragon({id:"osd",tileSources:"viewer.dzi",prefixUrl:"https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",showNavigator:true});</script>
</body></html>
```

### B.2 Single image, fully styled (project canonical — see §2.5)

(Template in §2.5)

### B.3 Two images, side-by-side comparison

```html
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Buddhabrot compare</title>
<style>body{margin:0;background:#0a0d14;}#osd{width:100vw;height:100vh;}</style>
</head><body><div id="osd"></div>
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
<script>
OpenSeadragon({
  id: "osd",
  tileSources: [
    { tileSource: "viewer_cp4130/viewer.dzi", x: 0, y: 0, width: 1 },
    { tileSource: "viewer_cp9280/viewer.dzi", x: 1.05, y: 0, width: 1 }
  ],
  prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
  showNavigator: true,
  collectionMode: false  // both viewports pan/zoom together
});
</script>
</body></html>
```

### B.4 With annotations (info hotspots)

```html
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Buddhabrot annotated</title>
<style>
body{margin:0;background:#0a0d14;}#osd{width:100vw;height:100vh;}
.hotspot{background:rgba(255,255,255,0.3);border:2px solid white;border-radius:50%;width:20px;height:20px;cursor:pointer;}
.hotspot:hover{background:rgba(255,255,255,0.6);}
</style></head><body><div id="osd"></div>
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
<script>
const viewer = OpenSeadragon({
  id: "osd",
  tileSources: "viewer.dzi",
  prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
  showNavigator: true
});
viewer.addHandler("open", () => {
  const annotations = [
    { x: 0.5, y: 0.45, label: "Body cusp" },
    { x: 0.35, y: 0.4, label: "Period-2 bulb" },
    { x: 0.65, y: 0.4, label: "Period-2 bulb (mirror)" }
  ];
  annotations.forEach(ann => {
    const el = document.createElement("div");
    el.className = "hotspot";
    el.title = ann.label;
    el.onclick = () => alert(ann.label);
    viewer.addOverlay({
      element: el,
      location: new OpenSeadragon.Point(ann.x, ann.y),
      placement: OpenSeadragon.Placement.CENTER
    });
  });
});
</script>
</body></html>
```

### B.5 Embedded with custom skin (no toolbar)

```html
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Buddhabrot embed</title>
<style>body{margin:0;}#osd{width:100%;height:100%;}</style></head>
<body><div id="osd"></div>
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
<script>
OpenSeadragon({
  id: "osd",
  tileSources: "viewer.dzi",
  prefixUrl: "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
  showNavigator: false,
  showZoomControl: false,
  showHomeControl: false,
  showFullPageControl: false
});
</script></body></html>
```

---

## Appendix C — Quick command reference

```bash
# Extract viewer from tarball
tar xf viewer.tar
# Now have viewer.dzi + viewer_files/

# Local serve for testing
python -m http.server 8064
# Open http://localhost:8064/viewer.html

# Upload to HF bucket (whole dir)
hf sync . hf://buckets/bochen2079/buddhabrot/viewer_64k_public/ \
    --include "viewer.dzi" --include "viewer_files/*"

# Upload to R2 (after rclone config)
rclone copy . cf-r2:buddhabrot-tiles-64k/ --progress

# Upload to S3
aws s3 sync . s3://buddhabrot-viewer-64k/ --acl public-read

# Push to GitHub Pages
git add . && git commit -m "viewer" && git push

# Re-generate pyramid from a composite TIFF
python tools/build_dz_pyramid.py --composite-tif composite.tif --output viewer

# Fix upside-down bin
python tools/flip_bin.py source.bin source_flipped.bin
```

---

## Appendix D — Versioning the doc

| Date | What changed |
|---|---|
| 2026-05-12 | Initial draft. Sections 1-12 + appendices. |

---

*Last updated: 2026-05-12. Maintainer: Bo Chen. Future AI instances: chunk on `## Section N` for context-budget ingestion; §11 is your Q&A reference.*
