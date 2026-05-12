#!/usr/bin/env bash
# Single H200 141 GB / 64K monolithic render / 24-hour budget.
#
# 64K = 65536 × 49152 = 3.22 Gpx (16× the pixels of 16K, 4× the pixels of 32K).
# Histogram footprint: 76.9 GB (uint64 × 3 channels). VRAM total need: ~82 GB
# including driver/working buffers. Therefore:
#   - H100 80 GB:    OOMs at first launch (~2 GB short). DO NOT USE.
#   - H100 NVL 94GB: fits with ~12 GB headroom.
#   - H200 141 GB:   fits with ~59 GB headroom — recommended.
#   - B200 192 GB:   fits with ~110 GB headroom — overkill but works.
#
# At an expected H200 throughput of ~15-20 M IS samples/sec (1.5-2× H100 PCIe
# due to HBM3 bandwidth headroom, the renderer being memory-atomic-bound):
#   - 24h × 18 M/s = 1.56 T samples → ~485 traj/px native
#   - Compared to 32K@24h on H100: 920 B / 805 Mpx = 1143 traj/px native
#   - But at display-size (downsampled to 4K), 64K@485 ≈ 32K@1940 traj/px
#     equivalent per source-area, due to 4× more averaging.
#
# Each cp.bin is 77 GB — disk cleanup is mandatory. The script wires an
# aggressive cleanup loop that keeps only the MOST RECENT 1 cp locally (vs
# the 32K script's 2). HF sync loop runs every 15 min. Each new cp is on HF
# before the prior one is deleted from local.
#
# Pre-requisites:
#   - buddhabrot binary built  (./build.sh)
#   - imap.bin                 (./build_imap.sh) — same canonical IMap, resolution-independent
#   - tmux installed           (probe + apt-install if missing)
#
# Usage:
#   export HF_TOKEN=hf_...
#   export HF_BUCKET=bochen2079/buddhabrot
#   bash run-64k-h200.sh
#
# Reattach to render:
#   tmux attach -t h200_64k
# Detach without killing: Ctrl-B D

set -euo pipefail
cd "$(dirname "$0")"

# -------------------------------------------------------------------------
# Pre-flight + privilege detection
# -------------------------------------------------------------------------
echo "============================================================"
echo "Single H200 64K production render — 24 hour budget"
echo "============================================================"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)"
echo "User: $(whoami)"

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

# Whitelist: 64K-capable GPUs. H100 80GB is intentionally NOT here.
case "$GPU_NAME" in
    *H200*|*B200*|*B100*)
        echo "[gpu] 64K-capable datacenter GPU; good"
        ;;
    *H100*NVL*|*H100*nvl*|*"H100 NVL"*)
        echo "[gpu] H100 NVL (94GB) — should fit 64K with ~12GB headroom"
        ;;
    *H100*)
        echo "############################################################"
        echo "##  H100 80GB CANNOT FIT 64K HISTOGRAM (need ~82GB)        ##"
        echo "##  Use H100 NVL, H200, or B200 instead.                   ##"
        echo "############################################################"
        echo "  If you really want to proceed and have configured custom"
        echo "  smaller resolution via env vars, set OVERRIDE_GPU=1 to skip"
        echo "  this guard. Otherwise this script will exit."
        if [ "${OVERRIDE_GPU:-0}" != "1" ]; then
            exit 1
        fi
        echo "  [gpu] OVERRIDE_GPU=1 set; proceeding at your own risk."
        ;;
    *)
        echo "[gpu] WARN: GPU not recognized as 64K-capable. Continuing anyway."
        ;;
esac

if [ "$GPU_MEM" -lt 85000 ]; then
    echo "ERROR: GPU has < 85 GB VRAM. 64K histogram needs 77 GB + ~5 GB working = ~82 GB."
    echo "       Either use a larger GPU, or reduce WIDTH/HEIGHT and re-run."
    exit 1
fi

# Driver-version check. H200/B200 require driver 555+, but they're rarely
# shipped on older drivers. Warn if old.
if [ "$DRIVER_MAJOR" -lt 555 ]; then
    echo "[driver] WARN: driver $DRIVER_VER < 555. H200/B200 typically ship 570+."
    echo "         If a kernel crashes early, suspect driver mismatch."
fi

# CUDA toolkit
if command -v nvcc >/dev/null; then
    NVCC_VER=$(nvcc --version | grep -oE 'release [0-9]+\.[0-9]+' | head -1)
    echo "[cuda] $NVCC_VER (H200 needs CUDA 12.0+; B200 needs 12.6+)"
fi

# VRAM-used pre-flight (pod-reuse defense, same as 32K script)
GPU_MEM_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
if [[ "$GPU_MEM_USED" =~ ^[0-9]+$ ]]; then
    GPU_MEM_AVAIL=$((GPU_MEM - GPU_MEM_USED))
    echo "[gpu] VRAM: ${GPU_MEM_USED} MiB used / ${GPU_MEM} MiB total → ${GPU_MEM_AVAIL} MiB available"
    if [ "$GPU_MEM_AVAIL" -lt 85000 ]; then
        echo
        echo "############################################################"
        echo "##                                                        ##"
        echo "##     !!!  NOT ENOUGH FREE VRAM TO LAUNCH 64K  !!!       ##"
        echo "##                                                        ##"
        echo "############################################################"
        echo
        echo "  Required: ~85 GB available (82 GB histogram + ~3 GB margin)"
        echo "  Have:     ${GPU_MEM_AVAIL} MiB available of ${GPU_MEM} MiB total"
        echo "  In use:   ${GPU_MEM_USED} MiB held by another process"
        echo
        echo "  ## Nuke stale GPU processes:"
        echo "    pkill -9 -f python3 ; sleep 2"
        echo "  ## Verify clean:"
        echo "    nvidia-smi --query-gpu=memory.used --format=csv,noheader"
        echo
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null || true
        exit 1
    elif [ "$GPU_MEM_USED" -gt 1000 ]; then
        echo "[gpu] WARN: ${GPU_MEM_USED} MiB VRAM held by another process. Continuing in 10s; Ctrl-C to abort."
        sleep 10
    fi
fi

# Disk pre-flight — 64K needs more disk headroom than 32K
DISK_AVAIL_GB=$(df -BG "$HOME" | tail -1 | awk '{print $4}' | tr -d 'G')
if [[ "$DISK_AVAIL_GB" =~ ^[0-9]+$ ]]; then
    echo "[disk] available: ${DISK_AVAIL_GB} GB"
    if [ "$DISK_AVAIL_GB" -lt 200 ]; then
        echo "[disk] WARN: < 200 GB free. Each cp.bin is 77 GB. Cleanup loop"
        echo "       keeps only most recent locally, but HF sync can lag by"
        echo "       up to 15 min — peak local disk could hit 155 GB."
        echo "       Provision more disk or accept periodic OOD risk."
    fi
fi

# Build buddhabrot if missing
if [ ! -x ./buddhabrot ]; then
    echo "[build] compiling buddhabrot..."
    ./build.sh
fi

# IMap is resolution-independent — same canonical IMap works for 16K/32K/64K
if [ ! -f imap.bin ]; then
    echo "[imap] building canonical IMap..."
    ./build_imap.sh
fi

# Session manager probe (same logic as run-32k-h100-24h.sh)
PROBE_ID="_probe_$$"
SESSION_TOOL=""
if command -v tmux >/dev/null; then
    if tmux new-session -d -s "$PROBE_ID" "sleep 60" 2>/dev/null && sleep 0.3 && tmux has-session -t "$PROBE_ID" 2>/dev/null; then
        tmux kill-session -t "$PROBE_ID" 2>/dev/null
        SESSION_TOOL="tmux"
        echo "[deps] tmux probe: PASS"
    fi
fi
if [ -z "$SESSION_TOOL" ] && command -v screen >/dev/null; then
    if screen -dmS "$PROBE_ID" sleep 60 2>/dev/null && sleep 0.3 && screen -ls 2>/dev/null | grep -q "$PROBE_ID"; then
        screen -S "$PROBE_ID" -X quit 2>/dev/null
        SESSION_TOOL="screen"
        echo "[deps] screen probe: PASS"
    fi
fi
if [ -z "$SESSION_TOOL" ] && { [ -n "$APT_PREFIX" ] || [ "$PRIVILEGE" = "root" ]; }; then
    echo "[deps] installing tmux..."
    if ${APT_PREFIX}apt-get update -qq && ${APT_PREFIX}apt-get install -y -qq tmux; then
        tmux new-session -d -s "$PROBE_ID" "sleep 60" 2>/dev/null && tmux kill-session -t "$PROBE_ID" 2>/dev/null && SESSION_TOOL="tmux"
    fi
fi
[ -z "$SESSION_TOOL" ] && SESSION_TOOL="nohup"
echo "[deps] session manager: $SESSION_TOOL"

# HF auth + sync loop
HF_SYNC_ENABLED=0
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
    if ! command -v hf >/dev/null; then
        echo "[hf] installing huggingface_hub..."
        pip install -U -q $PIP_USER_FLAG huggingface_hub --break-system-packages 2>/dev/null || \
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

if [ "$HF_SYNC_ENABLED" = "1" ]; then
    pkill -f "hf sync.*buddhabrot_cloud_64k" 2>/dev/null || true
    nohup bash -c '
        cd '"$(pwd)"'
        while true; do
            echo "[hf-loop $(date -u +%H:%M:%S)] sync pass"
            hf sync . hf://buckets/'"$HF_BUCKET"'/ \
                --include "buddhabrot_cloud_64k*.bin" \
                --include "buddhabrot_cloud_64k*.png" \
                --include "buddhabrot_cloud_64k*.log" \
                2>&1 | tail -5
            sleep 900
        done
    ' > /tmp/hf_loop.log 2>&1 &
    disown
    echo "[hf] background sync loop PID $!  log: /tmp/hf_loop.log"
fi

# Aggressive local cleanup — each .bin is 77 GB so keep only most recent 1
nohup bash -c '
    while true; do
        # Keep most recent 1 locally; HF has the rest
        DELETED=$(ls -1t '"$(pwd)"'/buddhabrot_cloud_64k*.cp*.bin 2>/dev/null | tail -n +2 | xargs -r rm -v)
        if [ -n "$DELETED" ]; then
            echo "[$(date -u +%H:%M:%S)] cleanup deleted:"
            echo "$DELETED"
        fi
        sleep 600
    done
' > /tmp/cleanup_loop.log 2>&1 &
disown
echo "[cleanup] local-disk cleanup loop PID $!  log: /tmp/cleanup_loop.log"

# -------------------------------------------------------------------------
# Configuration — overridable via env
# -------------------------------------------------------------------------
export N_DEVICES="${N_DEVICES:-1}"
export WIDTH="${WIDTH:-65536}"
export HEIGHT="${HEIGHT:-49152}"
# Target 2T samples = ~28h at 20 M/s (H200 estimated). With 23h wallclock cap,
# we'll get ~1.5-1.7T = ~470-530 traj/px. Plenty of slack.
export TARGET_SAMPLES="${TARGET_SAMPLES:-2000000000000}"
# Trims are density-dependent — predicted for 64K@500 traj/px. Retune post-render.
export TRIM_R="${TRIM_R:-0.42}"
export TRIM_G="${TRIM_G:-0.30}"
export TRIM_B="${TRIM_B:-0.17}"
# Checkpoint cadence — non-uniform schedule per user spec:
#   first 3 cps at 30-min intervals (T+30, T+60, T+90) for early validation,
#   then 60-min intervals thereafter.
# Schedule is in ROUNDS (round numbers based on a 22 M/s H200 throughput estimate
# at 3.05 sec/round). If H200 actual rate differs by ±30%, cp times shift
# proportionally but still cover the run.
# Computed as: 590=30min, 1180=60min, 1770=90min, then +1180 (60 min) each.
# Final schedule entry at round 25370 ≈ T+22h, before SIGUSR1 fires at 22.5h.
#
# CHECKPOINT_EVERY=0 disables the uniform cadence — schedule is the only path.
# To override and use simple uniform cadence, set CHECKPOINT_EVERY=590 (30 min)
# or CHECKPOINT_EVERY=1180 (60 min) and CHECKPOINT_SCHEDULE="".
export CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-0}"
export CHECKPOINT_SCHEDULE="${CHECKPOINT_SCHEDULE:-590,1180,1770,2950,4130,5310,6490,7670,8850,10030,11210,12390,13570,14750,15930,17110,18290,19470,20650,21830,23010,24190,25370}"
export LAUNCHES_PER_ROUND="${LAUNCHES_PER_ROUND:-8}"
export SAMPLES_PER_THREAD="${SAMPLES_PER_THREAD:-8}"
export WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-82800}"     # 23 hr
export SIGUSR1_LEAD="${SIGUSR1_LEAD:-1800}"                  # 30 min grace
export OUTPUT_BASE="${OUTPUT_BASE:-buddhabrot_cloud_64k_h200_24h}"

echo
echo "[config] resolution: ${WIDTH}x${HEIGHT}  target: ${TARGET_SAMPLES} samples"
if [ "$CHECKPOINT_EVERY" -gt 0 ]; then
    echo "[config] cp every:   ${CHECKPOINT_EVERY} rounds  (~$((CHECKPOINT_EVERY * 305 / 6000)) min at 22 M/s est)"
fi
if [ -n "$CHECKPOINT_SCHEDULE" ]; then
    SCHED_COUNT=$(echo "$CHECKPOINT_SCHEDULE" | tr ',' '\n' | wc -l)
    echo "[config] cp schedule: $SCHED_COUNT explicit rounds (first 3 every 30 min, then every 60 min)"
fi
echo "[config] cap:        ${WALLCLOCK_HARD_CAP}s = $((WALLCLOCK_HARD_CAP/3600)) hr"
echo "[config] SIGUSR1 at: T+$((WALLCLOCK_HARD_CAP - SIGUSR1_LEAD))s"
echo "[config] trims:      R=$TRIM_R G=$TRIM_G B=$TRIM_B (predicted for 64K@500 traj/px; retune post-render)"

# Launch session
SESSION="h200_64k"
LAUNCH_INNER="export N_DEVICES=$N_DEVICES \
       WIDTH=$WIDTH HEIGHT=$HEIGHT \
       TARGET_SAMPLES=$TARGET_SAMPLES \
       TRIM_R=$TRIM_R TRIM_G=$TRIM_G TRIM_B=$TRIM_B \
       CHECKPOINT_EVERY=$CHECKPOINT_EVERY \
       CHECKPOINT_SCHEDULE='$CHECKPOINT_SCHEDULE' \
       LAUNCHES_PER_ROUND=$LAUNCHES_PER_ROUND \
       SAMPLES_PER_THREAD=$SAMPLES_PER_THREAD \
       WALLCLOCK_HARD_CAP=$WALLCLOCK_HARD_CAP \
       SIGUSR1_LEAD=$SIGUSR1_LEAD \
       OUTPUT_BASE=$OUTPUT_BASE \
       HF_BUCKET=$HF_BUCKET \
       HF_SYNC_ENABLED=$HF_SYNC_ENABLED; \
./run-cloud-hyperbolic.sh; \
echo 'Render exited at '\$(date -u)"

if [ "$SESSION_TOOL" = "tmux" ]; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 1
    tmux new-session -d -s "$SESSION" bash -c "$LAUNCH_INNER; exec bash"
    sleep 2
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo
        echo "[launch] render running in tmux session '$SESSION'"
        echo "[launch] reattach: tmux attach -t $SESSION  (Ctrl-B D to detach)"
    else
        echo "ERROR: tmux session failed to start"; exit 1
    fi
elif [ "$SESSION_TOOL" = "screen" ]; then
    screen -S "$SESSION" -X quit 2>/dev/null || true
    sleep 1
    screen -dmS "$SESSION" bash -c "$LAUNCH_INNER; exec bash"
    sleep 2
    if screen -ls | grep -q "$SESSION"; then
        echo
        echo "[launch] render running in screen session '$SESSION'"
        echo "[launch] reattach: screen -r $SESSION  (Ctrl-A D to detach)"
    else
        echo "ERROR: screen session failed to start"; exit 1
    fi
else
    nohup bash -c "$LAUNCH_INNER" > nohup_render.log 2>&1 &
    RENDER_BG_PID=$!
    disown
    echo "[launch] render running in background, PID $RENDER_BG_PID"
fi

echo
echo "============================================================"
echo "Render is going. Monitor:"
echo "============================================================"
echo
case "$SESSION_TOOL" in
    tmux)
        echo "  # Reattach (Ctrl-B D to detach):"
        echo "  tmux attach -t $SESSION"
        ;;
    screen)
        echo "  # Reattach (Ctrl-A D to detach):"
        echo "  screen -r $SESSION"
        ;;
    nohup)
        echo "  # Tail output:"
        echo "  tail -f nohup_render.log"
        ;;
esac
echo
echo "  # Tail render stderr:"
echo "  tail -f $OUTPUT_BASE.stderr.log"
echo
echo "  # GPU health:"
echo "  watch -n 5 nvidia-smi"
echo
echo "  # Disk pressure (each cp.bin = 77 GB; cleanup keeps only 1 local):"
echo "  df -h ~ ; ls -lh $OUTPUT_BASE*.bin 2>/dev/null"
echo
echo "  # Tail HF sync + cleanup loops:"
echo "  tail -f /tmp/hf_loop.log /tmp/cleanup_loop.log"
echo
echo "  # IMPORTANT — terminal silence DOES NOT mean the render is stalled."
echo "  # Source of truth = nvidia-smi GPU utilization. If util > 50%, alive."
echo
if [ "$PRIVILEGE" = "root" ] || [ -n "$APT_PREFIX" ]; then
    echo "  # Linux-level shutdown safety (recommended): 24 hr from now"
    echo "  ${APT_PREFIX}shutdown +1440   # cancel anytime with: ${APT_PREFIX}shutdown -c"
    echo
fi
echo "Expected timeline (at 18-22 M/s on H200):"
echo "  T+0:30  first checkpoint (~67 B samples in cp0600)"
echo "  T+12    ~12-16 cps, ~700-900 B samples"
echo "  T+22:30 SIGUSR1 fires, render finishes current round, final save"
echo "  T+23    hard cap, clean exit, final .bin uploaded"
echo "  Final:  ~1.5-1.7 T samples = ~470-530 traj/px native"
echo
