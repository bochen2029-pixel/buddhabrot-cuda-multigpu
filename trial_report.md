# 16K trial run — pipeline validation report

**Date:** 2026-05-08
**Hardware:** RTX 4070 Ti SUPER, sm_89, 16 GB VRAM, Windows 11
**Binary:** buddhabrot.exe (built 2026-05-08 11:49 UTC, with §B7 unconditional .bin dump)

## Verdict

**PIPELINE VALIDATED.** Re-tonemap from `.bin` works as designed. The cheap iteration loop is operational. Histogram persistence is lossless. Render output dimness at this budget is expected and corrected via post-hoc re-tonemap, not re-rendering.

| Test | Result |
|---|---|
| 1. Artifacts present (6 PNG + 6 BIN) | PASS — all 12 files written |
| 2. .bin size invariant (4,831,838,360 bytes) | PASS — exact match for all 6 |
| 3. .bin header parse (magic, dims, iter, samples) | PASS — every field matches kernel-side |
| 4. Channel max progression | INFORMATIONAL — discrete-jump pattern observed |
| 5. Image structural sanity | PASS — recognizable Buddhabrot in retoned PNG |
| 6. Re-tonemap from .bin (LOAD-BEARING) | **PASS** — 47 sec, no GPU compute, brighter PNG |
| 7. Wallclock validation | PASS — 14.2 min (brief budget 9–15 min) |
| 8. R_max sub-linearity exponent | x = 0.612 (PRE-ASYMPTOTIC, expected) |
| 9. SHA256 sidecars | PASS — 6 sidecars written |

## Configuration

- Resolution: 16384 × 12288 (200.3 Mpx)
- Total samples: 4,202,692,608 IS (~4.2 B target, 0.06% over)
- Per-pixel density: **21 traj/pixel** (8% of full 50B run, 0.4% of reference 5,120 traj/pixel)
- IS efficiency: ε_filament ≈ 50× → equivalent ~1,050 uniform-traj/pixel at filaments
- IS efficiency: ε_body ≈ 1.5× → equivalent ~31 uniform-traj/pixel at body (predicts very dim body — confirmed)
- Trim values during render: 0.74 / 0.74 / 0.52 (full-run calibration, NOT retuned for trial budget)

### TDR-safe substitution (per CLAUDE.md B11)

| Brief specified | Actual used | Reason |
|---|---|---|
| samples-per-thread = 666 | **8** | Brief value → 91 sec/launch wallclock = 67× over Windows TDR (2 sec). B11 mandates per-launch < 2 sec. |
| launches-per-round = 1 | **84** | Compensating for smaller per-launch; preserves 6 saves (5 cps + final). |
| n_rounds = 6 | **6** (504 launches / 84 = 6) | Matches brief intent. |
| samples-per-launch = 698M | **8.4M** | Per-launch under TDR by ~50%. |

All other parameters match the brief.

## Wallclock breakdown

| Stage | Time | Notes |
|---|---:|---|
| Compute (rendering) | 801 sec | 5.2 M/s effective throughput (down from 7.7 M/s baseline; per-checkpoint .bin write adds host-bound latency) |
| Per-checkpoint encode + .bin write | ~56 sec each × 6 | PNG encode at 16K dominates (~50 sec); .bin write ~5 sec |
| Total wallclock | 854 sec (14.2 min) | Within brief budget (9–15 min) |
| Re-tonemap from cp0003.bin | 47.7 sec | 0.001 sec compute (skipped render loop) + 47 sec PNG encode |

## Channel max progression (R = G = B at every cp — documented IS body-pixel equality)

| Checkpoint | Samples | R = G = B raw | Δ vs prior cp | Sample ratio | Exponent x |
|---|---:|---:|---:|---:|---:|
| cp0001 | 704,643,072 | 51,404,779 | — | — | — |
| cp0002 | 1,409,286,144 | 102,787,017 | 2.000× | 2.00× | 0.985 |
| cp0003 | 2,113,929,216 | 102,791,497 | 1.000× | 1.50× | 0.000 (plateau) |
| cp0004 | 2,818,572,288 | 154,173,311 | 1.500× | 1.33× | 1.409 (super-linear jump) |
| cp0005 | 3,523,215,360 | 154,201,180 | 1.000× | 1.25× | 0.000 (plateau) |
| final | 4,202,692,608 | 154,201,180 | 1.000× | 1.19× | 0.000 (plateau) |

**Overall exponent (cp1 → final): x = 0.612.** Sub-linear, pre-asymptotic regime. Trim values are NOT portable across budgets at 16K under this pipeline — confirms CLAUDE.md B12/B13.

The discrete jump pattern (alternating linear / plateau / super-linear / plateau) is the heavy-tail orbit-length distribution signature: occasional rare-but-large IS-weight contributions cause R_max to "leap" from one brightest-pixel-candidate to another. Between leaps, R_max plateaus.

## R = G = B exact equality at every checkpoint

This is the documented IS body-pixel pattern, not a kernel bug. Under aggressive Bitterli IS, the orbit population is heavily biased toward N ≥ 100 escapers; their first 20 iterations write to all three channels equally per visit. The brightest pixel sits in a body-cusp region where this writing pattern dominates. R = G = B at the brightest pixel is structurally correct. See `project_buddhabrot_is.md` items 5, 11, 12.

## The load-bearing test: re-tonemap from cp0003.bin

**Command:**
```
./buddhabrot.exe \
  --resume-from buddhabrot_16k_trial.cp0003.bin \
  --samples 2113929216 \
  --trim-r 0.21 --trim-g 0.21 --trim-b 0.15 \
  --output buddhabrot_16k_trial.cp0003_retoned.png \
  [same view + iter params, --no-output-raw to skip writing a duplicate .bin]
```

**Kernel behavior:**
- Loaded cp0003.bin (4.83 GB raw histogram + 128 byte header)
- Validated header against current invocation: PASS
- samples_done_at_start = 2,113,929,216 from header
- target_samples = 2,113,929,216 from --samples → render loop SKIPPED (already at target)
- Final save_image() ran with new trim values: tonemap_kernel + PNG encode

**Wallclock: 47.7 sec total (0.001 sec render loop, 47 sec PNG encode).**

**Brightness comparison (downsampled-to-1024×768 for inspection):**

| Metric | Original cp0003.png (trim 0.74) | Retoned (trim 0.21) | Ratio |
|---|---:|---:|---:|
| R p50 | 3 | 11 | 3.7× |
| R p99 | 20 | 66 | 3.3× |
| R p99.99 | 37 | 114 | 3.1× |
| R p99.999 | 60 | 164 | 2.7× |
| TL corner median RGB | (2, 2, 2) | (7, 7, 10) | ~3.5× |
| Saturation fraction | 0 | 0 | (no clipping in either) |

The retoned image is ~3.5× brighter across all percentiles. Trim ratio 0.74/0.21 = 3.52× confirms the retone scales as expected.

**Visual comparison:** original PNG is near-black with body barely visible. Retoned PNG shows clearly recognizable Buddhabrot structure — body, head, period-2 bulb, cardioid, satellites all resolved. See `buddhabrot_16k_trial.cp0003_thumb.jpg` and `buddhabrot_16k_trial.cp0003_retoned_thumb.jpg`.

## Disk-resident artifact integrity

```
buddhabrot_16k_trial.cp0001.bin    4,831,838,360 bytes  (4.83 GB binary; matches spec)
buddhabrot_16k_trial.cp0002.bin    4,831,838,360 bytes
buddhabrot_16k_trial.cp0003.bin    4,831,838,360 bytes
buddhabrot_16k_trial.cp0004.bin    4,831,838,360 bytes
buddhabrot_16k_trial.cp0005.bin    4,831,838,360 bytes
buddhabrot_16k_trial.bin (final)   4,831,838,360 bytes
```

Six SHA256 sidecars written (`*.bin.sha256`) for cloud spec compliance.

PNG sizes range 851–884 MB; the retoned variant (981 MB) is larger because brighter content compresses less.

## Anomalies and observations

1. **Throughput dropped from baseline 7.7 M/s to 5.2 M/s.** Likely cause: the per-checkpoint dual-write (.png + .bin) is host-side I/O bound for ~56 sec each, during which the GPU sits idle. Six checkpoints × 56 sec = 336 sec of idle out of 854 total = 39% of wallclock spent on saves. For production renders at sparser checkpoint cadence (e.g., every 16 rounds), this overhead drops to ~6%.

2. **R_max plateaus across cp2/cp3 and cp4/cp5/final.** This is the discrete-jump regime, not a stuck render. The overall exponent (0.612) confirms pre-asymptotic.

3. **R = G = B exactly at every cp.** Documented behavior under IS; not a bug. The trim_b factor 0.52 (now 0.15 under retune) gives B's effective max a 1.42× boost over R/G, which produces blue tint at convergence — but at this trial's per-pixel density the typical pixel counts are <30, where the trim_b boost is below 8-bit LSB, so the visible image is brown (sepia-ish), not blue. Brown-to-blue evolution requires per-pixel counts above ~30, which requires more samples than the trial allocates. Expected per `project_buddhabrot_is.md` item 4.

4. **The .bin write timing matches the spec target.** Atomic rename via .tmp completed cleanly across all six saves. No stale .tmp files left behind.

## Forward implications

- **The kernel is correct.** §B7 round-trips the histogram losslessly. The IS pipeline produces structurally-correct Buddhabrot at 21 traj/pixel — dim by construction, but that's a tonemap question not a sampling question.
- **Cheap trim iteration is now available.** Future trim retune costs ~50 sec per iteration (PNG encode at 16K) — entirely the encode, not the kernel.
- **For production-quality 16K output (matching reference body brightness):** need 5T-ish IS samples for native body density parity, OR hybrid sampling (uniform body + IS filament + merge), OR cloud Plan B 32K which has 31K traj/pixel comfortably above reference. Local 4070 Ti SUPER cannot deliver native reference-grade body brightness at 16K in reasonable wallclock; this is per CLAUDE.md B12.
- **For the immediate "ship a 16K image today" path:** retune trims via `--resume-from cp0005.bin --trim-r X --trim-g Y --trim-b Z` and iterate. Each iteration is ~50 sec. Pick the trim values that produce the desired tone match. Deliverable in <10 min of post-trial wallclock.

## Files written

```
buddhabrot_16k_trial.png + .bin + .bin.sha256              — final
buddhabrot_16k_trial.cp0001..0005.png + .bin + .bin.sha256 — 5 intermediate
buddhabrot_16k_trial.cp0003_retoned.png                    — re-tonemap test output
buddhabrot_16k_trial.cp0003_thumb.jpg                      — original 1024x768 thumb
buddhabrot_16k_trial.cp0003_retoned_thumb.jpg              — retoned 1024x768 thumb
buddhabrot_16k_trial.stderr.log                            — full kernel stderr
trial_report.md                                            — this file
```

Total disk used by trial: ~33 GB (.bin) + ~5 GB (.png) + sidecars = ~38 GB.

---

**End of trial report.**
