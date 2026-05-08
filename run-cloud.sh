#!/bin/bash
# Cloud (multi-GPU) render. Default Plan B (medium tier).
# Plan C (~$300) requires explicit PLAN=C opt-in per CLAUDE.md section B4.
#
# Tone is baked at render time via --trim-r/g/b (sample-count-invariant
# compression anchors, matches the user-accepted 1024B reference).
#
# Usage:
#   ./run-cloud.sh                       # Plan B: 32K + 25T,  ~3-4 hr
#   PLAN=A ./run-cloud.sh                # Plan A: 16K + 25T,  ~25 min
#   PLAN=C ./run-cloud.sh                # Plan C: 32K + 100T, ~12-14 hr (opt-in)
#   GPUS=4 ./run-cloud.sh                # override device count (default 8)
#   WALLCLOCK_HARD_CAP=18h ./run-cloud.sh # override hard cap (default 15h)
#   P2P_OVERRIDE=1 ./run-cloud.sh        # acknowledge non-NVLink topology

set -euo pipefail
cd "$(dirname "$0")"

# CLAUDE.md section B1 guard — see CLAUDE.md for rationale.
if grep -qE -- '--target-[rgb]' "$0"; then
    echo "ERROR: banned auto-derive flag present in this script."
    echo "       See CLAUDE.md section B1."
    exit 1
fi

if [[ ! -x ./buddhabrot ]]; then
    echo "buddhabrot binary not found. Run ./build.sh first."
    exit 1
fi

PLAN="${PLAN:-B}"
case "$PLAN" in
    A)  WIDTH=16384; HEIGHT=12288; SAMPLES=25000000000000;  CP_EVERY=30  ;;
    B)  WIDTH=32768; HEIGHT=24576; SAMPLES=25000000000000;  CP_EVERY=60  ;;
    C)  WIDTH=32768; HEIGHT=24576; SAMPLES=100000000000000; CP_EVERY=120 ;;
    *)  echo "Unknown PLAN=$PLAN. Use A, B, or C."; exit 1 ;;
esac

GPUS="${GPUS:-8}"
WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-15h}"
OUT="${OUT:-buddhabrot_cloud_plan${PLAN}.png}"

echo "=== Pre-flight: GPU enumeration"
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not found."
    exit 1
fi
nvidia-smi --query-gpu=index,name,memory.total --format=csv | sed 's/^/    /'
ACTUAL_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | tr -d ' ')
if [[ -z "$ACTUAL_GPUS" || "$ACTUAL_GPUS" -lt "$GPUS" ]]; then
    echo "ERROR: requested $GPUS GPUs, only $ACTUAL_GPUS visible. Aborting."
    exit 1
fi
echo "    requested=$GPUS visible=$ACTUAL_GPUS"

if [[ "$GPUS" -gt 1 ]]; then
    echo "=== Pre-flight: P2P topology"
    TOPO=$(nvidia-smi topo -m 2>/dev/null || true)
    if [[ -z "$TOPO" ]]; then
        echo "ERROR: nvidia-smi topo -m produced no output."
        exit 1
    fi
    echo "$TOPO" | sed 's/^/    /'
    BAD=$(echo "$TOPO" | awk -v n="$GPUS" '
        /^GPU[0-9]+/ {
            row = substr($1, 4) + 0
            if (row >= n) next
            for (i = 2; i <= 1 + n; i++) {
                if (i - 2 == row) continue
                if ($i ~ /^(SYS|NODE|PHB|PXB|PIX)$/) { print $i; exit }
            }
        }')
    if [[ -n "$BAD" ]]; then
        echo "ERROR: non-NVLink P2P link detected ($BAD) between requested GPU pairs."
        echo "       Multi-GPU efficiency degrades sharply (CLAUDE.md section 5)."
        echo "       To proceed anyway: P2P_OVERRIDE=1 ./run-cloud.sh"
        [[ "${P2P_OVERRIDE:-0}" == "1" ]] || exit 1
        echo "       P2P_OVERRIDE=1; continuing despite degraded topology."
    else
        echo "    NVLink confirmed across $GPUS GPU pairs."
    fi
fi

echo ""
echo "=== Plan $PLAN: ${WIDTH}x${HEIGHT}, ${SAMPLES} samples, ${GPUS} GPUs"
echo "=== Checkpoint every $CP_EVERY rounds, hard wallclock cap $WALLCLOCK_HARD_CAP"
echo "=== Output: $OUT"
echo "=== Launching at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
START_TS=$(date +%s)

timeout --signal=SIGTERM --kill-after=300 "$WALLCLOCK_HARD_CAP" \
./buddhabrot \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --samples "$SAMPLES" \
    --devices "$GPUS" \
    --iter-r 2000 \
    --iter-g 200 \
    --iter-b 20 \
    --view-center-x -0.5935417456742 \
    --view-center-y  0.04166264380232 \
    --zoom 0.5 \
    --rotation-deg 90 \
    --sample-center-x 0 \
    --sample-center-y 0 \
    --sample-radius 2.5 \
    --trim-r 0.2673 \
    --trim-g 0.2051 \
    --trim-b 0.1270 \
    --checkpoint-every "$CP_EVERY" \
    --launches-per-round 8 \
    --output "$OUT" \
    "$@"

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo ""
echo "=== Done: $OUT"
echo "=== Wallclock: $ELAPSED sec ($((ELAPSED / 60)) min)"
echo "=== Checkpoints (in order):"
ls -1tr "${OUT%.png}".cp*.png 2>/dev/null | sed 's/^/    /' || echo "    (none)"
echo "=== File sizes:"
ls -lh "${OUT%.png}"*.png 2>/dev/null | sed 's/^/    /' || true
echo ""
echo "=== Download outputs BEFORE shutting down the rental."
echo "=== Note: this binary writes only PNG. Re-grading requires re-render."
echo "=== Add --output-raw to main.cu before next paid render (CLAUDE.md section B7)."
