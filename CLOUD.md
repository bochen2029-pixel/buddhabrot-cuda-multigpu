# Cloud render — 8× H200/H100 × 32K × 80-min on Hyperbolic.xyz

This document is the operational runbook for the canonical cloud render. It covers:

- The wallclock and sample-budget arithmetic
- Pre-flight dimensional audit (CLAUDE.md §B13)
- Trim prediction for 32K @ 2 T IS
- One-shot bootstrap on a fresh Hyperbolic instance
- Adaptive H100/H200 detection (no smoke test required — checkpoints are the safety net)
- Background HuggingFace bucket sync for crash recovery
- SIGUSR1 graceful-terminate handler (90-min hard cap)

---

## Quickstart

On your laptop:
```
ssh -i ~/.ssh/hyperbolic_key ubuntu@<instance-ip>
```

On the Hyperbolic instance:
```
curl -sSL "https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash
cd ~/buddhabrot-cuda-multigpu
export HF_TOKEN=hf_...           # for background checkpoint sync
./run-cloud-hyperbolic.sh
```

The `?ts=$(date +%s)` is a cache-bust: GitHub Raw URLs are fronted by Fastly with 5-min per-edge TTL; within 5 min of a push, edge nodes may serve the previous version. Timestamp query string is part of Fastly's cache key but ignored by GitHub. Omit if you know the bootstrap hasn't changed in the last 10 min.

That's it. Bootstrap takes ~2 min (build + IMap). Render takes 80 min. Watchdog enforces 90-min hard cap. Each checkpoint .bin (~19 GB) syncs to your HuggingFace bucket in the background.

---

## Wallclock budget arithmetic

Goal: 32K (32768 × 24576 = 805 Mpx) at 2 T IS samples in 80 min, hard cap 90 min.

```
WALLCLOCK_TARGET     = 80 min × 60 = 4,800 sec
WALLCLOCK_HARD_CAP   = 90 min × 60 = 5,400 sec  (margin: 600 sec → SIGUSR1 at T-300, SIGTERM at T-0)
SAVE_OVERHEAD        = 4 saves × 250 sec = 1,000 sec
                       (PNG encode @ 32K: 200s + .bin write 19.3 GB / 500 MB/s NVMe: 39s + ~10s host CPU)
COMPUTE_TIME_BUDGET  = 4,800 - 1,000 = 3,800 sec
```

Per-GPU throughput estimate (Hopper, IS, atomic-bound at 32K):

| GPU      | FP32   | HBM BW   | est. throughput | aggregate (8x at 0.96) |
|----------|-------:|---------:|----------------:|-----------------------:|
| H200 SXM5| 67 TF  | 4.8 TB/s | 50 M/s          | 384 M/s                |
| H100 SXM5| 67 TF  | 3.35 TB/s| 40 M/s          | 307 M/s                |
| A100 SXM | 19 TF  | 2.0 TB/s | 18 M/s          | 138 M/s                |

```
target_samples (350 M/s plan)  = 3,800 × 350M = 1.33 T
target_samples (550 M/s opt)   = 3,800 × 550M = 2.09 T
target_samples (250 M/s pess)  = 3,800 × 250M = 0.95 T
```

**Default target: 2 T IS samples.** If the GPU runs slower than projected, SIGUSR1 fires at T-300s and the renderer saves whatever it has — the .bin enables retune from any progress level.

---

## Per-pixel density audit (B13 mandatory)

```
pixel_count_32K   = 32768 × 24576 = 805,306,368
density_32K_2T    = 2.0T / 805M   = 2,484 traj/pixel
density_16K_ref   = 1024B / 200M  = 5,120 traj/pixel    (uniform reference)
```

At 2T IS at 32K, density is **49% of reference**. With IS efficiency:
- ε_filament ≈ 50× → effective filament density = 24× of reference (filaments crush)
- ε_body ≈ 1.5× → effective body density = 73% of reference (body slightly dim, retune from .bin closes gap)

This is a major step toward reference body density vs the 16K local run (5% body-effective). At 2T, body matches reference within ~30% — well within retune range.

---

## Trim prediction (the load-bearing math)

Trial calibration anchor (16K @ 2.1B IS, measured):
```
count_p50 / R_max (R/G channels)  =  0.00220
count_p50 / R_max (B channel)     =  0.00207
R_max scaling exponent x          =  0.612 (sub-linear, pre-asymptotic)
```

Cross-resolution invariance:
```
count_p50 / R_max  ∝  N^(1-x)  =  N^0.388       (resolution-independent — pixel_area cancels)
```

Scaling from trial (N=2.1B) to cloud target (N=2T):
```
N_ratio  = 2.0T / 2.1B = 952
factor   = 952^0.388   = 14.3
```

Predicted count_p50/R_max at 32K @ 2T:
- R/G:  0.00220 × 14.3 = 0.0315
- B:    0.00207 × 14.3 = 0.0296

Reference targets (γ=4 inverted from 16K_blue.png):
```
t_target_R (D=29) = 0.0294
t_target_G (D=41) = 0.0427
t_target_B (D=65) = 0.0707
```

Predicted trims (`trim = (count/R_max) / t_target`):
```
trim_R  =  0.0315 / 0.0294 = 1.07  →  clamped to 1.00
trim_G  =  0.0315 / 0.0427 = 0.738
trim_B  =  0.0296 / 0.0707 = 0.419
```

**Final values: 1.00 / 0.74 / 0.42** (close to original 4K IS calibration, sanity-checked).

---

## Full parameter table (default)

| Flag                    | Value                                  |
|-------------------------|----------------------------------------|
| `--width`               | 32768                                  |
| `--height`              | 24576                                  |
| `--samples`             | 2,000,000,000,000 (2 T)                |
| `--devices`             | 8                                      |
| `--samples-per-thread`  | 32 (Linux, no TDR)                     |
| `--launches-per-round`  | 16                                     |
| `--checkpoint-every`    | 117 rounds (4 saves)                   |
| `--imap`                | imap.bin (4 MB)                        |
| `--iter-r/g/b`          | 2000 / 200 / 20                        |
| `--view-center-x/y`     | -0.5935417456742 / 0.04166264380232    |
| `--zoom`                | 0.5                                    |
| `--rotation-deg`        | 90                                     |
| `--sample-radius`       | 2.5                                    |
| `--trim-r/g/b`          | 1.00 / 0.74 / 0.42                     |
| `--output`              | buddhabrot_cloud_32k_2T.png            |
| `.bin` auto-on          | yes (resumability + retune)            |

VRAM per device at 32K: ~21 GB (19.3 GB hist + 1.7 GB working). Fits H100 80 GB and H200 141 GB easily.

---

## Adaptive H100/H200 detection

`run-cloud-hyperbolic.sh` detects GPU at startup:
```bash
case "$GPU_FIRST" in
    *H200*) PER_GPU_MS=50 ; GPU_TIER="H200" ;;
    *H100*) PER_GPU_MS=40 ; GPU_TIER="H100" ;;
    *A100*) PER_GPU_MS=18 ; GPU_TIER="A100" ;;
    *)      PER_GPU_MS=20 ; GPU_TIER="UNKNOWN" ;;
esac
```

H100 and H200 are both sm_90 (Hopper) — **same binary, no rebuild needed**. The binary is built as a fat-binary covering sm_80/86/89/90 for emergency Ampere fallback.

---

## Watchdog: SIGUSR1 graceful-terminate

`_supervise-cloud.sh` polls every 5 sec. Timeline:

| Time          | Action                                                      |
|---------------|-------------------------------------------------------------|
| T+0           | Render starts                                               |
| T+5,100s (85m)| SIGUSR1 fires; main.cu sets g_terminate_requested           |
|               | At next round boundary, render breaks out of loop           |
|               | save_image() runs (.png + .bin written)                     |
|               | Process exits 0                                             |
| T+5,400s (90m)| If still running: SIGTERM                                   |
| T+5,460s      | If still running: SIGKILL (ungraceful, but .bin from last cp survives) |

The SIGUSR1 handler is implemented in main.cu. POSIX-only — Windows builds skip it.

---

## HuggingFace bucket sync (background)

`_supervise-cloud.sh` watches the output directory every 5 sec. When a new checkpoint .bin appears (atomic-renamed from .tmp), it kicks `hf upload` in the background.

```
hf upload --repo-type bucket bochen2079/buddhabrot \
    buddhabrot_cloud_32k_2T.cp0117.bin \
    buddhabrot_cloud_32k_2T.cp0117.bin \
    --commit-message "watchdog cp 2026-05-08T..."
```

Each .bin is ~19.3 GB. At 100 Gbit Hyperbolic uplink, theoretical upload is 24 sec; realistic ~3-5 min. Runs concurrently with next render round — does NOT block compute.

Final outputs (.png, .bin, logs) sync at end. Watchdog waits up to 600s for background syncs to complete before exiting.

If `HF_TOKEN` is unset or `hf` CLI is missing, sync is silently skipped — render continues.

---

## Cost analysis

Hyperbolic.xyz pricing (2026-05-08):
```
$3.73 / GPU-hr × 8 GPUs = $29.83 / hr
free_credit = 1h 46m × $29.83 = $52.66 of credit available
target_run  = 80 min × $29.83 = $39.78    (under credit)
hard_cap    = 90 min × $29.83 = $44.75    (under credit, under $50 CLAUDE.md cost-approval threshold)
+ build/imap/upload overhead ~10 min = $4.97
total worst-case = $49.72                  (within free credit)
```

---

## Failure modes and recovery

1. **Throughput estimate wrong.** SIGUSR1 fires at T-300s; partial render saved with however many samples accumulated. Trim retune via `tools/retune_trims.py` against the .bin recovers tone at any sample count.

2. **NVLink topology not full.** Logged as WARN but not blocking. Multi-GPU merge slows down (peer copies via PCIe-PHB ~32 GB/s vs NV12+ 900 GB/s); at 19.3 GB × 7 peer copies, that's 4 sec vs 0.15 sec — adds 4 sec per checkpoint. Negligible.

3. **HF upload fails.** Background; renderer does NOT block. Check `*.hfsync.log` in working dir.

4. **Instance preempted.** Resume on next instance: `scp` the latest cp.bin from HF bucket to new instance, set `RESUME_ARG="--resume-from buddhabrot_cloud_32k_2T.cpNNNN.bin"`, re-run `./run-cloud-hyperbolic.sh`. The watchdog auto-detects existing .bin and resumes.

5. **Trim predictions off.** `.bin` is the safety net — `tools/retune_trims.py` against reference closes any percentile gap in 5-15 min × 4 (32K is 4× slower than 16K) = 20-60 min on user's local machine.

---

## What the .bin file gives you

Every render writes `<output>.bin` alongside `<output>.png`. The .bin is a 128-byte HistHeader followed by `width × height × 3 × 8` bytes of uint64 histogram data. At 32K that's 19,327,353,344 bytes (18 GiB).

The .bin enables:
- **Re-tonemap with different trims** without re-rendering (~50 sec at 16K, ~3 min at 32K — PNG encode dominates)
- **Resume from this point** with `--resume-from <path>` (additive, bit-exact)
- **Format conversion** to EXR for graphics-pipeline use (`tools/bin_to_exr.py`)
- **Crash recovery** — even if final PNG fails to save, the .bin persists

For long cloud runs, the .bin is the irreplaceable artifact. PNG is derivative.

---

## After the render: retune locally

On your laptop after `scp` (or `hf download`) of the final .bin:
```
python tools/retune_trims.py \
    --bin buddhabrot_cloud_32k_2T.bin \
    --reference-stats reference_calibration.json \
    --output buddhabrot_cloud_32k_2T_retoned.png
```

Runs ~5-15 iterations of coordinate descent over trim values, comparing percentiles against the reference (`buddhabrot_16k_blue.png`). Each iteration is one tonemap + percentile-compare; at 32K each ~40 sec on a 4070 Ti SUPER. Total ~5-10 min for full convergence.

Or skip the iteration and just retone with custom trims:
```
./buddhabrot \
    --resume-from buddhabrot_cloud_32k_2T.bin \
    --samples 2000000000000 \
    --trim-r 0.85 --trim-g 0.65 --trim-b 0.40 \
    --output buddhabrot_cloud_32k_2T_v2.png \
    --no-output-raw                              # don't dump duplicate .bin
```

The renderer detects samples_done == target and skips the render loop entirely; only tonemap + PNG encode runs.
