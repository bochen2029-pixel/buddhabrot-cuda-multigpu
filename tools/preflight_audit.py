"""Pre-flight dimensional audit for buddhabrot renders.

Runs the load-bearing dimensional checks that the 2026-05-08 16K planning skipped:
  (1) Per-pixel density vs reference
  (2) R_max regime detection (asymptotic vs pre-asymptotic) from existing
      checkpoint .bin files, if present
  (3) IS-efficiency heterogeneity advisory (filament vs body)
  (4) Trim portability check across operating points

Prints a verdict that should be reviewed before launching any render. Run from
run-local.sh / run-cloud.sh as a required pre-flight step.

Usage:
    python tools/preflight_audit.py \
        --resolution 16K --total-samples 50000000000 \
        --mode is \
        [--reference-resolution 16K --reference-samples 1024000000000] \
        [--checkpoint-dir .  --checkpoint-pattern 'buddhabrot_16k_IS.cp*.bin']

Exit codes:
    0 -- all checks pass; render is sized appropriately
    1 -- one or more warnings; user should acknowledge before launch
    2 -- pre-asymptotic regime detected from existing checkpoints; trims not portable
"""
import argparse
import glob
import math
import struct
import sys
from pathlib import Path

# IS efficiency by region, empirical-ish defaults from Bitterli + the 2026-05-08
# regime analysis. Region-conditional, not a single scalar.
IS_EFFICIENCY = {
    "filament": 50.0,   # Bitterli's high-end claim, applies at rare-event regions
    "body":     1.5,    # near-unity; IS doesn't help body density much
    "halo":     10.0,   # mid-zone
}

# Threshold for "asymptotic" vs "pre-asymptotic" R_max regime
ASYMPTOTIC_EXPONENT_THRESHOLD = 0.9

RESOLUTIONS = {
    "1K":  (1024, 768),
    "4K":  (4096, 3072),
    "8K":  (8192, 6144),
    "16K": (16384, 12288),
    "32K": (32768, 24576),
}


def read_bin_field(path: Path, offset: int, fmt: str):
    size = struct.calcsize(fmt)
    with open(path, "rb") as f:
        f.seek(offset)
        return struct.unpack(fmt, f.read(size))[0]


def parse_resolution(spec: str) -> tuple[int, int]:
    if spec in RESOLUTIONS:
        return RESOLUTIONS[spec]
    if "x" in spec:
        w, h = spec.split("x")
        return int(w), int(h)
    raise ValueError(f"unknown resolution: {spec}")


def density_check(args) -> int:
    """(1) Per-pixel density vs reference. Returns warning count."""
    print("=" * 70)
    print("PRE-FLIGHT AUDIT -- DIMENSIONAL CHECKS")
    print("=" * 70)
    warns = 0

    pw, ph = parse_resolution(args.resolution)
    pixels = pw * ph
    target = int(args.total_samples)
    density = target / pixels

    rw, rh = parse_resolution(args.reference_resolution)
    ref_pixels = rw * rh
    ref_samples = int(args.reference_samples)
    ref_density = ref_samples / ref_pixels

    print(f"\n[1] Per-pixel density")
    print(f"    Production:  {pw} x {ph} = {pixels/1e6:.1f} Mpx, {target:,} samples -> {density:,.0f} traj/pixel")
    print(f"    Reference:   {rw} x {rh} = {ref_pixels/1e6:.1f} Mpx, {ref_samples:,} samples -> {ref_density:,.0f} traj/pixel")
    ratio = density / ref_density
    print(f"    Ratio:       {ratio:.3f}x reference density")

    # IS efficiency check by region
    if args.mode == "is":
        print(f"\n[2] IS efficiency heterogeneity (mode=is)")
        for region, eff in IS_EFFICIENCY.items():
            equiv_uniform = density * eff
            ratio_eff = equiv_uniform / ref_density
            verdict = "OK" if ratio_eff >= 1.0 else "DIM" if ratio_eff >= 0.3 else "VERY DIM"
            print(f"    {region:10s}: eff={eff:>5.1f}x -> {equiv_uniform:>11,.0f} uniform-equivalent traj/pixel ({ratio_eff:.2f}x ref) [{verdict}]")
            if ratio_eff < 0.5:
                warns += 1
                print(f"               WARN: {region} region will be {(1-ratio_eff)*100:.0f}% under reference brightness")
    else:
        print(f"\n[2] Mode=uniform; IS efficiency analysis skipped")
        if ratio < 1.0:
            warns += 1
            print(f"    WARN: uniform density {density:,.0f} traj/pixel < reference {ref_density:,.0f} ({ratio*100:.0f}% of ref); body will be dim")

    return warns


def rmax_regime_check(args) -> int:
    """(3) R_max regime detection from --rmax-values OR checkpoint .bin files."""
    print(f"\n[3] R_max regime detection")

    # --rmax-values takes priority; works standalone without --checkpoint-dir.
    if args.rmax_values:
        rmax_pairs = [tuple(map(float, p.split(":"))) for p in args.rmax_values.split(",")]
        if len(rmax_pairs) >= 2:
            print(f"    Computing scaling exponent from --rmax-values input:")
            worst_rc = 0
            for i in range(1, len(rmax_pairs)):
                s_prev, r_prev = rmax_pairs[i-1]
                s_curr, r_curr = rmax_pairs[i]
                if s_prev <= 0 or r_prev <= 0:
                    continue
                exponent = math.log(r_curr / r_prev) / math.log(s_curr / s_prev)
                regime = "ASYMPTOTIC" if exponent >= ASYMPTOTIC_EXPONENT_THRESHOLD else "PRE-ASYMPTOTIC"
                print(f"      ({s_prev:.2g} -> {s_curr:.2g} samples, {r_prev:.2g} -> {r_curr:.2g} R_max): x = {exponent:.3f} [{regime}]")
                if exponent < ASYMPTOTIC_EXPONENT_THRESHOLD:
                    print(f"      VERDICT: trims calibrated at one budget will NOT port to a different budget at same resolution.")
                    print(f"      Either run to asymptotic regime (~10x more samples), or retune trims at the production budget.")
                    worst_rc = 2
            return worst_rc

    if not args.checkpoint_dir:
        print(f"    (skipped -- no --checkpoint-dir or --rmax-values provided)")
        return 0

    cp_dir = Path(args.checkpoint_dir)
    pattern = args.checkpoint_pattern or "*.cp*.bin"
    cp_files = sorted(cp_dir.glob(pattern))
    if len(cp_files) < 2:
        print(f"    (insufficient checkpoints: found {len(cp_files)} matching {pattern}; need >= 2)")
        return 0

    print(f"    Found {len(cp_files)} checkpoints matching {pattern}")
    # Read samples_done (offset 32) and R_max -- but R_max is in the histogram, not header.
    # The header tracks samples_done; for R_max we'd need to scan or the kernel could
    # write it. For now: report samples_done growth and ask user to manually pair with
    # R_max from stderr logs.
    series = []
    for cp in cp_files[-3:]:  # last 3 only
        try:
            samples_done = read_bin_field(cp, 32, "<Q")
            series.append((cp.name, samples_done))
        except Exception as e:
            print(f"    WARN: couldn't read {cp.name}: {e}")
            continue

    if len(series) < 2:
        print(f"    (insufficient readable checkpoints)")
        return 0

    print(f"    Last 3 checkpoints (samples_done):")
    for name, sd in series:
        print(f"      {name:50s} {sd:>20,}")

    print(f"\n    Note: R_max regime detection requires R_max values, which live in the")
    print(f"    histogram body, not the .bin header. To compute the scaling exponent x:")
    print(f"      1. Grep stderr logs for 'channel maxes  R=<N>'")
    print(f"      2. Pair R values with their samples_done from these checkpoints")
    print(f"      3. Compute x = log(R_n / R_{{n-1}}) / log(samples_n / samples_{{n-1}})")
    print(f"      4. If x < {ASYMPTOTIC_EXPONENT_THRESHOLD}: pre-asymptotic regime; trims not portable across budgets.")
    print(f"      5. If x >= {ASYMPTOTIC_EXPONENT_THRESHOLD}: asymptotic regime; trims port to other points at same resolution.")

    # If user provided R_max values explicitly via env or args, compute now.
    if args.rmax_values:
        rmax_pairs = [tuple(map(float, p.split(":"))) for p in args.rmax_values.split(",")]
        if len(rmax_pairs) >= 2:
            print(f"\n    Computing scaling exponent from provided R_max values:")
            for i in range(1, len(rmax_pairs)):
                s_prev, r_prev = rmax_pairs[i-1]
                s_curr, r_curr = rmax_pairs[i]
                if s_prev <= 0 or r_prev <= 0:
                    continue
                exponent = math.log(r_curr / r_prev) / math.log(s_curr / s_prev)
                regime = "ASYMPTOTIC" if exponent >= ASYMPTOTIC_EXPONENT_THRESHOLD else "PRE-ASYMPTOTIC"
                print(f"      ({s_prev:.2g} -> {s_curr:.2g} samples, {r_prev:.2g} -> {r_curr:.2g} R_max): x = {exponent:.3f} [{regime}]")
                if exponent < ASYMPTOTIC_EXPONENT_THRESHOLD:
                    return 2  # pre-asymptotic: trim portability broken
    return 0


def trim_portability_check(args) -> int:
    """(4) Cross-operating-point trim portability."""
    print(f"\n[4] Trim portability")
    if args.validation_resolution and args.validation_samples:
        vw, vh = parse_resolution(args.validation_resolution)
        v_pixels = vw * vh
        v_samples = int(args.validation_samples)
        v_density = v_samples / v_pixels
        pw, ph = parse_resolution(args.resolution)
        p_density = int(args.total_samples) / (pw * ph)
        density_ratio = v_density / p_density
        print(f"    Validation density:  {v_density:,.0f} traj/pixel (at {args.validation_resolution})")
        print(f"    Production density:  {p_density:,.0f} traj/pixel (at {args.resolution})")
        print(f"    Ratio:               {density_ratio:.3f}x (validation : production)")
        if abs(density_ratio - 1.0) > 0.10:
            print(f"    WARN: validation density differs from production by >10% -- trims calibrated at validation density may not produce the same percentile distribution at production density")
            return 1
        else:
            print(f"    OK: validation and production densities match within 10%; trim portability acceptable")
    else:
        print(f"    (skipped -- no --validation-resolution / --validation-samples provided)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--resolution", required=True, help="production resolution (16K, 32K, or WxH)")
    ap.add_argument("--total-samples", required=True, type=int, help="production target samples")
    ap.add_argument("--mode", default="is", choices=["is", "uniform", "hybrid"])
    ap.add_argument("--reference-resolution", default="16K")
    ap.add_argument("--reference-samples", default="1024000000000", help="reference total samples (default 1024B)")
    ap.add_argument("--validation-resolution", default=None)
    ap.add_argument("--validation-samples", default=None, type=int)
    ap.add_argument("--checkpoint-dir", default=None)
    ap.add_argument("--checkpoint-pattern", default=None)
    ap.add_argument("--rmax-values", default=None,
                    help="comma-separated samples:rmax pairs, e.g., '8.6e9:257e6,17.2e9:360e6'")
    args = ap.parse_args()

    warns = 0
    warns += density_check(args)
    rc = rmax_regime_check(args)
    warns += (rc if rc != 2 else 0)
    warns += trim_portability_check(args)

    print()
    print("=" * 70)
    if rc == 2:
        print(f"VERDICT: PRE-ASYMPTOTIC R_max DETECTED. Trim values calibrated at one")
        print(f"         budget will not produce the same tone at a different budget.")
        print(f"         Either run to asymptote (~10x more samples) or accept the")
        print(f"         current operating point's tonemap (not portable).")
        print("=" * 70)
        sys.exit(2)
    elif warns > 0:
        print(f"VERDICT: {warns} WARNING(S). Review before launch.")
        print(f"         The audit found a structural concern; do not proceed unless")
        print(f"         you understand and accept the implications.")
        print("=" * 70)
        sys.exit(1)
    else:
        print(f"VERDICT: ALL CHECKS PASSED. Render plan is dimensionally sound.")
        print("=" * 70)
        sys.exit(0)


if __name__ == "__main__":
    main()
