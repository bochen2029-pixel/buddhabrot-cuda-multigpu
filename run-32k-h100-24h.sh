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
# Pre-flight + privilege detection
# -------------------------------------------------------------------------
echo "============================================================"
echo "Single H100 32K production render — 24 hour budget"
echo "============================================================"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)"
echo "User: $(whoami)"

# Hyperbolic doesn't give root; RunPod does. Detect once and branch installs.
if [ "$(id -u)" = "0" ]; then
    APT_PREFIX=""
    PIP_USER_FLAG=""
    PRIVILEGE="root"
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    APT_PREFIX="sudo "
    PIP_USER_FLAG="--user"
    PRIVILEGE="sudo (passwordless)"
elif command -v sudo >/dev/null; then
    APT_PREFIX="sudo "
    PIP_USER_FLAG="--user"
    PRIVILEGE="sudo (interactive)"
else
    APT_PREFIX=""
    PIP_USER_FLAG="--user"
    PRIVILEGE="unprivileged; apt-get steps will be SKIPPED"
fi
echo "Privilege: $(whoami) (uid=$(id -u)); apt prefix='${APT_PREFIX:-<none>}'; pip flag='${PIP_USER_FLAG:-<none>}' — $PRIVILEGE"
if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
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

# Install screen if missing. Use privilege-appropriate command.
if ! command -v screen >/dev/null; then
    if [ -z "$APT_PREFIX" ] && [ "$PRIVILEGE" != "root" ]; then
        echo "[deps] WARN: 'screen' missing and no apt privilege. Render will run in"
        echo "       foreground; SSH disconnect will kill it. Alternatives:"
        echo "         (a) ask pod admin to install screen, OR"
        echo "         (b) use 'tmux' if it's preinstalled, OR"
        echo "         (c) use 'nohup ./run-cloud-hyperbolic.sh &' instead of this wrapper"
        echo "       Continuing without screen — render will be foreground."
        USE_SCREEN=0
    else
        echo "[deps] installing screen (${APT_PREFIX}apt-get)..."
        ${APT_PREFIX}apt-get update -qq && ${APT_PREFIX}apt-get install -y -qq screen
        USE_SCREEN=1
    fi
else
    USE_SCREEN=1
fi

# HF auth (only if env set)
HF_SYNC_ENABLED=0
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
    if ! command -v hf >/dev/null; then
        echo "[hf] installing huggingface_hub (pip $PIP_USER_FLAG)..."
        pip install -U -q $PIP_USER_FLAG huggingface_hub || \
            python3 -m pip install -U -q $PIP_USER_FLAG huggingface_hub
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
export CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-320}"          # first cp at ~30 min (12 M/s)
# Cadence math: 1 round ≈ 5.6s at 12 M/s → 320 rounds ≈ 30 min between cps.
# Expected total cps over 24h: ~45. Save overhead: ~3 hr (13% of 24h).
# Override to 540 for hourly cps + lower overhead (~8%) at the cost of
# first-cp landing at T+50min instead of T+30min.
export LAUNCHES_PER_ROUND="${LAUNCHES_PER_ROUND:-8}"
export SAMPLES_PER_THREAD="${SAMPLES_PER_THREAD:-8}"        # TDR-safe
export WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-82800}"    # 23 hr
export SIGUSR1_LEAD="${SIGUSR1_LEAD:-1800}"                 # 30 min margin
export OUTPUT_BASE="${OUTPUT_BASE:-buddhabrot_cloud_32k_h100_24h}"

echo
echo "[config] resolution: ${WIDTH}x${HEIGHT}  target: ${TARGET_SAMPLES} samples"
# Per-round time: 1 round = launches_per_round × 4096 × 256 × samples_per_thread samples
#                          / throughput.  At LPR=8 SPT=8: per_round = 67.1M / throughput.
# At 12 M/s: 5.59 sec/round → CHECKPOINT_EVERY × 5.59 / 60 = CHECKPOINT_EVERY × 559 / 6000 min
# At 25 M/s: 2.68 sec/round → CHECKPOINT_EVERY × 268 / 6000 min
echo "[config] cp every:   ${CHECKPOINT_EVERY} rounds  (~$((CHECKPOINT_EVERY * 559 / 6000)) min at 12 M/s, ~$((CHECKPOINT_EVERY * 268 / 6000)) min at 25 M/s)"
echo "[config] first cp:   expected at T+$((CHECKPOINT_EVERY * 559 / 6000)) min (watch HF bucket then)"
echo "[config] cap:        ${WALLCLOCK_HARD_CAP}s = $((WALLCLOCK_HARD_CAP/3600)) hr"
echo "[config] SIGUSR1 at: T+$((WALLCLOCK_HARD_CAP - SIGUSR1_LEAD))s ($(((WALLCLOCK_HARD_CAP - SIGUSR1_LEAD)/3600)) hr $((((WALLCLOCK_HARD_CAP - SIGUSR1_LEAD)%3600)/60)) min)"
echo "[config] trims:      R=$TRIM_R G=$TRIM_G B=$TRIM_B (predicted for 1.5T density)"

# -------------------------------------------------------------------------
# Launch — prefer detached screen so it survives SSH disconnects; fall back
# to nohup-in-background if screen unavailable.
# -------------------------------------------------------------------------
SESSION="h100_32k"

if [ "${USE_SCREEN:-1}" = "1" ]; then
    # Kill any prior session with this name
    screen -S "$SESSION" -X quit 2>/dev/null || true
    sleep 1

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
else
    # nohup fallback — render survives SSH disconnect via SIGHUP ignore,
    # but no interactive reattach. Output goes to nohup.out + stderr.log.
    echo
    echo "[launch] starting render via nohup (no screen available)"
    nohup bash -c "\
export N_DEVICES=$N_DEVICES \
       WIDTH=$WIDTH HEIGHT=$HEIGHT \
       TARGET_SAMPLES=$TARGET_SAMPLES \
       TRIM_R=$TRIM_R TRIM_G=$TRIM_G TRIM_B=$TRIM_B \
       CHECKPOINT_EVERY=$CHECKPOINT_EVERY \
       LAUNCHES_PER_ROUND=$LAUNCHES_PER_ROUND \
       SAMPLES_PER_THREAD=$SAMPLES_PER_THREAD \
       WALLCLOCK_HARD_CAP=$WALLCLOCK_HARD_CAP \
       SIGUSR1_LEAD=$SIGUSR1_LEAD \
       OUTPUT_BASE=$OUTPUT_BASE \
       HF_BUCKET=$HF_BUCKET \
       HF_SYNC_ENABLED=$HF_SYNC_ENABLED; \
./run-cloud-hyperbolic.sh" > nohup_render.log 2>&1 &
    RENDER_BG_PID=$!
    disown
    echo "[launch] render running in background, PID $RENDER_BG_PID  log: nohup_render.log"
fi

# -------------------------------------------------------------------------
# Recommended Linux-level safety net + monitoring tips
# -------------------------------------------------------------------------
echo
echo "============================================================"
echo "Render is going. Useful commands:"
echo "============================================================"
echo
if [ "${USE_SCREEN:-1}" = "1" ]; then
    echo "  # Attach to the running screen (Ctrl-A D to detach without killing):"
    echo "  screen -r $SESSION"
    echo
    echo "  # Manually kill the render (rare):"
    echo "  screen -S $SESSION -X stuff \$'\\003'"
else
    echo "  # Render in background (no screen). Tail nohup output:"
    echo "  tail -f nohup_render.log"
    echo
    echo "  # Render PID: ${RENDER_BG_PID:-(check via pgrep buddhabrot)}"
    echo "  # Manually kill the render (rare):"
    echo "  kill -USR1 \$(cat $OUTPUT_BASE.pid 2>/dev/null) 2>/dev/null  # graceful save+exit"
    echo "  # or: pkill -USR1 buddhabrot"
fi
echo
echo "  # Tail the renderer stderr log:"
echo "  tail -f $OUTPUT_BASE.stderr.log"
echo
echo "  # Quick health check:"
echo "  nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv"
echo "  ls -lh $OUTPUT_BASE*.bin 2>/dev/null"
echo
if [ "$PRIVILEGE" = "root" ] || [ -n "$APT_PREFIX" ]; then
    echo "  # Linux-level shutdown safety net (recommended): 24 hr from now"
    echo "  ${APT_PREFIX}shutdown +1440   # cancel anytime with: ${APT_PREFIX}shutdown -c"
    echo
fi
echo "  # Monitor HF bucket from your laptop:"
echo "  https://huggingface.co/buckets/$HF_BUCKET"
echo
echo "Expected timeline (at 12 M/s on H100):"
echo "  T+1 hr   first checkpoint, ~67 B samples in cp.bin (HF sync ~5 min later)"
echo "  T+12 hr  ~12 cps accumulated, ~800 B samples"
echo "  T+22:30  SIGUSR1 fires; render finishes current round, runs final save"
echo "  T+23     hard cap, render exits cleanly with .DONE flag"
echo "  T+23+    final HF sync completes, ~1-1.5 T samples in final .bin"
echo
