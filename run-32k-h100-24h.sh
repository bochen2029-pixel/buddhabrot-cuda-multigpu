#!/usr/bin/env bash
# Single H100 80GB / 32K monolithic render / 24-hour budget.
#
# Targets ~1-2 T IS samples (whatever lands within 23 hr hard cap).
# Hourly checkpoints (CHECKPOINT_EVERY=540 rounds ≈ 1 hr at 12 M/s).
# Each .bin auto-syncs to HF if HF_TOKEN + HF_BUCKET are set.
# Final state survives in HF even if pod evaporates.
#
# Pre-requisites (handled here if missing):
#   - buddhabrot binary built  (./build.sh)
#   - imap.bin                 (./build_imap.sh, or ships in repo)
#   - screen installed         (apt-get install -y screen)
#
# Usage:
#   export HF_TOKEN=hf_...
#   export HF_BUCKET=bochen2079/buddhabrot
#   bash run-32k-h100-24h.sh
#
# The render runs INSIDE a detached `screen` session, so it survives
# SSH disconnects and pod web terminal closures. Reattach any time:
#   screen -r h100_32k
# Quit-without-killing: Ctrl-A D
# Kill the render manually if needed:
#   screen -S h100_32k -X stuff $'\003'  # sends Ctrl-C into the session

set -euo pipefail
cd "$(dirname "$0")"

# -------------------------------------------------------------------------
# Pre-flight
# -------------------------------------------------------------------------
echo "============================================================"
echo "Single H100 32K production render — 24 hour budget"
echo "============================================================"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)"
echo

if ! command -v nvidia-smi >/dev/null; then
    echo "ERROR: nvidia-smi not found"; exit 1
fi
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
GPU_COUNT=$(nvidia-smi -L | wc -l)
echo "[gpu] $GPU_NAME — $GPU_MEM MiB — $GPU_COUNT GPU(s) detected"
case "$GPU_NAME" in
    *H100*|*H200*|*B200*) echo "[gpu] datacenter-class; good" ;;
    *) echo "[gpu] WARN: GPU not H100/H200/B200 class. 32K histogram needs ~24 GB VRAM." ;;
esac
if [ "$GPU_MEM" -lt 25000 ]; then
    echo "ERROR: GPU has < 25 GB VRAM. 32K histogram needs 19.3 GB + ~4 GB working = ~24 GB."
    exit 1
fi

# Build buddhabrot if missing
if [ ! -x ./buddhabrot ]; then
    echo "[build] compiling buddhabrot..."
    ./build.sh
fi

# IMap (canonical orbit-length-weighted; ships in repo at 4 MB)
if [ ! -f imap.bin ]; then
    echo "[imap] building canonical IMap..."
    ./build_imap.sh
fi

# Install screen if missing
if ! command -v screen >/dev/null; then
    echo "[deps] installing screen..."
    apt-get update -qq && apt-get install -y -qq screen
fi

# HF auth (only if env set)
HF_SYNC_ENABLED=0
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
    if ! command -v hf >/dev/null; then
        echo "[hf] installing huggingface_hub..."
        pip install -U -q huggingface_hub
    fi
    if hf auth login --token "$HF_TOKEN" 2>&1 | grep -q "Login successful\|Token is valid"; then
        HF_SYNC_ENABLED=1
        echo "[hf] auth OK, bucket: $HF_BUCKET"
    else
        echo "[hf] auth failed — sync disabled"
    fi
else
    echo "[hf] HF_TOKEN / HF_BUCKET not both set — sync disabled"
fi

# Background auto-sync loop (every 15 min). Each cp.bin lands as it's
# written; loop catches it and pushes to HF without blocking the render.
if [ "$HF_SYNC_ENABLED" = "1" ]; then
    pkill -f "hf sync.*buddhabrot_cloud_32k_h100_24h" 2>/dev/null || true
    nohup bash -c '
        cd '"$(pwd)"'
        while true; do
            echo "[hf-loop $(date -u +%H:%M:%S)] sync pass"
            hf sync . hf://buckets/'"$HF_BUCKET"'/ \
                --include "buddhabrot_cloud_32k_h100_24h*.bin" \
                --include "buddhabrot_cloud_32k_h100_24h*.png" \
                --include "buddhabrot_cloud_32k_h100_24h*.log" \
                2>&1 | tail -5
            sleep 900
        done
    ' > /tmp/hf_loop.log 2>&1 &
    disown
    echo "[hf] background sync loop PID $!  log: /tmp/hf_loop.log"
fi

# -------------------------------------------------------------------------
# Configuration — overridable via env if you want different params
# -------------------------------------------------------------------------
export N_DEVICES="${N_DEVICES:-1}"
export WIDTH="${WIDTH:-32768}"
export HEIGHT="${HEIGHT:-24576}"
export TARGET_SAMPLES="${TARGET_SAMPLES:-2000000000000}"   # 2 T ambitious
export TRIM_R="${TRIM_R:-0.95}"
export TRIM_G="${TRIM_G:-0.66}"
export TRIM_B="${TRIM_B:-0.38}"
export CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-540}"          # ~1 cp/hr at 12 M/s
export LAUNCHES_PER_ROUND="${LAUNCHES_PER_ROUND:-8}"
export SAMPLES_PER_THREAD="${SAMPLES_PER_THREAD:-8}"        # TDR-safe
export WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-82800}"    # 23 hr
export SIGUSR1_LEAD="${SIGUSR1_LEAD:-1800}"                 # 30 min margin
export OUTPUT_BASE="${OUTPUT_BASE:-buddhabrot_cloud_32k_h100_24h}"

echo
echo "[config] resolution: ${WIDTH}x${HEIGHT}  target: ${TARGET_SAMPLES} samples"
echo "[config] cp every:   ${CHECKPOINT_EVERY} rounds  (~1 hr at 12 M/s)"
echo "[config] cap:        ${WALLCLOCK_HARD_CAP}s = $((WALLCLOCK_HARD_CAP/3600)) hr"
echo "[config] SIGUSR1 at: T+$((WALLCLOCK_HARD_CAP - SIGUSR1_LEAD))s ($(((WALLCLOCK_HARD_CAP - SIGUSR1_LEAD)/3600)) hr $((((WALLCLOCK_HARD_CAP - SIGUSR1_LEAD)%3600)/60)) min)"
echo "[config] trims:      R=$TRIM_R G=$TRIM_G B=$TRIM_B (predicted for 1.5T density)"

# -------------------------------------------------------------------------
# Launch inside detached screen so it survives disconnects
# -------------------------------------------------------------------------
SESSION="h100_32k"

# Kill any prior session with this name
screen -S "$SESSION" -X quit 2>/dev/null || true
sleep 1

# Build the launch command (uses run-cloud-hyperbolic.sh as the watchdog wrapper)
LAUNCH_CMD="\
export N_DEVICES=$N_DEVICES; \
export WIDTH=$WIDTH; \
export HEIGHT=$HEIGHT; \
export TARGET_SAMPLES=$TARGET_SAMPLES; \
export TRIM_R=$TRIM_R; \
export TRIM_G=$TRIM_G; \
export TRIM_B=$TRIM_B; \
export CHECKPOINT_EVERY=$CHECKPOINT_EVERY; \
export LAUNCHES_PER_ROUND=$LAUNCHES_PER_ROUND; \
export SAMPLES_PER_THREAD=$SAMPLES_PER_THREAD; \
export WALLCLOCK_HARD_CAP=$WALLCLOCK_HARD_CAP; \
export SIGUSR1_LEAD=$SIGUSR1_LEAD; \
export OUTPUT_BASE=$OUTPUT_BASE; \
export HF_BUCKET=$HF_BUCKET; \
export HF_SYNC_ENABLED=$HF_SYNC_ENABLED; \
./run-cloud-hyperbolic.sh; \
echo 'Render exited at '\$(date -u); \
exec bash"

screen -dmS "$SESSION" bash -c "$LAUNCH_CMD"
sleep 2

if screen -ls | grep -q "$SESSION"; then
    echo
    echo "[launch] render running in screen session '$SESSION'"
    echo "[launch] PID: $(screen -ls | grep "$SESSION" | awk '{print $1}' | cut -d. -f1)"
else
    echo "ERROR: screen session failed to start"
    exit 1
fi

# -------------------------------------------------------------------------
# Recommended Linux-level safety net + monitoring tips
# -------------------------------------------------------------------------
echo
echo "============================================================"
echo "Render is going. Useful commands:"
echo "============================================================"
echo
echo "  # Attach to the running screen (Ctrl-A D to detach without killing):"
echo "  screen -r $SESSION"
echo
echo "  # Tail the stderr log:"
echo "  tail -f $OUTPUT_BASE.stderr.log"
echo
echo "  # Quick health check:"
echo "  nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv"
echo "  ls -lh $OUTPUT_BASE*.bin 2>/dev/null"
echo
echo "  # Linux-level shutdown safety net (recommended): 24 hr from now"
echo "  sudo shutdown +1440   # cancel anytime with: sudo shutdown -c"
echo
echo "  # Monitor HF bucket from your laptop:"
echo "  https://huggingface.co/buckets/$HF_BUCKET"
echo
echo "  # Manually kill the render (rare):"
echo "  screen -S $SESSION -X stuff \$'\\003'"
echo
echo "Expected timeline (at 12 M/s on H100):"
echo "  T+1 hr   first checkpoint, ~67 B samples in cp.bin (HF sync ~5 min later)"
echo "  T+12 hr  ~12 cps accumulated, ~800 B samples"
echo "  T+22:30  SIGUSR1 fires; render finishes current round, runs final save"
echo "  T+23     hard cap, render exits cleanly with .DONE flag"
echo "  T+23+    final HF sync completes, ~1-1.5 T samples in final .bin"
echo
