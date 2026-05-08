#!/usr/bin/env bash
# Cloud watchdog: launches buddhabrot, monitors wallclock, fires SIGUSR1 at
# T-N seconds before hard cap to trigger graceful save+exit, then SIGTERM if
# still running. Also runs an inotify loop on the output directory and fires
# background HF sync uploads as new checkpoint .bin files appear.
#
# Usage:
#   _supervise-cloud.sh --output-base BASE --hard-cap SEC --sigusr1-lead SEC
#                       --hf-sync 0|1 --hf-bucket USER/BUCKET -- CMD ARGS...

set -uo pipefail

# Parse args
OUTPUT_BASE=""
HARD_CAP=5400
SIGUSR1_LEAD=300
HF_SYNC_ENABLED=0
HF_BUCKET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --output-base)   OUTPUT_BASE="$2"; shift 2 ;;
        --hard-cap)      HARD_CAP="$2";    shift 2 ;;
        --sigusr1-lead)  SIGUSR1_LEAD="$2"; shift 2 ;;
        --hf-sync)       HF_SYNC_ENABLED="$2"; shift 2 ;;
        --hf-bucket)     HF_BUCKET="$2"; shift 2 ;;
        --) shift; break ;;
        *)  echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$OUTPUT_BASE" ] || [ $# -eq 0 ]; then
    echo "usage: _supervise-cloud.sh --output-base BASE [opts] -- CMD ARGS..." >&2
    exit 2
fi

LOG_PATH="${OUTPUT_BASE}.stderr.log"
PID_PATH="${OUTPUT_BASE}.pid"
DONE_PATH="${OUTPUT_BASE}.DONE"
FATAL_PATH="${OUTPUT_BASE}.FATAL"
WATCHDOG_LOG="${OUTPUT_BASE}.watchdog.log"

log() {
    echo "[watchdog $(date -u +%H:%M:%S)] $*" | tee -a "$WATCHDOG_LOG" >&2
}

# Background HF sync helper (one-shot per checkpoint)
hf_sync_one() {
    local fpath="$1"
    if [ "$HF_SYNC_ENABLED" != "1" ]; then return; fi
    if [ -z "$HF_BUCKET" ]; then return; fi
    local bn
    bn=$(basename "$fpath")
    local synclog="${fpath}.hfsync.log"
    log "  HF sync $bn -> hf://buckets/$HF_BUCKET (background)"
    (
        if command -v hf >/dev/null 2>&1; then
            hf upload --repo-type bucket "$HF_BUCKET" "$fpath" "$bn" \
                --commit-message "watchdog cp $(date -u +%Y%m%dT%H%M%SZ)" \
                > "$synclog" 2>&1 \
                || echo "[hf-sync FAIL] $bn" >> "$synclog"
        elif command -v huggingface-cli >/dev/null 2>&1; then
            huggingface-cli upload --repo-type bucket "$HF_BUCKET" "$fpath" "$bn" \
                > "$synclog" 2>&1 \
                || echo "[hf-sync FAIL] $bn" >> "$synclog"
        fi
    ) &
    echo "$!" > "${fpath}.hfsync.pid"
}

# Track which checkpoints we've already kicked sync for
declare -A SYNCED

scan_and_sync() {
    [ "$HF_SYNC_ENABLED" = "1" ] || return
    for f in "${OUTPUT_BASE}".cp*.bin "${OUTPUT_BASE}.bin"; do
        [ -f "$f" ] || continue
        # Skip files still being written (atomic rename writes <path>.tmp first)
        if [ -f "${f}.tmp" ]; then continue; fi
        # Skip files with size < 1 MB (probably mid-write)
        local sz
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        [ "$sz" -gt 1000000 ] || continue
        # Skip if already synced
        if [ -n "${SYNCED[$f]:-}" ]; then continue; fi
        SYNCED["$f"]=1
        hf_sync_one "$f"
    done
}

# Launch render in background
log "launching: $* (hard-cap ${HARD_CAP}s, SIGUSR1 at T-${SIGUSR1_LEAD}s)"
"$@" > "$LOG_PATH" 2>&1 &
RENDER_PID=$!
echo "$RENDER_PID" > "$PID_PATH"
log "render PID: $RENDER_PID"

START_TS=$(date +%s)
SIGUSR1_AT=$(( START_TS + HARD_CAP - SIGUSR1_LEAD ))
HARD_AT=$(( START_TS + HARD_CAP ))
SIGUSR1_FIRED=0
SIGTERM_FIRED=0

# Forward Ctrl-C / SIGTERM from supervisor to render process
forward_term() {
    log "received SIGTERM/SIGINT; forwarding to render PID $RENDER_PID"
    kill -TERM "$RENDER_PID" 2>/dev/null || true
}
trap forward_term TERM INT

# Main monitor loop — 5 sec polling cadence.
while kill -0 "$RENDER_PID" 2>/dev/null; do
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TS ))

    # SIGUSR1 trigger
    if [ "$SIGUSR1_FIRED" = "0" ] && [ "$NOW" -ge "$SIGUSR1_AT" ]; then
        log "T-${SIGUSR1_LEAD}s reached; firing SIGUSR1 to render PID $RENDER_PID"
        kill -USR1 "$RENDER_PID" 2>/dev/null || true
        SIGUSR1_FIRED=1
    fi

    # SIGTERM hard trigger
    if [ "$SIGTERM_FIRED" = "0" ] && [ "$NOW" -ge "$HARD_AT" ]; then
        log "HARD CAP reached at ${ELAPSED}s; firing SIGTERM"
        kill -TERM "$RENDER_PID" 2>/dev/null || true
        SIGTERM_FIRED=1
        # Give it 60 sec to clean up, then SIGKILL
        sleep 60
        if kill -0 "$RENDER_PID" 2>/dev/null; then
            log "SIGTERM did not work; SIGKILL"
            kill -KILL "$RENDER_PID" 2>/dev/null || true
        fi
    fi

    # Background checkpoint sync
    scan_and_sync

    sleep 5
done

# Render exited — wait and capture exit code
wait "$RENDER_PID"
EXIT_CODE=$?
END_TS=$(date +%s)
TOTAL_SEC=$(( END_TS - START_TS ))

log "render exited code=$EXIT_CODE after ${TOTAL_SEC}s"

# Final scan: any straggler checkpoints / final output
scan_and_sync

# Sync final output (PNG + BIN)
if [ "$HF_SYNC_ENABLED" = "1" ]; then
    for f in "${OUTPUT_BASE}.png" "${OUTPUT_BASE}.bin" "${OUTPUT_BASE}.stderr.log" "${OUTPUT_BASE}.watchdog.log" "${OUTPUT_BASE}.launch.log"; do
        if [ -f "$f" ] && [ -z "${SYNCED[$f]:-}" ]; then
            hf_sync_one "$f"
        fi
    done
    log "waiting up to 600s for HF sync background jobs to finish..."
    SYNC_DEADLINE=$(( $(date +%s) + 600 ))
    while [ "$(date +%s)" -lt "$SYNC_DEADLINE" ]; do
        ANY_RUNNING=0
        for pid_file in "${OUTPUT_BASE}".*.hfsync.pid; do
            [ -f "$pid_file" ] || continue
            local_pid=$(cat "$pid_file" 2>/dev/null || echo 0)
            if [ -n "$local_pid" ] && [ "$local_pid" != "0" ] && kill -0 "$local_pid" 2>/dev/null; then
                ANY_RUNNING=1
            fi
        done
        [ "$ANY_RUNNING" = "0" ] && break
        sleep 5
    done
    log "HF sync wait done"
fi

if [ "$EXIT_CODE" = "0" ]; then
    log "DONE (exit 0)"
    : > "$DONE_PATH"
else
    log "FATAL (exit $EXIT_CODE)"
    : > "$FATAL_PATH"
fi

exit "$EXIT_CODE"
