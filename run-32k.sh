#!/bin/bash
# 32K Buddhabrot render. Same view / iter / trim as the canonical 16K reference;
# resolution stepped up to 32768 x 24576 (4:3, 805 Mpx).
#
# VRAM per device: ~15 GB (9.7 GB hist + 4.8 GB out + working buffers).
# - Single 4070 Ti SUPER (16 GB total): WILL NOT FIT after desktop overhead. Cloud only.
# - 8x H200 (141 GB each): trivial.
#
# Defaults: 25T samples (Plan B equivalent), 8 GPUs, 15h hard wallclock cap.
# Override via env: SAMPLES, GPUS, WALLCLOCK_HARD_CAP, CP_EVERY, OUT, P2P_OVERRIDE.
#
# Usage:
#   ./run-32k.sh                                  # 25T on 8 GPUs (Plan B)
#   SAMPLES=100000000000000 ./run-32k.sh          # 100T (Plan C)
#   SAMPLES=5000000000000   ./run-32k.sh          # 5T (sample-density parity with 5T 16K, ~75% as dense per-pixel)
#   GPUS=1 ./run-32k.sh                           # single GPU (will OOM on cards < 20 GB)
#   P2P_OVERRIDE=1 ./run-32k.sh                   # ignore non-NVLink topology
#
# Wallclock projection at 8x H200 + NVLink (assuming ~21 G samples/sec aggregate):
#   25T  = ~20 min compute + ~25 min PNG encode at 32K (8 checkpoints) = ~45 min total
#   100T = ~80 min compute + ~25 min PNG encode = ~105 min total

set -euo pipefail
cd "$(dirname "$0")"

# CLAUDE.md section B1 guard
if grep -qE -- '--target-[rgb]' "$0"; then
    echo "ERROR: banned auto-derive flag in script. See CLAUDE.md section B1."
    exit 1
fi

# Locate binary (Linux ./buddhabrot or Windows ./buddhabrot.exe)
BIN=""
for candidate in ./buddhabrot ./buddhabrot.exe; do
    [[ -x "$candidate" ]] && BIN="$candidate" && break
done
if [[ -z "$BIN" ]]; then
    echo "ERROR: buddhabrot binary not found. Run ./build.sh (Linux) or build.bat (Windows) first."
    exit 1
fi

GPUS="${GPUS:-8}"
SAMPLES="${SAMPLES:-25000000000000}"
WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-15h}"
CP_EVERY="${CP_EVERY:-60}"
OUT="${OUT:-buddhabrot_32k_$(printf '%dT' $((SAMPLES / 1000000000000))).png}"

# Pre-flight: GPU enumeration
echo "=== Pre-flight: GPU enumeration"
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not found."
    exit 1
fi
nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv | sed 's/^/    /'
ACTUAL_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | tr -d ' ')
if [[ -z "$ACTUAL_GPUS" || "$ACTUAL_GPUS" -lt "$GPUS" ]]; then
    echo "ERROR: requested $GPUS GPUs, only $ACTUAL_GPUS visible."
    exit 1
fi
echo "    requested=$GPUS visible=$ACTUAL_GPUS"

# Pre-flight: VRAM (32K hist+out+working ~ 15 GB per device, plus headroom)
echo "=== Pre-flight: VRAM check (32K needs >= 15.5 GB free per device)"
MIN_VRAM_MIB=15500
for i in $(seq 0 $((GPUS - 1))); do
    VRAM_FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits -i $i 2>/dev/null | tr -d ' ')
    if [[ -z "$VRAM_FREE" || "$VRAM_FREE" -lt "$MIN_VRAM_MIB" ]]; then
        echo "ERROR: GPU $i has only ${VRAM_FREE} MiB free; need >= ${MIN_VRAM_MIB} MiB."
        echo "       Close other GPU workloads or use a GPU with more memory."
        exit 1
    fi
    echo "    GPU $i: ${VRAM_FREE} MiB free (ok)"
done

# Pre-flight: P2P topology (multi-GPU only)
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
        echo "       To proceed anyway: P2P_OVERRIDE=1 ./run-32k.sh"
        [[ "${P2P_OVERRIDE:-0}" == "1" ]] || exit 1
        echo "       P2P_OVERRIDE=1 set; continuing despite degraded topology."
    else
        echo "    NVLink confirmed across $GPUS GPU pairs."
    fi
fi

echo ""
echo "=== Plan: 32768 x 24576 (805 Mpx), $SAMPLES samples, ${GPUS} GPUs"
echo "=== Checkpoint every $CP_EVERY rounds; hard wallclock cap $WALLCLOCK_HARD_CAP"
echo "=== Output: $OUT"
echo "=== Log:    ${OUT%.png}.stderr.log"
echo "=== Launching at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

nohup timeout --signal=SIGTERM --kill-after=300 "$WALLCLOCK_HARD_CAP" \
"$BIN" \
    --width 32768 \
    --height 24576 \
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
    "$@" > "${OUT%.png}.stderr.log" 2>&1 &

RENDER_PID=$!
disown $RENDER_PID

echo ""
echo "=== Render PID: $RENDER_PID"
echo "=== Tail log: tail -f ${OUT%.png}.stderr.log"
echo "=== Started:  $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
