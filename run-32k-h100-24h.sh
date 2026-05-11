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
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
DRIVER_MAJOR=$(echo "$DRIVER_VER" | cut -d. -f1)
echo "[gpu] $GPU_NAME — $GPU_MEM MiB — $GPU_COUNT GPU(s) — driver $DRIVER_VER"
case "$GPU_NAME" in
    *H100*|*H200*|*B200*) echo "[gpu] datacenter-class; good" ;;
    *) echo "[gpu] WARN: GPU not H100/H200/B200 class. 32K histogram needs ~24 GB VRAM." ;;
esac
if [ "$GPU_MEM" -lt 25000 ]; then
    echo "ERROR: GPU has < 25 GB VRAM. 32K histogram needs 19.3 GB + ~4 GB working = ~24 GB."
    exit 1
fi

# Driver-version pre-flight. Hyperbolic ships driver 535.x which limits the
# CUDA runtime to 12.2. For our buddhabrot binary that's fine (sm_90 H100
# only needs CUDA 12.0+), but if you also want to compile/run sm_120
# (Blackwell / 5090), you'd need driver 550+ which requires apt-upgrade +
# reboot. Pure-CUDA pipeline (no torch), so we don't need 12.4+ for the
# Python stack — but document the constraint either way.
if [ "$DRIVER_MAJOR" -lt 550 ]; then
    echo "[driver] WARN: driver $DRIVER_VER < 550. OK for H100/H200 but NOT for 5090/sm_120."
    echo "         If you ever want to use Blackwell, upgrade: sudo apt-get install nvidia-driver-570"
    echo "         (Reboot kills your SSH session — reconnect after 1-3 min. Render starts AFTER upgrade.)"
elif [ "$DRIVER_MAJOR" -lt 535 ]; then
    echo "ERROR: driver $DRIVER_VER is ancient. Upgrade before running:"
    echo "       sudo apt-get update && sudo apt-get install -y nvidia-driver-570 && sudo reboot"
    exit 1
fi

# CUDA toolkit version (used by build.sh). H100 needs CUDA 12.0+, fine on
# Hyperbolic's 12.2. Builder script will auto-skip sm_120 if nvcc < 12.6.
if command -v nvcc >/dev/null; then
    NVCC_VER=$(nvcc --version | grep -oE 'release [0-9]+\.[0-9]+' | head -1)
    echo "[cuda] $NVCC_VER (used for build; sm_120 auto-skipped if < 12.6)"
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

# Pick session manager via PROBE (not just presence check). Each candidate
# is tested by starting a 60-sec dummy session and verifying it actually
# stuck — `command -v` says nothing about whether the binary works in this
# environment. K0 lesson §2.12: screen breaks on Hyperbolic's stock image
# with [screen is terminating] due to /var/run/screen perms.
#
# Order: tmux first (works everywhere per K0 + our own experience), then
# screen (with SCREENDIR=~/.screen workaround if the default dir is broken),
# then apt-install tmux if privileged, finally nohup.
#
# Failproof: if any probe fails, fall through to the next; the prior
# linear-preference behavior (screen > tmux > nohup) is recoverable by
# `git revert` on this commit if the new logic causes trouble.
PROBE_ID="_probe_$$"
SESSION_TOOL=""

if command -v tmux >/dev/null; then
    if tmux new-session -d -s "$PROBE_ID" "sleep 60" 2>/dev/null; then
        sleep 0.3
        if tmux has-session -t "$PROBE_ID" 2>/dev/null; then
            tmux kill-session -t "$PROBE_ID" 2>/dev/null
            SESSION_TOOL="tmux"
            echo "[deps] tmux probe: PASS"
        else
            echo "[deps] tmux probe: started but vanished — trying screen"
        fi
    else
        echo "[deps] tmux probe: failed to start — trying screen"
    fi
fi

if [ -z "$SESSION_TOOL" ] && command -v screen >/dev/null; then
    if screen -dmS "$PROBE_ID" sleep 60 2>/dev/null && sleep 0.3 && screen -ls 2>/dev/null | grep -q "$PROBE_ID"; then
        screen -S "$PROBE_ID" -X quit 2>/dev/null
        SESSION_TOOL="screen"
        echo "[deps] screen probe: PASS"
    else
        # K0 §2.12 workaround: stock /var/run/screen perms can be wrong;
        # try a private SCREENDIR.
        mkdir -p "$HOME/.screen" && chmod 700 "$HOME/.screen"
        export SCREENDIR="$HOME/.screen"
        if screen -dmS "$PROBE_ID" sleep 60 2>/dev/null && sleep 0.3 && screen -ls 2>/dev/null | grep -q "$PROBE_ID"; then
            screen -S "$PROBE_ID" -X quit 2>/dev/null
            SESSION_TOOL="screen"
            echo "[deps] screen probe (SCREENDIR=\$HOME/.screen workaround): PASS"
        else
            unset SCREENDIR
            echo "[deps] screen probe: FAIL (even with SCREENDIR workaround)"
        fi
    fi
fi

if [ -z "$SESSION_TOOL" ] && { [ -n "$APT_PREFIX" ] || [ "$PRIVILEGE" = "root" ]; }; then
    echo "[deps] no working session manager; installing tmux via ${APT_PREFIX:-}apt-get..."
    if ${APT_PREFIX}apt-get update -qq && ${APT_PREFIX}apt-get install -y -qq tmux; then
        if tmux new-session -d -s "$PROBE_ID" "sleep 60" 2>/dev/null; then
            sleep 0.3
            if tmux has-session -t "$PROBE_ID" 2>/dev/null; then
                tmux kill-session -t "$PROBE_ID" 2>/dev/null
                SESSION_TOOL="tmux"
                echo "[deps] post-install tmux probe: PASS"
            fi
        fi
    fi
fi

if [ -z "$SESSION_TOOL" ]; then
    echo "[deps] WARN: no working tmux/screen and no apt privilege."
    echo "       Render will run via nohup — survives SSH disconnect but no"
    echo "       interactive reattach. Output goes to nohup_render.log."
    SESSION_TOOL="nohup"
fi
echo "[deps] session manager: $SESSION_TOOL"

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
# Launch — detached session via screen | tmux | nohup. All three survive
# SSH disconnect; screen/tmux additionally allow interactive reattach.
# -------------------------------------------------------------------------
SESSION="h100_32k"

# Build the launch command shared across all three paths
LAUNCH_INNER="export N_DEVICES=$N_DEVICES \
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
./run-cloud-hyperbolic.sh; \
echo 'Render exited at '\$(date -u)"

if [ "$SESSION_TOOL" = "screen" ]; then
    screen -S "$SESSION" -X quit 2>/dev/null || true
    sleep 1
    screen -dmS "$SESSION" bash -c "$LAUNCH_INNER; exec bash"
    sleep 2
    if screen -ls | grep -q "$SESSION"; then
        echo
        echo "[launch] render running in screen session '$SESSION'"
        echo "[launch] reattach: screen -r $SESSION  (Ctrl-A D to detach)"
    else
        echo "ERROR: screen session failed to start"
        exit 1
    fi
elif [ "$SESSION_TOOL" = "tmux" ]; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 1
    tmux new-session -d -s "$SESSION" bash -c "$LAUNCH_INNER; exec bash"
    sleep 2
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo
        echo "[launch] render running in tmux session '$SESSION'"
        echo "[launch] reattach: tmux attach -t $SESSION  (Ctrl-B D to detach)"
    else
        echo "ERROR: tmux session failed to start"
        exit 1
    fi
else
    # nohup fallback — render survives SSH disconnect via SIGHUP ignore,
    # but no interactive reattach. Output goes to nohup_render.log.
    echo
    echo "[launch] starting render via nohup (no screen/tmux available)"
    nohup bash -c "$LAUNCH_INNER" > nohup_render.log 2>&1 &
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
case "$SESSION_TOOL" in
    screen)
        echo "  # Reattach to render (Ctrl-A D to detach without killing):"
        echo "  screen -r $SESSION"
        echo
        echo "  # Manually kill the render (rare):"
        echo "  screen -S $SESSION -X stuff \$'\\003'"
        ;;
    tmux)
        echo "  # Reattach to render (Ctrl-B D to detach without killing):"
        echo "  tmux attach -t $SESSION"
        echo
        echo "  # Manually kill the render (rare):"
        echo "  tmux send-keys -t $SESSION C-c"
        ;;
    nohup)
        echo "  # Render in background. Tail nohup output:"
        echo "  tail -f nohup_render.log"
        echo
        echo "  # Render PID: ${RENDER_BG_PID:-(check via pgrep buddhabrot)}"
        echo "  # Graceful save+exit (waits for round to finish):"
        echo "  pkill -USR1 buddhabrot"
        ;;
esac
echo
echo "  # Tail the renderer stderr log:"
echo "  tail -f $OUTPUT_BASE.stderr.log"
echo
echo "  # Quick health check:"
echo "  nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv"
echo "  ls -lh $OUTPUT_BASE*.bin 2>/dev/null"
echo
echo "  # IMPORTANT — terminal silence DOES NOT mean the render is stalled."
echo "  # The supervise wrapper redirects render stdout/stderr to log files."
echo "  # Source of truth = nvidia-smi GPU utilization. If util > 50%, alive."
echo "  # If terminal silent BUT nvidia-smi shows util, render is fine — do"
echo "  # NOT Ctrl-C. Tail the log file in a separate SSH tab instead."
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
