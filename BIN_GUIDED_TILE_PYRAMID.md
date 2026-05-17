# Bin-guided fast-tile pyramid architecture — comprehensive runbook

**Status:** Production. Validated end-to-end on H100 PCIe (Hyperbolic.xyz) 2026-05-12. Bin-guided per-tile rendering with full corrected pipeline (classification + weight floor + apron crossfade + tile-order switch). Reusable guide hierarchy permanently archived on HF.

**Audience:** Bo Chen (project owner) + future Claude/AI instances asked to operate this pipeline. Section 0 is the LLM ingest header — chunk it and paste into any AI to get a guided walkthrough instead of reading 1500 lines.

---

## Section 0 — LLM ingest header (read me first if you're an AI)

### How to use this document with an AI

This doc is structured for AI-assisted operation. Each major section is a coherent unit; chunk on `## Section N` boundaries and the AI gets enough context to answer correctly without the full file.

**Suggested system prompt for the assistant:**

```
You are helping Bo Chen operate the Buddhabrot CUDA tile-pyramid rendering
pipeline. The reference manual is BIN_GUIDED_TILE_PYRAMID.md. Bo prefers
direct, unpadded answers; no apology theater. When he asks how to do X,
give him the exact commands from the runbook, not paraphrases. If a
command requires substitution (paths, GPU counts, sample budgets), show
both the template and a worked example with sensible defaults.

Constraints:
  - Renderer code is at C:\buddhabrot-main\cuda-render-16k\ on his Windows
    box. Cloud pods clone https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu
  - HF bucket: bochen2079/buddhabrot. Token in $HF_TOKEN or ~/.hf_token.
  - Canonical view: center -0.5935417456742, 0.04166264380232; zoom 0.5;
    rotation 90°; sample-radius 2.5. Don't propose alternatives.
  - IS production trims: 0.137/0.098/0.056 (the per-tile defaults).
  - Source-render trims: 0.74/0.74/0.52 (full-frame canonical match).
  - Banned: --target-r/g/b in any script. Banned: uniform-mode trims
    (0.2673/0.2051/0.1270) in production IS renders.
  - When suggesting cloud providers: RunPod Secure or Lambda. Avoid
    RunPod Community (bandwidth-throttled). Hyperbolic works but has
    quirks documented in Section 4.

If asked a question the runbook doesn't answer: say so. Don't invent.
```

### Chunk routing — "I need to..."

| Need | Read section |
|---|---|
| Pick a cloud provider | §4 (Provider walkthroughs) |
| Set up SSH / Web Terminal | §4.1 (RunPod) or §4.3 (Hyperbolic) |
| Bootstrap the renderer on a fresh pod | §4.5 (bootstrap one-liner) |
| Build the binary | §4.6 (compile step) |
| Render a brand new tile pyramid | §5.A (Workflow A) |
| Grow the source bin for cleaner guides | §5.B (Workflow B) |
| Pull viewer to local + view in browser | §5.C (Workflow C) |
| Recover from a crash mid-render | §5.D (Workflow D) |
| Pick the right tile-rendering order | §3.5 (`--tile-order`) |
| Diagnose a slow pod | §4.7 (cloud diagnostics) |
| Free GPU memory after a fine-tune left it pinned | §4.8 (VRAM cleanup) |
| Quick command reference | §7 (Cheatsheets) |
| Why a thing broke | §8 (Known issues) |
| Plan a 128K / 256K / 512K render | §10 (Future directions) |
| Look up a term | §11 (Glossary) |

### File chunks (for token-budgeted ingest)

Approximate chunks at H2 boundaries:

```
Section 0:  this header                         (~600 tokens)
Section 1:  TL;DR + architectural premise        (~700)
Section 2:  Why monolithic hits a wall           (~500)
Section 3:  Four architectural insights          (~1500)
Section 4:  Provider walkthroughs                (~3500)
Section 5:  Operational workflows                (~3000)
Section 6:  Tool reference                       (~1500)
Section 7:  Cheatsheets                          (~2000)
Section 8:  Known issues + fixes                 (~2000)
Section 9:  Performance numbers                  (~800)
Section 10: Future directions                    (~1500)
Section 11: Glossary                             (~600)
Section 12: Reference command snippets           (~1500)
Total:                                          ~19000 tokens
```

Most AI contexts can absorb the full document. Chunk only if you must.

---

## Section 1 — TL;DR

A monolithic 32K or 64K Buddhabrot render spreads samples uniformly across all pixels, hitting a per-pixel-density wall regardless of total resolution. A **per-tile rendering** approach with a **bin-guided importance map** beats it by 2-3× per-pixel sharpness at the same wallclock, and runs **~24× faster per atomic-add** due to L2 cache fit. This document captures the architecture, the four insights that make it work, the toolchain, and the operational procedures across two cloud providers.

The full corrected pipeline produces a seamless OpenSeadragon-ready tile pyramid in **~95 minutes on an H100 PCIe**, with output that's measurably sharper than a 32K monolithic render that took 24 hours.

**Headline numbers (validated 2026-05-12 on H100 PCIe at Hyperbolic):**

- 256-tile (16×16 grid) 64K stitched render: ~75 min render + 20 min post-processing
- Per-tile throughput: 262 M/s aggregate (vs 11-12 M/s monolithic) = 22× speedup
- Final viewer.tar size: ~1-2 GB (DZI pyramid, OpenSeadragon-ready)
- Reusable guide hierarchy: 2.1 GB total (4K / 8K / 16K / 32K), permanent archive
- Cost on Hyperbolic H100: ~$3-5 for end-to-end run

---

## Section 2 — Why monolithic hits a wall

Three compounding factors limit monolithic Buddhabrot rendering past 32K:

| Factor | Mechanism |
|---|---|
| **Atomic contention** | 19 GB histogram (32K × 24K × 3 × uint64) doesn't fit in any cache. Every `atomicAdd(uint64)` bounces to HBM3 with ~400 cycle latency. Throughput caps around 11-12 M/s on H100. |
| **Sample dilution** | At 24h wallclock = 920 B samples / 800 Mpx = 1140 traj/px native — sounds reasonable, but heavy-tailed orbit distribution means filament pixels see far fewer effective samples than the average suggests. |
| **No focus** | Every sample is treated equally regardless of where its orbit lands. Bright-region pixels and noise-floor pixels get the same sample budget. |

The result: you can throw 24 hours of H100 at 32K and still see visible Monte Carlo noise when you deep-zoom. Going to 64K monolithic spreads the SAME samples across 4× more pixels — empty resolution, not detail.

---

## Section 3 — The four architectural insights

### 3.1 Per-tile L2 cache locality (the real reason this works)

When the histogram fits in L2 cache (50 MB on H100), atomic adds resolve in cache instead of HBM. **4K tiles produce a ~19 MB stride-relevant working set that's L2-resident**, vs a 32K monolithic's 19 GB that thrashes the cache 100% of the time.

Measured throughput on H100 PCIe:

| Workload | Throughput | Bottleneck |
|---|---|---|
| 32K monolithic IS | 11-12 M/s | HBM atomic latency |
| 8×8 = 64 tiles @ 4K each | ~50 M/s/tile aggregate | Some cache misses |
| **16×16 = 256 tiles @ 4K each** | **262 M/s/tile aggregate** | **L2 hot working set** |

**22× speedup from the same kernel, just smaller histograms.** This is not parallelism — it's algorithmic. You cannot replicate this efficiency by throwing more GPUs at a monolithic workload.

### 3.2 Per-tile view-aware IMap with bin-guided weighting

Each tile renders a sub-region of the canonical view (e.g., 1/256 of c-space at 16×16 grid). Three importance-map options:

| IMap | Resolution per c-area | IS efficiency |
|---|---|---|
| Canonical orbit-length (`imap.bin`) | Sparse — 1024² cells over full disk | Same as monolithic |
| View-aware (`--build-view-imap`) | Concentrated — 1024² cells over the tile's c-region (64× higher per-area) | 2-3× better than canonical |
| **Bin-guided view-aware** (`--guide-bin guide_*.gbin`) | Same 1024² cells but weighted by the guide's brightness | **3-5× better** for visually-important regions |

The bin-guided variant uses a previously-rendered high-quality `.bin` (downsampled) as a **prior over image-space importance**. During IMap construction, each viewport-hit's contribution to its c-cell is weighted by `guide[orbit_landing_pixel]`. C-values whose orbits hit bright pixels (per the guide) get amplified IMap weight. Result: samples concentrate where they produce visible output.

### 3.3 Tile classification (prevents over-concentration)

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

### 3.4 Weight floor in the kernel (smooths tile-tile discontinuities)

Even bright-classified tiles can have within-tile regions where the guide is zero. The kernel's `--guide-min-weight N` parameter ensures every viewport-hit contributes at least `N` to its IMap cell:

```c
unsigned int w = (guide[pixel] >> 8);  // top-8-bits: range [0, 255]
if (w < guide_min_weight) w = guide_min_weight;  // floor: baseline coverage
weighted_hits += w;
```

Default for tile pyramids: 8. Tunable 0-64. Zero = pure bin-guided (artifact-prone for tile pyramids); higher = smoother but reduces concentration benefit.

### 3.5 Tile rendering order (`--tile-order`) — crash resilience

**Added 2026-05-12, commit `5275a15`.** Today's run hit a GPU fault state at tile #199 (r13c09) that required mass-stubbing 38 tiles to recover. Under row-major (default) ordering the crashed region was bottom-right empty background — acceptable. If the crash had hit a body-region tile instead, ~50% of the visible artifact would be missing.

**Inversion:** render the bright/structural tiles first so a mid-run crash leaves the empty corners unrendered (acceptable) rather than the body cusp (catastrophic).

`tools/render_fast_tiles.py --tile-order {naive,brightness,spiral,brightness-spiral}`

| Strategy | Behavior | Use when |
|---|---|---|
| `naive` (default) | row-major top-to-bottom left-to-right | unchanged existing behavior |
| `brightness` | DESC by guide region max — body cusp first, empty last | **best for crash-resilience** |
| `spiral` | ASC by distance from brightness-weighted centroid | center-out radial; single-mode brightness only |
| `brightness-spiral` | top 25% by brightness, remainder by spiral from centroid | hybrid for multi-modal images |

All non-naive modes require `--guide-bin`. Falls back to naive with WARN if guide unavailable. Works for both serial (`--num-gpus 1`) and parallel (`--num-gpus N`) paths — submission order into the ThreadPoolExecutor determines which tiles get STARTED first.

**Recommendation:** use `brightness` on long renders or on shared/preemptible hardware. Use `naive` for short renders where order doesn't matter.

---

## Section 4 — Cloud provider walkthroughs

The Buddhabrot pipeline runs on any Linux GPU box with CUDA 12.6+ (Blackwell sm_120 inclusion). Two providers are documented in detail; a third is referenced for capacity overflow.

### 4.1 RunPod Secure Cloud (RECOMMENDED for production)

**Why:** dedicated tenancy means no shared-HBM contention. Web Terminal eliminates SSH key drama. Pricing is competitive.

**Pricing (May 2026):**

| GPU | Tier | $/hr | Notes |
|---|---|---:|---|
| H100 PCIe | Secure | $2.49 | best $/perf for tile renders |
| H100 SXM5 | Secure | $3.49 | NVLink, marginal benefit for single-tile workload |
| H200 SXM5 | Secure | $3.99 | 141 GB HBM3e — overkill for tiles, useful for 64K monolithic |
| H100 PCIe | Community | $1.99 | **AVOID — shared HBM, throttled** |

**Step-by-step from zero:**

1. Sign up at https://www.runpod.io. Add ~$20 of credit (covers ~6 hr of H100 work).
2. Console → Deploy → GPU Pod.
3. Select **H100 PCIe** in **Secure Cloud** (not Community).
4. Template: `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04` — the `-devel` suffix is critical (runtime images lack nvcc).
5. Storage: 200 GB container volume + 0 GB persistent. Tile renders fit in 100 GB; 200 gives margin.
6. Optional: tick "Expose TCP Ports" + paste your SSH pubkey if you want SSH access. Skip it for Web Terminal-only.
7. Deploy. Wait ~2 min for boot.
8. Click "Connect" → "Start Web Terminal". Browser-based bash shell opens.

**Web Terminal access is enough for everything.** No SSH key dance. File transfers go via HF bucket, not SCP.

### 4.2 RunPod Community Cloud — AVOID for Buddhabrot

**Verified 2026-05-08:** H100 SXM5 80GB HBM3 reported 100% GPU util but only **146 W power draw out of 700 W cap (21%)**. Diagnosis: shared HBM bandwidth with other tenants; SMs idle waiting on atomic writes. Observed throughput **12.1 M/s** vs estimated 40-60 M/s.

The atomic-bound Buddhabrot kernel is exactly the workload that exposes shared-tenancy bandwidth contention. **Community Cloud's lower price is a false economy** — you pay $1/hr less and get 3-4× slower throughput.

For non-bandwidth-bound work (compile, dev, single-GPU LLM inference) Community is fine. Buddhabrot, no.

### 4.3 Hyperbolic.xyz (works, with quirks)

**Why use it:** sometimes RunPod Secure has no H100 capacity. Hyperbolic has 8×H100s available when RunPod doesn't.

**Pricing (May 2026):** 1× H100 SXM ~$2/hr, 8× ~$16/hr. Per-second billing.

**Quirks documented in the K0 LESSONS_LEARNED audit (memory file):**

| Quirk | Workaround |
|---|---|
| Single SSH key slot per account | Use Web Terminal (browser) — equivalent to SSH. |
| Non-root user (`ubuntu`) by default | All commands work without `sudo`; `sudo apt install tmux` if needed. |
| Network interface is `ens3` not `eth0` | Mostly invisible; only matters if you script `ip route` checks. |
| No systemd inside container | `service` commands fail; use `nohup` for background work. |
| `screen` exits with `[screen is terminating]` on stock image | Use `tmux` instead (preinstalled on most templates). Alternative: `SCREENDIR=~/.screen screen -d -m -S name cmd`. |
| `pip install` may fail with PEP 668 "externally-managed-environment" | Pass `--break-system-packages` flag. Bootstrap script auto-detects. |
| `git pull --ff-only` fails after `chmod +x` marks files dirty under default `core.filemode=true` | Bootstrap script sets `git config core.filemode false` BEFORE pull, with `fetch+reset --hard` fallback. |
| GitHub Raw URLs are cached at Fastly edges with 5-min TTL | Bootstrap script adds `?ts=$(date +%s)` cache-bust query parameter. |
| Background HF sync nohup'd from Web Terminal can die when terminal closes | Use `tmux new -d -s syncloop` to host the sync loop instead of plain `nohup`. |

**Bootstrap on Hyperbolic:**

```bash
# In Web Terminal:
curl -sSL "https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash
cd ~/buddhabrot-cuda-multigpu
```

The bootstrap clones the repo, installs `hf` CLI, sets git filemode, runs `./build.sh` to compile the CUDA binary. Takes ~3 min on a fresh pod.

### 4.4 Lambda Labs (third option, capacity overflow)

- 1× H100 PCIe: $2.49/hr (matches RunPod Secure)
- 1× H100 SXM5: $3.29/hr
- 1× H200 SXM5: $3.99/hr (often capacity-constrained, check region dropdown)

**SSH UX:** standard. Add pubkey in account settings; auto-injected into instances. Connect with `ssh ubuntu@<ip>` (default user is `ubuntu`).

**No browser shell.** SSH is the only access path. Use Lambda when you've already got working keys and capacity is your only constraint.

### 4.5 Bootstrap one-liner (any provider)

```bash
export HF_TOKEN=$(cat ~/.hf_token)   # or: hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export HF_BUCKET=bochen2079/buddhabrot

curl -sSL "https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash
cd ~/buddhabrot-cuda-multigpu
```

The script handles RunPod and Hyperbolic uniformly — privilege detection, pip break-system-packages probe, git filemode workaround, build the binary.

After bootstrap:

```bash
./buddhabrot --help | head -30   # verify binary works
ls -la imap.bin                   # verify canonical IMap is present (4 MB)
nvidia-smi --query-gpu=name,power.draw,memory.used --format=csv,noheader
```

If `nvidia-smi` shows power draw < 30% during a render later, you're on a throttled node — switch providers.

### 4.6 Build step (after bootstrap)

The bootstrap script runs `./build.sh` automatically, but if you pull new code:

```bash
cd ~/buddhabrot-cuda-multigpu
git pull
./build.sh   # ~30 sec on H100 with nvcc 12.4+
```

**Important:** after any `git pull` that touches `src/main.cu`, you MUST `./build.sh` again. The compiled `./buddhabrot` is gitignored — pulling code doesn't rebuild it. If a new flag (e.g., `--guide-min-weight`) is unrecognized, that's a stale-binary symptom.

### 4.7 Cloud diagnostics — power draw is the tell

Before launching a long render, verify the GPU isn't throttled:

```bash
nvidia-smi --query-gpu=name,power.draw,power.limit,utilization.gpu,memory.used --format=csv,noheader
```

| Reading | Meaning | Action |
|---|---|---|
| Power < 30% of cap, util 0% | Idle, fine | Proceed |
| Power 50-70% of cap, util > 95% during render | Real compute work | All good |
| **Power < 30% of cap, util > 95% during render** | **Memory-bandwidth-bound on shared HBM** | **Switch providers** |
| `nvidia-smi: command not found` | Wrong template | Redeploy with `-devel` template |

The 21% power-cap reading on RunPod Community Cloud is the canonical signature of shared-tenancy throttling. You cannot fix this with kernel parameters; the kernel is correctly atomic-bound. Move pods.

### 4.8 VRAM cleanup (after a prior fine-tune left memory pinned)

PyTorch holds GPU allocations until process exit, not on `del model` or `model.cpu()`. If you reuse a pod that just ran an LLM fine-tune:

```bash
nvidia-smi --query-gpu=memory.used --format=csv,noheader
# If > 1000 MiB, something else is holding memory.

# Find the offender
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# Kill it
pkill -f python   # or specific PID
sleep 2
nvidia-smi --query-gpu=memory.used --format=csv,noheader   # should now be < 200 MiB
```

The `run-32k-h100-24h.sh` script does this pre-flight automatically and aborts with BIG WORDS if VRAM is held.

---

## Section 5 — Operational workflows

### 5.A Workflow A: New tile pyramid from existing source

You have a 32K `.bin` on the pod (or in HF) and want a v2 tile pyramid render.

**Prereqs:**

1. Source `.bin` on disk: `buddhabrot_cloud_32k_h100_24h.cp*.bin` (or downloaded from HF)
2. Guide hierarchy: `guide_4k.gbin` / `guide_8k.gbin` / `guide_16k.gbin` / `guide_32k.gbin` (or downloaded from HF artifacts_v1/)
3. Built `./buddhabrot` binary with `--guide-bin` and `--guide-min-weight` support

**Pull missing artifacts from HF if needed:**

```bash
export HF_TOKEN=$(cat ~/.hf_token)
hf auth login --token "$HF_TOKEN"
hf sync hf://buckets/bochen2079/buddhabrot/ . \
    --include "buddhabrot_cloud_32k_h100_24h.cp9280.bin" \
    --include "artifacts_v1/guide_*.gbin"
mv artifacts_v1/guide_*.gbin .   # move to working dir for direct access
```

**Run the pipeline:**

```bash
# Default 16×16 grid at 4K per tile = 64K stitched output
GUIDE=guide_4k.gbin bash run-fast-tiles-blended-h100.sh

# Higher quality: use bigger guide and brightness ordering for crash-resilience
GUIDE=guide_8k.gbin \
TILE_ORDER=brightness \
bash run-fast-tiles-blended-h100.sh
```

(Note: `TILE_ORDER` env passthrough requires a 1-line edit in the launcher — see §6 for the snippet, or commit `5275a15` to enable.)

**What happens in the launcher (5 steps):**

1. Render 256 tiles (auto-syncs to HF as they land) — ~75 min on H100
2. `stitch_tiles.py --keep-apron` — produces per-tile TIFFs with 64-px apron retained — ~5 min
3. `compose_blended.py` — linear-alpha crossfade at apron overlaps → single composite TIFF — ~5 min — **needs 200+ GB RAM at 64K** (see §8.2)
4. `build_dz_pyramid.py --composite-tif` — libvips dzsave → DZI tile pyramid — ~5 min
5. `tar` + `hf sync` → uploads `viewer.tar` (~1-2 GB) to HF

Total: ~95 min. Output: `tiles_v2_h100/viewer.tar` on HF.

**Config knobs (env vars):**

| Var | Default | What it does |
|---|---|---|
| `GRID` | `16x16` | tile grid dimensions (cols × rows) |
| `RESOLUTION` | `4096x3072` | per-tile pixels (multiplied by grid = final dims) |
| `SECONDS_PER_TILE` | `60` | wallclock budget per tile |
| `THROUGHPUT_EST` | `12` | M samples/sec estimate (H100=12, H200=15-20, 4070 Ti=7) |
| `GUIDE` | `guide_4k.gbin` | guide file for bin-guided IS |
| `OUTPUT_DIR` | `tiles_v2_h100` | tile output directory |
| `APRON` | `64` | overlap pixels per side (for crossfade) |
| `TRIM_R/G/B` | `0.137/0.098/0.056` | tonemap trims (per-tile defaults) |
| `CLASSIFY_THRESHOLD` | `2000` | dim tiles below this use canonical IMap |
| `GUIDE_MIN_WEIGHT` | `8` | kernel floor for bin-guided weights |

### 5.B Workflow B: Grow the source for better guides

You want denser guides (cleaner SNR) for future renders.

```bash
# On any H100 pod
bash resume_to_grow_source.sh
# Resumes latest cp.bin, grows toward 1.5T samples (override via TARGET_SAMPLES).
# ~14 hr on H100 to go from 641B → 1.5T.

# Then regenerate the guide hierarchy from the cleaner source
bash generate_guide_hierarchy.sh
```

Source per-pixel σ drops from 3.5% (at 641B) to 2.3% (at 1.5T). All guide variants benefit proportionally. The new guides upload to HF in `artifacts_v1/` namespace (overwriting if same path) — they ARE the render cheat asset.

### 5.C Workflow C: Local pull + view in browser

After a pod run completes, on your local Windows box:

```powershell
cd C:\buddhabrot-main\cuda-render-16k

# Pull the viewer tarball
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "tiles_v2_h100/viewer.tar"

# Extract
cd tiles_v2_h100
tar xf viewer.tar
# Now viewer.dzi + viewer_files/ are local
```

Create `viewer.html` next to `viewer.dzi`:

```html
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Buddhabrot 64K</title>
<style>body{margin:0;background:#0a0d14;}#osd{width:100vw;height:100vh;}</style>
</head><body><div id="osd"></div>
<script src="https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"></script>
<script>OpenSeadragon({
    id:"osd",
    tileSources:"viewer.dzi",
    prefixUrl:"https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/images/",
    showNavigator:true,
    showZoomControl:true,
    showHomeControl:true,
    minZoomLevel:0.5,
    maxZoomPixelRatio:8
});</script>
</body></html>
```

Serve locally (DZI tiles need HTTP, can't be opened as file://):

```powershell
python -m http.server 8064
# Browser → http://localhost:8064/viewer.html
```

Different ports for different renders avoids browser tile-cache confusion (cp4130 viewer artifact). Use `8064` for 64K, `8128` for 128K, etc.

### 5.D Workflow D: Recovery from crash mid-render

**Scenario:** render dies at tile N of M with one of:

- `CUDA ERROR: device busy or unavailable` (today's GPU fault)
- `out of memory` (kernel ran out of HBM)
- Pod was preempted / shutdown timer expired
- Local crash, ssh disconnect

**Step 1 — diagnose:**

```bash
cd tiles_v2_h100
ls -1 r*.bin | wc -l    # how many tiles completed
# Compare to grid: 256 for 16×16, 64 for 8×8
```

**Step 2 — choose recovery strategy:**

| Diagnosis | Strategy |
|---|---|
| Pod alive, GPU healthy | Re-run launcher with same OUTPUT_DIR — skip-if-exists logic resumes |
| Pod alive, GPU fault state (persistent CUDA errors) | Mass-stub missing tiles (below) — skip GPU, run CPU-only pipeline |
| Pod dead | Spin new pod, sync state from HF, re-run launcher with same OUTPUT_DIR |
| Many tiles missing in specific region | Targeted re-render those tiles only (see §5.D.3) |

**Step 2a — Resume (GPU still works):**

```bash
# The launcher's skip-if-exists logic handles this automatically.
GUIDE=guide_4k.gbin bash run-fast-tiles-blended-h100.sh
# Skipped tiles print "already exists, skipping"; missing tiles re-render.
```

**Step 2b — Mass-stub (GPU is hosed):**

This is the recovery path used 2026-05-12 when r13c09 onward kept failing with `device busy`. Copy a known-good neighbor as a stand-in:

```bash
cd tiles_v2_h100
STUB=r13c08   # known good tile near the bad region
for j in 13 14 15; do
    for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
        target=r${j}c${i}
        if [ ! -f $target.bin ]; then
            cp ${STUB}.bin $target.bin
            cp ${STUB}.png $target.png 2>/dev/null
            echo "stubbed $target"
        fi
    done
done
cd ..

# Now re-run launcher; stubs are treated as completed tiles, pipeline proceeds
# to stitch/compose/dzsave (CPU-only, no GPU needed).
GUIDE=guide_4k.gbin bash run-fast-tiles-blended-h100.sh
```

**Caveats of mass-stubbing:**

- Stubbed tiles will be visibly wrong if they're in a high-detail region — the stub neighbor's content gets pasted into the wrong viewport
- Acceptable when the stubbed region is empty background (corners, edges)
- NOT acceptable if you stub a body-cusp tile — use `--tile-order brightness` to ensure body cusp tiles are rendered first specifically to avoid this

**Step 2c — Spin new pod + sync state from HF:**

```bash
# On new pod:
curl -sSL "https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash
cd ~/buddhabrot-cuda-multigpu

# Pull existing tile state
export HF_TOKEN=$(cat ~/.hf_token)
hf auth login --token "$HF_TOKEN"
mkdir -p tiles_v2_h100
hf sync hf://buckets/bochen2079/buddhabrot/tiles_v2_h100/ tiles_v2_h100/ \
    --include "r*.bin" --include "r*.png" --include "tile_spec.json"

# Also pull the guide
hf sync hf://buckets/bochen2079/buddhabrot/ . \
    --include "artifacts_v1/guide_4k.gbin"
mv artifacts_v1/guide_4k.gbin .

# Resume from HF state
GUIDE=guide_4k.gbin bash run-fast-tiles-blended-h100.sh
```

**Step 3 — verify recovery succeeded:**

```bash
ls -1 tiles_v2_h100/r*.bin | wc -l   # should be 256 for 16×16
ls -lh tiles_v2_h100/viewer.tar      # should exist after full pipeline
```

### 5.E Workflow E: Generate guide hierarchy from scratch

If you need the four guide resolutions and they're not on HF yet:

```bash
# Source bin must exist (cp9280 or similar)
ls -lh buddhabrot_cloud_32k_h100_24h.cp*.bin

bash generate_guide_hierarchy.sh
# Produces guide_4k/8k/16k/32k.gbin from the latest cp.bin.
# Uploads all four to hf://buckets/bochen2079/buddhabrot/artifacts_v1/
# Total: 2.1 GB. Runtime: ~10 min on any box (CPU-only Python).
```

### 5.F Workflow F: Pyramid recovery from saved state (the COMPOSE OOM workaround)

**Scenario:** render completed, stitch completed, but `compose_blended.py` died with OOM (today's 64K case — 170 GB peak vs 180 GB pod RAM).

```bash
# State already on HF as tiles_v2_state.tar (108 GB tarball with stitched/ TIFFs)
# Spin a 256+ GB RAM box (NOT a GPU box — this is CPU-only work).

# Pull state
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "tiles_v2_state.tar"
tar xf tiles_v2_state.tar

# Resume from compose_blended
python3 tools/compose_blended.py \
    --stitched-dir tiles_v2_h100/stitched \
    --output composite.tif

# Continue with dzsave
python3 tools/build_dz_pyramid.py \
    --composite-tif composite.tif \
    --output viewer

# Bundle + upload
tar cf viewer.tar viewer.dzi viewer_files/
hf sync . hf://buckets/bochen2079/buddhabrot/ --include "viewer.tar"
```

**Alternative (no fat-RAM box available):** rewrite `compose_blended.py` to stream-write the composite tile-by-tile instead of in-memory accumulation (~50 LOC). Not yet implemented as of 2026-05-12; flagged in §10 future directions.

---

## Section 6 — Tool reference

### 6.1 Source generation

| Tool | Purpose |
|---|---|
| `./buddhabrot` (rendered) | The CUDA renderer. Produces `.bin` + `.png` per run. |
| `run-32k-h100-24h.sh` | Monolithic 32K render, 24h budget — generates the SOURCE for guides. |
| `resume_to_grow_source.sh` | Resume an existing 32K `.bin` to grow it toward a higher sample target. Cleaner source = cleaner guides. |
| `run-64k-h200.sh` | 64K monolithic launcher (legacy; tile pyramid path is preferred). |

### 6.2 Guide generation

| Tool | Purpose |
|---|---|
| `tools/downsample_bin.py <bin> <gbin> --factor N` | Downsample a `.bin` to a uint16 single-channel guide. Factor 8 = 32K→4K, factor 1 = no downsample. |
| `generate_guide_hierarchy.sh` | Produce all four guide resolutions from the latest cp.bin on disk. Upload to HF in `artifacts_v1/`. |

### 6.3 Tile-pyramid rendering

| Tool | Purpose |
|---|---|
| `tools/render_fast_tiles.py` | Render NxM grid of tiles. Supports `--guide-bin`, `--classify-threshold`, `--guide-min-weight`, `--tile-order`, multi-GPU, HF auto-sync. |
| `tools/stitch_tiles.py` | Per-tile global-R_max tonemap + write 16-bit TIFFs. Use `--keep-apron` for the blended pipeline. |
| `tools/compose_blended.py` | Linear-alpha crossfade at apron overlaps. Produces single seamless composite TIFF. **WARNING: 200+ GB RAM at 64K composite.** |
| `tools/build_dz_pyramid.py` | libvips dzsave to produce DZI tile pyramid. `--composite-tif` for single-input mode, `--stitched-dir` for legacy arrayjoin. |

### 6.4 Launchers (orchestrators)

| Script | Pipeline |
|---|---|
| `run-fast-tiles-h100.sh` | (deprecated, has tile-seam artifacts) renders + stitch (no blend) → pyramid |
| **`run-fast-tiles-blended-h100.sh`** | **(v2, corrected)** full pipeline with classification + weight floor + compose_blended + dzsave + upload |

**To pass --tile-order through the launcher**, add this snippet to `run-fast-tiles-blended-h100.sh` after the existing env-var section:

```bash
# Pass tile-order through (default 'naive' = unchanged behavior)
export TILE_ORDER="${TILE_ORDER:-naive}"

# Then in the python3 tools/render_fast_tiles.py call, add:
#   --tile-order "$TILE_ORDER" \
```

(I haven't pre-modified the launcher to keep "don't change existing code" intact. Apply this when you want to use brightness ordering.)

### 6.5 Utilities

| Tool | Purpose |
|---|---|
| `tools/build_viewer_package.py` | Generate OpenSeadragon viewer HTML + DZI from a single `.bin` (alternate path) |
| `tools/download_from_hf.ps1` / `.sh` | Bulletproof large-file download from HF buckets via `hf sync` (avoids browser/BITS failures) |
| `tools/flip_bin.py` | 180° rotate a `.bin` in-place at the math level (fixes orientation without runtime `--flip` hack) |
| `tools/quality_report.py` | Per-channel max + percentile + density-correct trim derivation from a `.bin` |
| `tools/retune_trims.py` | Iterative tonemap-only loop over a `.bin` to find trims that match a reference's percentiles |

---

## Section 7 — Cheatsheets

### 7.1 HF bucket commands

```bash
# Auth (do this once per session)
export HF_TOKEN=$(cat ~/.hf_token)   # or set explicitly
hf auth login --token "$HF_TOKEN"
hf auth whoami                        # must echo username, not "Not logged in"

# List bucket contents (verify what's there)
hf buckets list bochen2079/buddhabrot

# Upload (sync)
hf sync . hf://buckets/bochen2079/buddhabrot/ \
    --include "*.bin" --include "*.png" --include "*.log"

# Download a specific file
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "viewer.tar"

# Background auto-sync loop (every 10 min during a long render)
nohup bash -c '
while true; do
    hf sync . hf://buckets/bochen2079/buddhabrot/ \
        --include "*.bin" --include "*.png" --include "*.log" 2>&1 | tail -3
    sleep 600
done
' > /tmp/hf_loop.log 2>&1 &
disown

# Stop the loop
pkill -f "hf sync.*buddhabrot"
```

**Common errors:**

- `Error: 'bucket' is not one of 'model', 'dataset', 'space'` — you used `hf upload --repo-type bucket`. Wrong tool. Use `hf sync` with the `hf://buckets/...` URL form.
- `Not logged in` from `hf auth whoami` — token wasn't actually written. Re-run `hf auth login` and check stderr (don't `2>/dev/null`).
- BITS / browser download fails at 50% — single-stream HTTP. Use `hf sync` CLI instead; it uses HF's chunked API with transparent retry.

### 7.2 tmux cheatsheet (for long renders)

```bash
# Start a named session
tmux new -s render

# Detach from session (render keeps running)
Ctrl-b d

# Reattach
tmux attach -t render

# List sessions
tmux ls

# Kill a session
tmux kill-session -t render

# Scroll mode (read previous output)
Ctrl-b [          # enter scroll mode
PgUp / PgDown     # scroll
q                 # exit scroll mode
```

### 7.3 nvidia-smi diagnostic snippets

```bash
# One-shot snapshot
nvidia-smi

# CSV format (scriptable)
nvidia-smi --query-gpu=name,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv,noheader

# Watch live (updates every 1 sec)
watch -n 1 nvidia-smi

# Per-process GPU memory (find the offender)
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# Throughput sanity check during render (should match expectation)
# H100 doing real Buddhabrot work: ~600 W power draw, > 95% util
# H100 throttled on shared HBM: ~150 W, > 95% util (BAD)
```

### 7.4 Disk-space planning

| Artifact | Size | Per 16×16 grid |
|---|---|---|
| Per-tile `.bin` (4096×3072 × uint64 × 3) | ~302 MB | 77 GB |
| Per-tile `.png` (4096×3072 PNG) | ~65 MB | 17 GB |
| Per-tile imap.bin (1024² uint32) | 4 MB | 1 GB |
| Stitched TIFFs (16-bit, apron retained) | ~78 MB | 20 GB |
| Composite TIFF (64K × 49K × 16-bit RGB) | ~19 GB | 19 GB |
| DZI pyramid (output of dzsave, JPEG tiles) | ~1.5 GB | 1.5 GB |
| **Total disk on pod (rendering)** | | **~135 GB** |
| `viewer.tar` (final shippable artifact) | | ~1.6 GB |
| `tiles_v2_state.tar` (full pod state for recovery) | | ~108 GB |

**Recommendation:** 200 GB container storage on pod is the minimum. 500 GB if you want to keep multiple cp.bin checkpoints.

### 7.5 --tile-order quick reference

```bash
# Default — no change
python3 tools/render_fast_tiles.py [args] --tile-order naive

# Recommended for crash-resilience on long/preemptible runs
python3 tools/render_fast_tiles.py [args] --guide-bin guide_4k.gbin --tile-order brightness

# Center-out radial (single bright concentration assumed)
python3 tools/render_fast_tiles.py [args] --guide-bin guide_4k.gbin --tile-order spiral

# Hybrid — top 25% by brightness, remainder spiral
python3 tools/render_fast_tiles.py [args] --guide-bin guide_4k.gbin --tile-order brightness-spiral
```

Strategies require `--guide-bin`. If guide unavailable, falls back to naive with WARN.

### 7.6 Build / rebuild

```bash
# Initial build
cd ~/buddhabrot-cuda-multigpu
./build.sh

# After git pull (REQUIRED if main.cu changed)
git pull
./build.sh

# Verify the build supports new flags
./buddhabrot --help | grep -E "guide-min-weight|tile-order"
# (--tile-order is in render_fast_tiles.py, not the binary; --guide-min-weight is in the binary)

# Force-rebuild from scratch
rm buddhabrot
./build.sh
```

### 7.7 One-liner recovery (paste-ready)

```bash
# Full recovery from HF state to deliverable, on a fat-RAM box (256+ GB):
export HF_TOKEN=$(cat ~/.hf_token)
hf auth login --token "$HF_TOKEN"
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "tiles_v2_state.tar"
tar xf tiles_v2_state.tar
python3 tools/compose_blended.py --stitched-dir tiles_v2_h100/stitched --output composite.tif
python3 tools/build_dz_pyramid.py --composite-tif composite.tif --output viewer
tar cf viewer.tar viewer.dzi viewer_files/
hf sync . hf://buckets/bochen2079/buddhabrot/ --include "viewer.tar"
```

### 7.8 Cost ledger

| Operation | Provider | Wallclock | Cost |
|---|---|---|---|
| 32K source bin (initial) | RunPod H100 Secure | 24 hr | ~$60 |
| Grow source 641B → 1.5T | H100 | ~14 hr | ~$50 |
| Guide hierarchy generation | any (CPU) | ~10 min | ~$0 |
| 64K tile pyramid (today's run) | Hyperbolic H100 | ~1.5 hr | ~$3 |
| 128K tile pyramid (projected) | H100 | ~5 hr | ~$10 |
| 256K tile pyramid (projected) | H100 | ~20 hr | ~$40 |
| Compose_blended recovery (fat-RAM CPU box) | any 256GB-RAM | ~30 min | ~$1-5 |

---

## Section 8 — Known issues + fixes

### 8.1 64K renders produced corrupt histograms (FIXED)

**Root cause:** kernel int32 overflow in pixel indexing. At 64K resolution, `pixels × 3 = 9.66 G` exceeds `unsigned int` max (4.29 G). The histogram-write address wraps around, causing the bottom half of the image to overwrite the top half's memory.

**Fix:** commit `894f4cb` — changed all relevant indexing variables in `main.cu` from `unsigned int` to `size_t` (5 sites total: `increment_pixel_channel`, `sum_pixels_kernel`, `compute_max_kernel`, `tonemap_kernel`, `save_image` launch math).

**Bit-identical at 32K** — `size_t` arithmetic gives same results as `unsigned int` when values fit. **Functional at 64K and beyond.**

### 8.2 compose_blended.py OOM at 64K (KNOWN LANDMINE)

**Discovered 2026-05-12.** The compose step loads all stitched TIFFs, builds a float32 accumulator at full composite resolution, and a float32 alpha buffer at the same size. Memory peak:

- 64K composite at float32 RGB: `65536 × 49152 × 3 × 4 bytes = 38 GB` (accumulator)
- Float32 alpha buffer: same size = `12 GB` (single-channel)
- 256 input TIFFs cached during the pass: ~20 GB
- Python/tifffile overhead: ~10 GB

**Peak memory: ~170 GB.** Killed by OOM on a 180 GB pod after writing all 256 blended-tile contributions to the accumulator but before serializing the composite TIFF.

**Current workaround:** rent a 256+ GB RAM box for the compose step. The state is preserved as `tiles_v2_state.tar` on HF (~108 GB).

**Proper fix (TODO):** rewrite compose_blended.py to stream-write the composite tile-by-tile to a TIFF tiled-write file, instead of accumulating in memory. ~50 LOC of `tifffile.TiffWriter` with `tile=(256,256)`. Filed in §10 future directions.

### 8.3 GPU fault mid-render (MASS-STUB RECOVERY)

**Today's symptom (2026-05-12):** at tile 199 of 256, `[CUDA ERROR] set device alloc: CUDA-capable device(s) is/are busy or unavailable`. Persisted after `pkill -f buddhabrot` and `nvidia-smi` reset attempts. The GPU was in a wedged state that required pod reboot to clear — but pod reboot was minutes away from scheduled shutdown.

**Recovery:** mass-stubbed the missing 38 tiles by copying a known-good neighbor's `.bin`/`.png` into the missing slots, then re-ran the launcher. The skip-if-exists logic treated the stubs as completed; the pipeline proceeded through stitch/compose/dzsave on CPU only. See §5.D.2b for the exact commands.

**Caveat:** stubbed tiles show their stub-source content in the wrong viewport, so this works ONLY if the stubbed tiles are empty background. The bottom-right corner (r13c09 onward in the 16×16 grid at canonical view) is empty for the canonical Buddhabrot composition — acceptable.

**Prevention:** use `--tile-order brightness` to render body cusp tiles FIRST. Any subsequent crash is biased toward empty regions. Today's row-major ordering put the crash at exactly the empty region by chance; brightness ordering makes this the guaranteed case.

### 8.4 HF browser/BITS downloads fail at ~50% (FIXED)

**Root cause:** HuggingFace Bucket resolve URLs are CDN-fronted. Long-lived TCP connections get reset by ISPs or HF edge nodes. Browsers and `Invoke-WebRequest` / `Start-BitsTransfer` all use single-stream HTTP and lack proper resume.

**Fix:** `hf sync` CLI uses HF's chunked API (small per-request bytes, transparent retry, resumable). Documented in `HF_DOWNLOAD.md`. Also: tar-bundle whole pyramids into single files for one-shot upload/download (avoids per-file HTTP overhead which destroys throughput at 65K+ tile counts).

### 8.5 Bin-guided IMap created tonal islands at tile boundaries (FIXED)

**Root cause:** bin-guided weighting amplifies existing density inequality. Adjacent tiles can have wildly different effective brightness distributions, producing visible per-tile averages at low pyramid zoom levels (16×16 dot pattern).

**Fix:** commits `ef29229` + `64b2d90` — two orthogonal fixes:

1. `--classify-threshold N` in `render_fast_tiles.py`: tiles with `max(guide_region) < N` use canonical IMap (uniform-ish coverage)
2. `--guide-min-weight N` in `main.cu`: kernel floor ensures every viewport-hit contributes at least N to its IMap cell

### 8.6 Hard cuts at tile boundaries in stitched output (FIXED)

**Root cause:** `stitch_tiles.py --keep-apron` retains aprons, but the actual crossfade is done by a separate tool (`compose_blended.py`) which was never run in the original pipeline.

**Fix:** `run-fast-tiles-blended-h100.sh` runs the full pipeline including `compose_blended.py` between stitch and dzsave. Plus `build_dz_pyramid.py` gained `--composite-tif` mode to take the single blended composite as input.

### 8.7 stitch_tiles.py filename mismatch (FIXED)

**Root cause:** `render_fast_tiles.py` writes tiles as `r07c07.bin`, but `stitch_tiles.py` was looking for `tile_r07c07.bin` (legacy convention from `tile_orchestrate.py`).

**Fix:** commit `8d3af5b` — drop the `tile_` prefix in stitcher.

### 8.8 Stale binary after git pull (OPERATIONAL)

**Root cause:** `./buddhabrot` is gitignored. `git pull` updates `src/main.cu` but does not rebuild. New CLI flags appear in source but fail with "unrecognized option" at runtime.

**Symptom:** `--guide-min-weight: unknown option` (or any new flag).

**Fix:** always `./build.sh` after `git pull`. The bootstrap one-liner does this; manual pulls don't.

### 8.9 RunPod Community Cloud bandwidth throttling (OPERATIONAL)

**Symptom:** 100% GPU util but 21% power draw; throughput 3-4× below estimated.

**Fix:** redeploy on Secure Cloud or Lambda. Cannot be fixed in software. See §4.2.

### 8.10 Hyperbolic non-root user / no systemd (OPERATIONAL)

**Symptoms:** `sudo: not found` for some commands; `service X start` fails; `screen` exits with `[screen is terminating]`.

**Fix:** use `tmux` instead of `screen`; bootstrap script handles `--break-system-packages` probe; nohup for background work. All documented in §4.3 quirks table.

---

## Section 9 — Performance numbers (validated)

### 9.1 Throughput

| Workload | Throughput | Per-pixel density @ 60s/tile |
|---|---|---|
| 32K monolithic IS (H100) | 11-12 M/s | 0.66 traj/px in 60s (~50 traj/px in 24h) |
| 4K tile @ bin-guided (H100) | 262 M/s | **60 traj/px in 60s** |
| 8K tile @ bin-guided (H100) | ~180 M/s | 14 traj/px in 60s |
| 4K tile @ canonical IMap (H100) | ~50 M/s | 12 traj/px in 60s |
| Source render (uniform mode, 4070 Ti) | 192 M/s | n/a — uniform mode is deprecated |

### 9.2 Wallclock (16×16 grid, 60s/tile, H100 PCIe)

| Stage | Time |
|---|---|
| Render 256 tiles | ~75 min |
| Stitch (per-tile tonemap → TIFF) | ~5 min |
| Compose_blended | ~5 min (CPU; OOM at 64K on < 200 GB RAM) |
| Build DZI pyramid (libvips dzsave) | ~5 min |
| Tar + HF upload | ~3 min |
| **Total** | **~95 min** |

### 9.3 Storage usage (per-render)

| Artifact | Size |
|---|---|
| Source 32K `.bin` (cp9280, 622 B samples) | 18 GB |
| Guide hierarchy (4K/8K/16K/32K) | 2.1 GB total (one-time, reusable forever) |
| 256 tile `.bin` files (4K each) | ~77 GB |
| 256 tile `.png` files | ~17 GB |
| Stitched TIFFs (apron retained) | ~20 GB |
| Composite TIFF (64K, 16-bit RGB) | ~19 GB |
| `viewer.tar` (DZI pyramid) | ~1.6 GB |
| Peak transient (during compose_blended) | ~170 GB RAM (not disk) |

---

## Section 10 — Future directions

### 10.1 128K stitched (next obvious step)

Same pipeline, 8K tiles instead of 4K:

```bash
GRID=16x16 RESOLUTION=8192x6144 GUIDE=guide_16k.gbin \
    bash run-fast-tiles-blended-h100.sh
```

Expected: ~5 hr on H100, 128K stitched output, 240 traj/px native per tile, 17 OSD zoom levels.

Composite at 128K × 96K × float32 RGB = ~152 GB accumulator alone. **Requires streaming compose rewrite or 512+ GB RAM box.**

### 10.2 256K stitched (the leverage limit before source upgrade)

16×16 grid at 16K tiles. Per-tile compute fits H100 80 GB easily. Stitched composite TIFF is ~38 GB — needs disk planning.

```bash
GRID=16x16 RESOLUTION=16384x12288 GUIDE=guide_16k.gbin \
    bash run-fast-tiles-blended-h100.sh
```

Expected: ~20 hr on H100. 18 OSD zoom levels.

Past 256K stitched, `guide_16k` is too coarse (multiple tile pixels per guide pixel). Either generate a denser source `.bin` first (via `resume_to_grow_source.sh`) or accept the guide-resolution ceiling.

### 10.3 512K+ requires denser source

Per-pixel guide noise (3.5% σ at cp9566) becomes the limiter. Path:

1. Grow source to 2-3 T samples (~28 hr H100)
2. Re-generate `guide_32k.gbin` from cleaner source
3. Then 512K stitched becomes tractable

### 10.4 Streaming compose_blended rewrite (KNOWN TODO)

**Today's compose_blended.py is memory-bound at 64K** — needs 200+ GB RAM. The proper fix is a tile-streaming TIFF writer:

```python
# Pseudocode
with tifffile.TiffWriter("composite.tif", bigtiff=True) as tw:
    for tile_y in range(0, composite_H, 256):
        for tile_x in range(0, composite_W, 256):
            # For each composite tile, identify which input tiles overlap
            # this output tile, load only those, blend in-memory at 256×256
            # scale (not full composite scale), write tile.
            tile_output = blend_for_output_tile(tile_x, tile_y, ...)
            tw.write(tile_output, tile=(256, 256))
```

Reduces peak memory from O(composite_size) to O(tile_size × n_overlapping_inputs) — maybe 100 MB instead of 170 GB. ~50 LOC of `tifffile` API work. Filed for future implementation.

### 10.5 Multi-view ambition (NOT NEAR-TERM)

The current architecture is hardcoded to the canonical Buddhabrot view (center `-0.5935417456742, 0.04166264380232`, zoom 0.5, rotation 90°). For zoom-into-features renders (e.g., deep zooms into specific filaments), the guide derived from canonical wouldn't help — would need to render new source for each new view.

**Not a near-term goal.** The canonical view is the artifact target.

### 10.6 Hybrid sampling for body brightness (B12 redux)

IS efficiency at body cusp is near-unity. To match a uniform-reference's body brightness without IS density-gap drift, the architecturally-correct answer is hybrid sampling: uniform pass for body density + IS pass for filament SNR, merged. CLAUDE.md §B12 documents this.

Currently the pipeline runs pure IS. The body cusp is bright enough at production densities not to need this; flag for future quality-tier work.

---

## Section 11 — Glossary

| Term | Meaning |
|---|---|
| **Apron** | Overlap pixels around a tile's native viewport, used for crossfade blending at tile boundaries. Default 64 px each side. |
| **bin** | Raw uint64 histogram dump from the renderer. The irreplaceable artifact — PNGs are derivative. |
| **Bitterli IS** | Importance sampling architecture from Benedikt Bitterli's 2014 paper. Uses a learned importance map (`imap.bin`) to concentrate samples on long-orbit c-values. |
| **bin-guided IMap** | View-aware IMap weighted by an image-space brightness prior (the guide). Concentrates samples on visually-important regions. |
| **canonical IMap** | The base orbit-length-weighted IMap (`imap.bin`) computed over the full sampling disk. View-agnostic. |
| **canonical view** | The user-accepted Buddhabrot composition: center -0.5935417456742, 0.04166264380232; zoom 0.5; rotation 90°; sample radius 2.5. |
| **classify threshold** | `--classify-threshold N` — tiles whose guide region max is below N use canonical IMap; brighter tiles use bin-guided. Prevents tonal islands. |
| **compose_blended** | The crossfade step that converts apron-retained per-tile TIFFs into a single seamless composite TIFF via linear-alpha blending. Memory-heavy (see §8.2). |
| **DZI** | Deep Zoom Image — Microsoft's pyramid tile format for browser-based zoomable images. OpenSeadragon renders these natively. |
| **gbin** | Single-channel uint16 downsampled guide file. 32-byte header + W×H×uint16 body. Produced by `tools/downsample_bin.py`. |
| **guide** | A previously-rendered `.bin` (or downsample) used as a brightness oracle for bin-guided IS or for `--tile-order` ranking. |
| **guide min weight** | `--guide-min-weight N` — floor for bin-guided IMap kernel weights. Ensures dim viewport regions still get baseline sampling. |
| **HIST_SCALE** | Integer precision factor for the histogram. uint64 hist absorbs `1/p(c)` IS weights without overflow. |
| **IMap** | Importance Map — 1024² uint32 table of per-c-cell sampling weights. Vose alias-method draws from this in the kernel. |
| **L2 hot working set** | Memory access pattern small enough to fit in the GPU's L2 cache (50 MB on H100). Atomic adds resolve in cache instead of HBM. |
| **monolithic** | Single-pass rendering at full output resolution, vs tiled rendering at per-tile resolution. |
| **OpenSeadragon** | JavaScript library for browser deep-zoom of DZI/IIIF/etc. pyramids. |
| **per-tile L2 locality** | The reason tile rendering is 22× faster per atomic-add than monolithic on H100 — smaller histogram = cache-resident. |
| **R_max** | Maximum per-channel pixel histogram count. Tonemap denominator. |
| **tile classification** | Decision per-tile whether to use canonical IMap or bin-guided IMap, based on guide-region brightness. See §3.3. |
| **tile order** | The sequence in which the grid of tiles gets rendered. `--tile-order brightness` etc. See §3.5. |
| **trims** | `--trim-r/g/b` — top-percentile fraction discarded from the tonemap; controls highlight rolloff. |
| **uniform mode** | Pre-2026-05-08 sampling regime — samples drawn uniformly from a disk in c-space. Known-failed for filaments (snow noise pathology). Deprecated. |
| **view-aware IMap** | An IMap built from samples whose orbits land in the tile's viewport (not full image). 64× higher c-space resolution per tile. |

---

## Section 12 — Reference command snippets

### 12.1 Full end-to-end from fresh pod

```bash
# === On the pod (Web Terminal or SSH) ===

# 1. Bootstrap (one-liner with cache-bust)
curl -sSL "https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash
cd ~/buddhabrot-cuda-multigpu

# 2. Set env
export HF_TOKEN=$(cat ~/.hf_token)   # or: hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export HF_BUCKET=bochen2079/buddhabrot
hf auth login --token "$HF_TOKEN"

# 3. Pull guide hierarchy + (if needed) source bin
mkdir -p artifacts_v1
hf sync hf://buckets/$HF_BUCKET/ . \
    --include "artifacts_v1/guide_*.gbin"
mv artifacts_v1/guide_*.gbin .

# 4. (Optional) pull existing source bin for re-grading or for guide-regen
hf sync hf://buckets/$HF_BUCKET/ . \
    --include "buddhabrot_cloud_32k_h100_24h.cp9280.bin"

# 5. Verify build
./buddhabrot --help | grep -E "guide-bin|guide-min-weight"

# 6. Launch tile pyramid (inside tmux for safety)
tmux new -s render bash -c "
GUIDE=guide_4k.gbin \
GRID=16x16 \
RESOLUTION=4096x3072 \
SECONDS_PER_TILE=60 \
THROUGHPUT_EST=12 \
OUTPUT_DIR=tiles_v2_h100 \
bash run-fast-tiles-blended-h100.sh 2>&1 | tee /tmp/render.log
"

# 7. Detach: Ctrl-b d. Reattach: tmux attach -t render
```

### 12.2 Re-run only the post-pipeline (compose/dzsave/upload) on fat-RAM box

```bash
# All tiles already on HF; just need to assemble
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "tiles_v2_state.tar"
tar xf tiles_v2_state.tar

python3 tools/compose_blended.py \
    --stitched-dir tiles_v2_h100/stitched \
    --output composite.tif

python3 tools/build_dz_pyramid.py \
    --composite-tif composite.tif \
    --output viewer

tar cf viewer.tar viewer.dzi viewer_files/
hf sync . hf://buckets/bochen2079/buddhabrot/ --include "viewer.tar"
```

### 12.3 Quality regression check (compare cps)

```bash
# Compare percentile distribution across cp checkpoints to detect drift
python3 tools/quality_report.py \
    buddhabrot_cloud_32k_h100_24h.cp9280.bin \
    buddhabrot_cloud_32k_h100_24h.cp9566.bin
# Outputs p50/p99/p99.99/p99.999 per channel + R_max ratios.
# Drift > 15% on any percentile = halt + diagnose.
```

### 12.4 Trim retune from a .bin (cheap iteration, no GPU)

```bash
# Iterate trims until percentile match against a reference
python3 tools/retune_trims.py \
    --bin buddhabrot_local_16k_80min.bin \
    --reference-stats reference_calibration.json \
    --output retoned.png
# Each iteration: ~50 sec at 16K (CPU-only tonemap). 5-10 iterations to converge.
```

### 12.5 Build view-aware IMap manually (debugging)

```bash
# Sometimes you want the IMap as an inspection artifact, not auto-built in pipeline
./buddhabrot \
    --build-view-imap test_imap.bin \
    --width 4224 --height 3200 \
    --view-center-x -0.5935417456742 --view-center-y 0.04166264380232 \
    --zoom 4.5 --rotation-deg 90 --sample-radius 2.5 \
    --imap-samples 500000000 \
    --iter-r 2000 --iter-g 200 --iter-b 20 \
    --devices 1 \
    --guide-bin guide_4k.gbin \
    --guide-min-weight 8
# Output: test_imap.bin (~4 MB). Inspect with hexdump or load in Python.
```

### 12.6 Verify pod is healthy before launching long render

```bash
nvidia-smi --query-gpu=name,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv,noheader

# Expected on idle H100:
# NVIDIA H100 PCIe, 70 W, 350 W, 0 %, 200 MiB, 81920 MiB

# Expected on busy H100 doing real work (during render):
# NVIDIA H100 PCIe, 350 W, 350 W, 99 %, 19500 MiB, 81920 MiB

# Red flag — shared-tenant throttle:
# NVIDIA H100 PCIe, 75 W, 350 W, 99 %, 19500 MiB, 81920 MiB
# (Util 99% but power 75 W out of 350 W cap = SMs idle on HBM)
```

### 12.7 Resume an interrupted render (skip-if-exists)

```bash
# Same launcher, same OUTPUT_DIR. The skip-if-exists logic in render_fast_tiles.py
# treats existing r*.bin files as completed and only renders the missing ones.
GUIDE=guide_4k.gbin OUTPUT_DIR=tiles_v2_h100 bash run-fast-tiles-blended-h100.sh
```

### 12.8 Pull viewer for local display

```powershell
# On Windows
cd C:\buddhabrot-main\cuda-render-16k
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "tiles_v2_h100/viewer.tar"
cd tiles_v2_h100
tar xf viewer.tar
# Save viewer.html (template in §5.C) next to viewer.dzi
python -m http.server 8064
# Browser → http://localhost:8064/viewer.html
```

---

## Appendix A — Artifact inventory on HF (`bochen2079/buddhabrot`)

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

tiles_v2_h100/                           (today's run, partially stub-recovered)
├── r*.bin r*.png               same convention
├── stitched/                   (apron-retained TIFFs; load-bearing for compose)
├── tile_spec.json              (geometry manifest)
└── (viewer.tar pending compose recovery)

viewer_fast_64k.tar             ~1.6 GB  OpenSeadragon DZI pyramid for 64K result
                                          (deprecated path; has tile seams)
viewer_fast_64k.dzi             207 B    (manifest, if .tar not used)
viewer_fast_64k_files/                   (pyramid tiles, if .tar not used)

tiles_v2_state.tar              108 GB   FULL pod state from 2026-05-12 OOM event
                                          (recovery seed for compose on fat-RAM box)

buddhabrot_cloud_32k_h100_24h.cp*.bin    Source 32K bins at various sample budgets
                                          (cp9280 = 622B samples = current source)
```

**Why the `.bin` files matter most:** they're the raw uint64 histograms. The PNG and viewer pyramid are derivative — any trim values, any tonemap, any future viewer technology can be re-derived from the `.bin`s. The `.png` files are debug outputs.

---

## Appendix B — Key insights to internalize

1. **Resolution alone is not quality.** A 64K monolithic at 1 hr is empty pixels around the same content as a 32K monolithic at 1 hr. Per-tile rendering at the visualization scale produces meaningful detail.

2. **The `.bin` is the load-bearing artifact.** PNGs are derivative. Anything you might want to do later (re-tonemap, re-tile, denoise, etc.) is possible from the `.bin`s. Treat them as the durable asset.

3. **The guide is reusable forever.** Once generated from a high-quality source, it powers any future tile pyramid render of the same view. The 1.6 GB `guide_32k.gbin` is the highest-leverage single asset on HF.

4. **L2 cache fit is the architectural fork.** Below ~50 MB working set, atomic adds resolve in cache and throughput skyrockets. Above that, you're bandwidth-bound. Choose tile sizes accordingly.

5. **Bin-guided IS has a downside.** Over-concentration creates tonal islands. Fix at two layers: tile classification (binary decision) + weight floor (continuous smoothing). Both should be active for tile pyramids.

6. **Tar-bundle for HF transfers.** Per-file HTTP overhead destroys throughput when you have 65K+ tiny files. Bundle into a single tar, transfer at ~100 MB/s, extract locally.

7. **Power draw is the cloud-provider tell.** 100% util + low power = shared HBM contention. Cannot be fixed in software. Move pods.

8. **Render bright tiles first.** Crashes mid-run are inevitable. `--tile-order brightness` ensures the partial artifact is recognizable, not catastrophic.

9. **Compose is the memory wall, not render.** Render is HBM-bound (need GPU); compose is system-RAM-bound (need 200+ GB at 64K). Plan the recovery box separately from the render box.

10. **Don't bundle improvements with scaling.** Per CLAUDE.md §B2 — if a render works at scale N, only change the scale parameter when going to N+1. Convenience features go in separate sessions.

---

## Appendix C — References

- `CLAUDE.md` — project operating contract, architectural invariants, banned patterns
- `BUILD_LOG.md` — per-session change log (rolling)
- `HF_DOWNLOAD.md` — how to reliably download large files from HF
- `cloud_render_plan.md` — detailed wallclock arithmetic, dimensional audit
- Bitterli (2014) — "The Buddhabrot" — importance map architecture
- Munafo's mu-ency catalog — methodology baseline
- Project repo: https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu

---

## Appendix D — Change log for this document

| Date | What changed |
|---|---|
| 2026-05-12 (initial) | TL;DR + architecture + 3 workflows + perf numbers |
| 2026-05-12 (today's update) | Added LLM ingest header (§0); provider walkthroughs (§4 RunPod + Hyperbolic + Lambda + diagnostics); `--tile-order` flag (§3.5, §7.5); compose OOM landmine (§8.2); GPU fault recovery (§8.3, §5.D); cheatsheets section (§7); glossary (§11); reference snippets (§12); artifact inventory (Appendix A) updated for tiles_v2_state.tar |

---

*Last updated: 2026-05-12 evening. Validated on H100 PCIe @ Hyperbolic.xyz. Pipeline produces seamless 64K OpenSeadragon viewer in ~95 min (assuming sufficient RAM for compose).*

*Maintainer: Bo Chen (bochen2029@gmail.com). Future Claude/AI instances: this doc is your context for the project; chunk it on `## Section N` boundaries.*
