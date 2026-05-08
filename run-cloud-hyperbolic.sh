#!/usr/bin/env bash
# 8x H200/H100 × 32K × 2T IS production render on Hyperbolic.xyz.
#
# Flow:
#   1. Detect GPU type (H200 / H100), count (require 8), NVLink topology (require NV*)
#   2. Verify imap.bin exists (build via build_imap.sh if missing — fresh + fallback)
#   3. Pre-flight dimensional audit (B13 mandatory) — flags but does not block
#   4. Launch under watchdog with 90-min hard cap
#   5. Watchdog fires SIGUSR1 at T-300s; main.cu finishes round, saves, exits
#   6. Background HF sync uploads each checkpoint as it lands
#
# Banned-pattern guard per CLAUDE.md §B1.
if grep -qE -- '--target-[rgb]' "$0"; then
    echo "ERROR: --target-r/g/b detected in this script. Banned per CLAUDE.md §B1." >&2
    exit 1
fi

set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Configuration (all overridable via env)
# ---------------------------------------------------------------------------
WIDTH="${WIDTH:-32768}"
HEIGHT="${HEIGHT:-24576}"
TARGET_SAMPLES="${TARGET_SAMPLES:-2000000000000}"   # 2 T IS
N_DEVICES="${N_DEVICES:-8}"
LAUNCHES_PER_ROUND="${LAUNCHES_PER_ROUND:-16}"
SAMPLES_PER_THREAD="${SAMPLES_PER_THREAD:-32}"      # Linux, no TDR — bigger than Windows 8
CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-117}"          # 4 saves over ~466 rounds at 2T

# Trim values predicted from the 0.388 cross-density scaling. See README §math.
TRIM_R="${TRIM_R:-1.00}"
TRIM_G="${TRIM_G:-0.74}"
TRIM_B="${TRIM_B:-0.42}"

# Reference invariants (do NOT change without explicit user request).
VIEW_CX="${VIEW_CX:--0.5935417456742}"
VIEW_CY="${VIEW_CY:-0.04166264380232}"
ZOOM="${ZOOM:-0.5}"
ROTATION_DEG="${ROTATION_DEG:-90}"
SAMPLE_RADIUS="${SAMPLE_RADIUS:-2.5}"
ITER_R="${ITER_R:-2000}"
ITER_G="${ITER_G:-200}"
ITER_B="${ITER_B:-20}"

# Wallclock cap. Watchdog enforces; SIGUSR1 fires at WALLCLOCK_HARD_CAP - SIGUSR1_LEAD.
WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-5400}"   # 90 min
SIGUSR1_LEAD="${SIGUSR1_LEAD:-300}"                # 5 min before hard cap

# Output
OUTPUT_BASE="${OUTPUT_BASE:-buddhabrot_cloud_32k_2T}"
OUTPUT_PNG="${OUTPUT_BASE}.png"
OUTPUT_BIN="${OUTPUT_BASE}.bin"

# IMap (mandatory for IS)
IMAP_PATH="${IMAP_PATH:-imap.bin}"

# Background HF sync (set HF_BUCKET=bochen2079/buddhabrot to enable)
HF_BUCKET="${HF_BUCKET:-bochen2079/buddhabrot}"
HF_SYNC_ENABLED="${HF_SYNC_ENABLED:-1}"

# ---------------------------------------------------------------------------
# Pre-flight: GPU detection (H100 vs H200 adaptive)
# ---------------------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null; then
    echo "ERROR: nvidia-smi not found. Not a CUDA host?" >&2
    exit 1
fi

GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader)
GPU_COUNT=$(echo "$GPU_NAMES" | wc -l)
GPU_FIRST=$(echo "$GPU_NAMES" | head -1)

echo "[gpu] detected $GPU_COUNT GPU(s):"
echo "$GPU_NAMES" | nl -ba

if [ "$GPU_COUNT" -lt "$N_DEVICES" ]; then
    echo "ERROR: requested N_DEVICES=$N_DEVICES but only $GPU_COUNT GPUs visible." >&2
    exit 1
fi

# Per-GPU throughput estimate (M samples/s). Adaptive: H200 > H100 > A100.
case "$GPU_FIRST" in
    *H200*) PER_GPU_MS=50 ; GPU_TIER="H200" ;;
    *H100*) PER_GPU_MS=40 ; GPU_TIER="H100" ;;
    *A100*) PER_GPU_MS=18 ; GPU_TIER="A100" ;;
    *)      PER_GPU_MS=20 ; GPU_TIER="UNKNOWN" ;;
esac

AGG_MS=$(( PER_GPU_MS * N_DEVICES * 96 / 100 ))
PROJECTED_COMPUTE_SEC=$(( TARGET_SAMPLES / (AGG_MS * 1000000) ))
PROJECTED_TOTAL_SEC=$(( PROJECTED_COMPUTE_SEC + 1000 ))

echo "[gpu] tier: $GPU_TIER"
echo "[gpu] per-GPU throughput estimate: ${PER_GPU_MS} M/s"
echo "[gpu] aggregate (8x at 0.96 efficiency): ${AGG_MS} M/s"
echo "[gpu] projected compute time: ${PROJECTED_COMPUTE_SEC}s"
echo "[gpu] projected total wallclock (with saves): ${PROJECTED_TOTAL_SEC}s"

if [ "$PROJECTED_TOTAL_SEC" -gt "$WALLCLOCK_HARD_CAP" ]; then
    echo "WARN: projected wallclock ${PROJECTED_TOTAL_SEC}s exceeds hard cap ${WALLCLOCK_HARD_CAP}s." >&2
    echo "WARN: SIGUSR1 will trigger early-stop with partial samples." >&2
fi

# ---------------------------------------------------------------------------
# Pre-flight: NVLink P2P topology check
# ---------------------------------------------------------------------------
echo "[p2p] checking NVLink topology"
TOPO=$(nvidia-smi topo -m 2>/dev/null || echo "")
if [ -n "$TOPO" ]; then
    if echo "$TOPO" | grep -qE 'NV[0-9]+'; then
        echo "[p2p] NVLink detected"
    else
        echo "WARN: no NVLink (NV*) connections detected; multi-GPU merge will be slow over PCIe." >&2
    fi
fi

# ---------------------------------------------------------------------------
# Pre-flight: IMap presence (build if missing — fresh-on-cloud fallback)
# ---------------------------------------------------------------------------
if [ ! -f "$IMAP_PATH" ]; then
    echo "[imap] $IMAP_PATH not found; building fresh"
    if [ ! -x ./buddhabrot ]; then
        echo "ERROR: ./buddhabrot binary missing. Run build.sh first." >&2
        exit 1
    fi
    ./buddhabrot \
        --build-imap "$IMAP_PATH" \
        --imap-samples 1000000000 \
        --width 1024 --height 1024 \
        --view-center-x "$VIEW_CX" --view-center-y "$VIEW_CY" \
        --zoom "$ZOOM" --rotation-deg "$ROTATION_DEG" \
        --sample-radius "$SAMPLE_RADIUS" \
        --iter-r "$ITER_R" --iter-g "$ITER_G" --iter-b "$ITER_B" \
        --devices 1
    echo "[imap] built: $(ls -lh "$IMAP_PATH" | awk '{print $5}')"
else
    echo "[imap] using existing: $(ls -lh "$IMAP_PATH" | awk '{print $5}')"
fi

# ---------------------------------------------------------------------------
# Pre-flight dimensional audit (B13 mandatory)
# ---------------------------------------------------------------------------
PIXEL_COUNT=$(( WIDTH * HEIGHT ))
TRAJ_PER_PIXEL=$(( TARGET_SAMPLES / PIXEL_COUNT ))
REF_DENSITY=5120
PCT_OF_REF=$(( TRAJ_PER_PIXEL * 100 / REF_DENSITY ))

echo "[audit] resolution        : ${WIDTH}x${HEIGHT} (${PIXEL_COUNT} pixels)"
echo "[audit] target samples    : $TARGET_SAMPLES"
echo "[audit] traj/pixel        : $TRAJ_PER_PIXEL"
echo "[audit] reference density : $REF_DENSITY (16K_blue.png uniform)"
echo "[audit] pct of reference  : ${PCT_OF_REF}%"
if [ "$PCT_OF_REF" -lt 30 ]; then
    echo "WARN: per-pixel density well below reference; body region will be dim. Retune via .bin post-render." >&2
fi

# ---------------------------------------------------------------------------
# HF auth check (best-effort; render does not block on this)
# ---------------------------------------------------------------------------
if [ "$HF_SYNC_ENABLED" = "1" ]; then
    if ! command -v hf >/dev/null && ! command -v huggingface-cli >/dev/null; then
        echo "[hf] CLI not installed; HF sync will be skipped"
        HF_SYNC_ENABLED=0
    elif [ -z "${HF_TOKEN:-}" ]; then
        echo "[hf] HF_TOKEN env not set; HF sync will be skipped"
        HF_SYNC_ENABLED=0
    else
        echo "[hf] sync enabled, bucket: $HF_BUCKET"
    fi
fi

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
LOG_PATH="${OUTPUT_BASE}.stderr.log"
PID_PATH="${OUTPUT_BASE}.pid"
DONE_PATH="${OUTPUT_BASE}.DONE"
FATAL_PATH="${OUTPUT_BASE}.FATAL"

# Clean prior state if rerunning fresh
rm -f "$DONE_PATH" "$FATAL_PATH"

# Resume detection (auto-default-on per main.cu)
RESUME_ARG=()
if [ -f "$OUTPUT_BIN" ]; then
    SIZE=$(stat -c%s "$OUTPUT_BIN" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 1000000 ]; then
        echo "[resume] found existing $OUTPUT_BIN ($(numfmt --to=iec --suffix=B "$SIZE")); resuming"
        RESUME_ARG=(--resume-from "$OUTPUT_BIN")
    fi
fi

cat <<EOF | tee "${OUTPUT_BASE}.launch.log"
[launch] $(date -u +%Y-%m-%dT%H:%M:%SZ)
[launch] target_samples : $TARGET_SAMPLES
[launch] resolution     : ${WIDTH}x${HEIGHT}
[launch] devices        : $N_DEVICES x $GPU_TIER
[launch] trims          : R=$TRIM_R G=$TRIM_G B=$TRIM_B
[launch] checkpoint_every: $CHECKPOINT_EVERY rounds
[launch] launches/round : $LAUNCHES_PER_ROUND
[launch] samples/thread : $SAMPLES_PER_THREAD
[launch] wallclock_cap  : ${WALLCLOCK_HARD_CAP}s (SIGUSR1 at T-${SIGUSR1_LEAD}s)
[launch] output_base    : $OUTPUT_BASE
[launch] hf_sync        : $HF_SYNC_ENABLED ($HF_BUCKET)
EOF

# Launch under supervisor watchdog
exec ./_supervise-cloud.sh \
    --output-base "$OUTPUT_BASE" \
    --hard-cap "$WALLCLOCK_HARD_CAP" \
    --sigusr1-lead "$SIGUSR1_LEAD" \
    --hf-sync "$HF_SYNC_ENABLED" \
    --hf-bucket "$HF_BUCKET" \
    -- \
    ./buddhabrot \
        --width "$WIDTH" \
        --height "$HEIGHT" \
        --samples "$TARGET_SAMPLES" \
        --devices "$N_DEVICES" \
        --imap "$IMAP_PATH" \
        --iter-r "$ITER_R" --iter-g "$ITER_G" --iter-b "$ITER_B" \
        --view-center-x "$VIEW_CX" --view-center-y "$VIEW_CY" \
        --zoom "$ZOOM" --rotation-deg "$ROTATION_DEG" \
        --sample-radius "$SAMPLE_RADIUS" \
        --trim-r "$TRIM_R" --trim-g "$TRIM_G" --trim-b "$TRIM_B" \
        --samples-per-thread "$SAMPLES_PER_THREAD" \
        --launches-per-round "$LAUNCHES_PER_ROUND" \
        --checkpoint-every "$CHECKPOINT_EVERY" \
        --output "$OUTPUT_PNG" \
        "${RESUME_ARG[@]}"
