#!/usr/bin/env bash
# Resume a 32K render from an existing .bin to grow it to a higher sample
# count, producing a denser source for future guide generation.
#
# Source quality is the load-bearing factor for guide quality. cp9566 has
# 641B samples (3.5% per-pixel σ). Growing to 1.5T drops σ to ~2.3% — much
# cleaner guides at ALL downsample resolutions.
#
# Workflow:
#   1. Run this script: resumes from latest cp.bin → grows toward 1.5T
#   2. (Optional later) re-run generate_guide_hierarchy.sh on the new .bin
#      to produce a v2 guide set with better SNR
#
# Time on H100 (12 M/s): ~14 hr to go from 641B → 1.5T
# Cost on Hyperbolic/RunPod: ~$50 if billable
#
# Usage:
#   export HF_TOKEN=$(cat ~/.hf_token)
#   export HF_BUCKET=bochen2079/buddhabrot
#   bash resume_to_grow_source.sh
#
# Override target via env:
#   TARGET_SAMPLES=2000000000000 bash resume_to_grow_source.sh   # 2T
#   SOURCE_BIN=path/to/cp.bin bash resume_to_grow_source.sh

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v nvcc >/dev/null 2>&1; then
    if [ -d /usr/local/cuda/bin ]; then export PATH=/usr/local/cuda/bin:$PATH; fi
fi

echo "============================================================"
echo "Resume render to grow source bin density"
echo "============================================================"

# Find latest cp.bin if not specified
if [ -z "${SOURCE_BIN:-}" ]; then
    SOURCE_BIN=$(ls -1 buddhabrot_cloud_32k_h100_24h.cp*.bin 2>/dev/null | sort -V | tail -1)
    if [ -z "$SOURCE_BIN" ]; then
        echo "ERROR: no resume source on disk."
        echo "       Set SOURCE_BIN=path/to/cp.bin or download one to the pod first."
        exit 1
    fi
fi

SOURCE_SIZE=$(stat -c %s "$SOURCE_BIN")
echo "[source] $SOURCE_BIN  ($(( SOURCE_SIZE / 1073741824 )) GB)"

# Read source samples_done from header for progress info
SAMPLES_DONE=$(python3 -c "
import struct
with open('$SOURCE_BIN','rb') as f: h=f.read(128)
print(struct.unpack_from('<Q', h, 32)[0])
")
echo "[source] samples_done = $SAMPLES_DONE"

# Configuration
export TARGET_SAMPLES="${TARGET_SAMPLES:-1500000000000}"   # 1.5T default
export OUTPUT_BASE="${OUTPUT_BASE:-buddhabrot_cloud_32k_h100_24h}"
export CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-320}"          # cp every ~30 min at 12 M/s
export LAUNCHES_PER_ROUND="${LAUNCHES_PER_ROUND:-8}"
export SAMPLES_PER_THREAD="${SAMPLES_PER_THREAD:-8}"
export WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-82800}"    # 23 hr
export SIGUSR1_LEAD="${SIGUSR1_LEAD:-1800}"

REMAINING=$(( TARGET_SAMPLES - SAMPLES_DONE ))
echo "[plan]   target = $TARGET_SAMPLES"
echo "[plan]   remaining = $REMAINING samples"
echo "[plan]   ETA at 12 M/s: $(( REMAINING / 12000000 / 60 )) min wallclock"
echo "[plan]   cp every $CHECKPOINT_EVERY rounds = ~30 min cps"
echo "[plan]   hard cap: ${WALLCLOCK_HARD_CAP}s = $(( WALLCLOCK_HARD_CAP / 3600 )) hr"

if [ "$REMAINING" -le 0 ]; then
    echo "  source already at/past target. Nothing to do."
    exit 0
fi

# Build binary if needed
if [ ! -x ./buddhabrot ]; then
    echo "[build] compiling..."
    ./build.sh
fi

# HF auth
if [ -z "${HF_TOKEN:-}" ] && [ -f "$HOME/.hf_token" ]; then
    HF_TOKEN=$(cat "$HOME/.hf_token"); export HF_TOKEN
fi
if [ -z "${HF_BUCKET:-}" ]; then export HF_BUCKET="bochen2079/buddhabrot"; fi
hf auth login --token "$HF_TOKEN" --add-to-git-credential 2>&1 | tail -1 || true

# Start background HF sync loop (uploads each cp.bin as it lands)
pkill -f "while true.*hf sync.*${OUTPUT_BASE}.cp" 2>/dev/null || true
nohup bash -c '
    while true; do
        echo "[hf-loop $(date -u +%H:%M:%S)] sync pass"
        hf sync . hf://buckets/'"$HF_BUCKET"'/ \
            --include "'"$OUTPUT_BASE"'.cp*.bin" \
            --include "'"$OUTPUT_BASE"'.cp*.png" \
            --include "'"$OUTPUT_BASE"'.*.log" \
            2>&1 | tail -3
        sleep 900
    done
' > /tmp/hf_resume_loop.log 2>&1 &
disown
echo "[hf] background sync loop PID $!  log: /tmp/hf_resume_loop.log"

# Launch (inside tmux for survival)
SESSION="h100_resume_grow"
LAUNCH_INNER="./buddhabrot \
    --resume-from \"$SOURCE_BIN\" \
    --samples $TARGET_SAMPLES \
    --output ${OUTPUT_BASE}.png \
    --imap imap.bin \
    --width 32768 --height 24576 \
    --view-center-x -0.5935417456742 --view-center-y 0.04166264380232 \
    --zoom 0.5 --rotation-deg 90 --sample-radius 2.5 \
    --iter-r 2000 --iter-g 200 --iter-b 20 \
    --trim-r 0.74 --trim-g 0.74 --trim-b 0.52 \
    --samples-per-thread $SAMPLES_PER_THREAD \
    --launches-per-round $LAUNCHES_PER_ROUND \
    --checkpoint-every $CHECKPOINT_EVERY \
    --output-raw ${OUTPUT_BASE}.bin"

if command -v tmux >/dev/null; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 1
    tmux new-session -d -s "$SESSION" bash -c "$LAUNCH_INNER 2>&1 | tee ${OUTPUT_BASE}.resume.stderr.log; exec bash"
    echo
    echo "============================================================"
    echo "Render running in tmux 'h100_resume_grow'"
    echo "Reattach: tmux attach -t $SESSION"
    echo "Tail log: tail -f ${OUTPUT_BASE}.resume.stderr.log"
    echo "Final HF sync (auto): every 15 min via background loop"
    echo "============================================================"
else
    echo "tmux not found; running foreground (Ctrl-C kills the render)"
    eval "$LAUNCH_INNER 2>&1 | tee ${OUTPUT_BASE}.resume.stderr.log"
fi
