#!/bin/bash
# _supervise.sh — watchdog/supervisor for run-local.sh.
#
# Auto-restarts buddhabrot on crash with --resume-from from latest .bin.
# Bounded by MAX_RETRIES; aborts on no-progress or fast-fail loops; respects
# stop sentinel and SIGTERM. Updates a status.html file every 30 sec for
# browser-friendly monitoring.
#
# Receives all parameters via env vars from run-local.sh; not user-facing.
#
# Files written:
#   <output>.watchdog.log          — supervisor decision log
#   <output>.attempt${NN}.stderr.log — per-attempt buddhabrot stderr
#   <output>.status.html           — web-readable status (auto-refresh)
#   <output>.DONE                  — created on successful completion
#   <output>.FATAL                 — created on max-retries / no-progress / etc.
#
# User-controlled stop:
#   touch <output>.stop            — supervisor exits cleanly before next attempt
#   kill -TERM <supervisor-pid>    — same effect via signal

set -u
cd "$(dirname "$0")"

# Required env from run-local.sh
: "${BIN:?missing BIN}"
: "${OUT:?missing OUT}"
: "${WIDTH:?missing WIDTH}"
: "${HEIGHT:?missing HEIGHT}"
: "${SAMPLES:?missing SAMPLES}"
: "${SAMPLES_PER_THREAD:?missing SAMPLES_PER_THREAD}"
: "${LAUNCHES_PER_ROUND:?missing LAUNCHES_PER_ROUND}"
: "${CP_EVERY:?missing CP_EVERY}"
: "${TRIM_R:?missing TRIM_R}"
: "${TRIM_G:?missing TRIM_G}"
: "${TRIM_B:?missing TRIM_B}"
: "${WALLCLOCK_HARD_CAP:?missing WALLCLOCK_HARD_CAP}"

# Optional
IMAP_FLAGS_STR="${IMAP_FLAGS_STR:-}"
SUPPORTS_RAW="${SUPPORTS_RAW:-0}"

# Watchdog defaults (overridable from run-local.sh or user env)
MAX_RETRIES="${MAX_RETRIES:-5}"
RETRY_BACKOFF_SEC="${RETRY_BACKOFF_SEC:-30}"
RETRY_BACKOFF_MULT="${RETRY_BACKOFF_MULT:-2}"
NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"
FAST_FAIL_LIMIT="${FAST_FAIL_LIMIT:-3}"
FAST_FAIL_THRESHOLD_SEC="${FAST_FAIL_THRESHOLD_SEC:-60}"
MAX_TOTAL_WALLCLOCK_SEC="${MAX_TOTAL_WALLCLOCK_SEC:-172800}"  # 48h

# Derived paths
OUT_BASE="${OUT%.png}"
OUT_BIN="${OUT_BASE}.bin"
WATCHDOG_LOG="${OUT_BASE}.watchdog.log"
STATUS_HTML="${OUT_BASE}.status.html"
STOP_SENTINEL="${OUT_BASE}.stop"
DONE_FLAG="${OUT_BASE}.DONE"
FATAL_FLAG="${OUT_BASE}.FATAL"
RENDER_NAME="$(basename "$OUT_BASE")"

# Cleanup any stale flags from previous runs
rm -f "$DONE_FLAG" "$FATAL_FLAG" "$STOP_SENTINEL"

START_TS=$(date +%s)
ATTEMPT=0
LAST_SAMPLES_DONE=0
NO_PROGRESS_COUNT=0
FAST_FAIL_COUNT=0
CURRENT_BACKOFF=$RETRY_BACKOFF_SEC

log_super() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [SUPER] $*"
    echo "$msg"
    echo "$msg" >> "$WATCHDOG_LOG"
}

read_samples_done() {
    local bin_path="$1"
    [[ ! -f "$bin_path" ]] && { echo 0; return; }
    python tools/read_bin_header.py "$bin_path" samples_done 2>/dev/null || echo 0
}

update_status() {
    local state="$1"
    local detail="$2"
    local current_log="${OUT_BASE}.attempt$(printf '%03d' "${ATTEMPT:-0}").stderr.log"
    [[ ! -f "$current_log" ]] && current_log="$WATCHDOG_LOG"
    python tools/write_status_html.py \
        --output "$STATUS_HTML" \
        --render-name "$RENDER_NAME" \
        --resolution "${WIDTH}x${HEIGHT}" \
        --state "$state" \
        --detail "$detail" \
        --target-samples "$SAMPLES" \
        --bin "$OUT_BIN" \
        --log "$current_log" \
        --watchdog-log "$WATCHDOG_LOG" \
        --start-ts "$START_TS" \
        --attempt "${ATTEMPT:-0}" \
        --max-attempts "$MAX_RETRIES" 2>/dev/null || true
}

cleanup_on_exit() {
    local exit_code=$?
    log_super "supervisor exiting (code $exit_code)"
    pkill -P $$ buddhabrot 2>/dev/null || true
    pkill -P $$ buddhabrot.exe 2>/dev/null || true
    return $exit_code
}

handle_sigterm() {
    log_super "received SIGTERM — cleaning up and exiting"
    update_status "STOPPED" "Supervisor received SIGTERM"
    pkill -P $$ buddhabrot 2>/dev/null || true
    pkill -P $$ buddhabrot.exe 2>/dev/null || true
    exit 0
}

trap cleanup_on_exit EXIT
trap handle_sigterm TERM
trap handle_sigterm INT

log_super "supervisor starting; OUT=$OUT, MAX_RETRIES=$MAX_RETRIES, SUPPORTS_RAW=$SUPPORTS_RAW"
log_super "supervisor PID=$$ — kill -TERM $$ to stop, or: touch $STOP_SENTINEL"
update_status "STARTING" "Supervisor initialized"

# Background status updater — refresh status.html every 30 sec while a render is active
(
    while [[ ! -f "$DONE_FLAG" && ! -f "$FATAL_FLAG" && ! -f "$STOP_SENTINEL" ]]; do
        sleep 30
        # Read CURRENT_STATE from a tiny state file rather than parent's env
        if [[ -f "${OUT_BASE}.watchdog.state" ]]; then
            local_state=$(cat "${OUT_BASE}.watchdog.state" 2>/dev/null || echo "RUNNING")
            local_detail=$(cat "${OUT_BASE}.watchdog.detail" 2>/dev/null || echo "")
        else
            local_state="RUNNING"
            local_detail=""
        fi
        # Re-read attempt number too
        local_attempt=$(cat "${OUT_BASE}.watchdog.attempt" 2>/dev/null || echo 0)
        python tools/write_status_html.py \
            --output "$STATUS_HTML" \
            --render-name "$RENDER_NAME" \
            --resolution "${WIDTH}x${HEIGHT}" \
            --state "$local_state" \
            --detail "$local_detail" \
            --target-samples "$SAMPLES" \
            --bin "$OUT_BIN" \
            --log "${OUT_BASE}.attempt$(printf '%03d' "$local_attempt").stderr.log" \
            --watchdog-log "$WATCHDOG_LOG" \
            --start-ts "$START_TS" \
            --attempt "$local_attempt" \
            --max-attempts "$MAX_RETRIES" 2>/dev/null || true
    done
) &
STATUS_UPDATER_PID=$!
disown $STATUS_UPDATER_PID

# Helper to write current state to small files (status updater reads them)
set_state() {
    echo "$1" > "${OUT_BASE}.watchdog.state"
    echo "$2" > "${OUT_BASE}.watchdog.detail"
    echo "$ATTEMPT" > "${OUT_BASE}.watchdog.attempt"
}

while [[ $ATTEMPT -lt $MAX_RETRIES ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    set_state "STARTING" "preparing attempt $ATTEMPT/$MAX_RETRIES"

    # Stop sentinel check
    if [[ -f "$STOP_SENTINEL" ]]; then
        log_super "stop sentinel $STOP_SENTINEL detected; exiting cleanly"
        rm -f "$STOP_SENTINEL"
        update_status "STOPPED" "User created stop sentinel"
        exit 0
    fi

    # Wallclock cap
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))
    if [[ $ELAPSED -gt $MAX_TOTAL_WALLCLOCK_SEC ]]; then
        log_super "[FATAL] total wallclock cap exceeded ($ELAPSED > $MAX_TOTAL_WALLCLOCK_SEC); aborting"
        touch "$FATAL_FLAG"
        update_status "FATAL" "Total wallclock cap exceeded"
        exit 1
    fi

    # Detect existing .bin for resume
    RESUME_FLAGS=()
    if [[ -f "$OUT_BIN" && "$SUPPORTS_RAW" == "1" ]]; then
        SAMPLES_IN_BIN=$(read_samples_done "$OUT_BIN")
        log_super "attempt $ATTEMPT: existing $OUT_BIN with $SAMPLES_IN_BIN samples"

        # No-progress detection (skip on first attempt — no comparison yet)
        if [[ $ATTEMPT -gt 1 ]]; then
            if [[ $SAMPLES_IN_BIN -le $LAST_SAMPLES_DONE ]]; then
                NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
                log_super "no progress: $SAMPLES_IN_BIN <= $LAST_SAMPLES_DONE; count=$NO_PROGRESS_COUNT/$NO_PROGRESS_LIMIT"
                if [[ $NO_PROGRESS_COUNT -ge $NO_PROGRESS_LIMIT ]]; then
                    log_super "[FATAL] $NO_PROGRESS_COUNT consecutive attempts with no progress; aborting"
                    touch "$FATAL_FLAG"
                    update_status "FATAL" "No-progress detection: $NO_PROGRESS_LIMIT consecutive attempts without samples_done increase"
                    exit 1
                fi
            else
                NO_PROGRESS_COUNT=0
            fi
        fi
        LAST_SAMPLES_DONE=$SAMPLES_IN_BIN
        RESUME_FLAGS=(--resume-from "$OUT_BIN")
    fi

    # GPU sanity check before retry
    if ! nvidia-smi --query-gpu=name --format=csv,noheader > /dev/null 2>&1; then
        log_super "WARN: nvidia-smi failed; sleeping 60s before retry"
        sleep 60
        continue
    fi

    ATTEMPT_LOG="${OUT_BASE}.attempt$(printf '%03d' "$ATTEMPT").stderr.log"
    log_super "attempt $ATTEMPT/$MAX_RETRIES: launching buddhabrot, log=$ATTEMPT_LOG"
    set_state "RUNNING" "attempt $ATTEMPT of $MAX_RETRIES"
    update_status "RUNNING" "attempt $ATTEMPT of $MAX_RETRIES"

    ATTEMPT_START=$(date +%s)

    # Build flag arrays from string env vars (whitespace-separated)
    EXTRA_FLAGS=()
    [[ -n "$IMAP_FLAGS_STR" ]] && {
        # shellcheck disable=SC2206
        _imap=($IMAP_FLAGS_STR)
        EXTRA_FLAGS+=("${_imap[@]}")
    }

    # If §B7 supported, request raw output
    RAW_FLAGS=()
    [[ "$SUPPORTS_RAW" == "1" ]] && RAW_FLAGS=(--output-raw "$OUT_BIN")

    timeout --signal=SIGTERM --kill-after=300 "$WALLCLOCK_HARD_CAP" \
    "$BIN" \
        --width "$WIDTH" \
        --height "$HEIGHT" \
        --samples "$SAMPLES" \
        --devices 1 \
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
        --trim-r "$TRIM_R" \
        --trim-g "$TRIM_G" \
        --trim-b "$TRIM_B" \
        --samples-per-thread "$SAMPLES_PER_THREAD" \
        --launches-per-round "$LAUNCHES_PER_ROUND" \
        --checkpoint-every "$CP_EVERY" \
        "${EXTRA_FLAGS[@]}" \
        "${RAW_FLAGS[@]}" \
        "${RESUME_FLAGS[@]}" \
        --output "$OUT" \
        > "$ATTEMPT_LOG" 2>&1
    EXIT_CODE=$?

    ATTEMPT_END=$(date +%s)
    ATTEMPT_DURATION=$((ATTEMPT_END - ATTEMPT_START))

    if [[ $EXIT_CODE -eq 0 ]]; then
        log_super "attempt $ATTEMPT: SUCCESS in ${ATTEMPT_DURATION}s"
        touch "$DONE_FLAG"
        set_state "DONE" "Render completed successfully on attempt $ATTEMPT"
        update_status "DONE" "Render completed successfully on attempt $ATTEMPT"
        exit 0
    fi

    log_super "attempt $ATTEMPT: FAILED with exit $EXIT_CODE after ${ATTEMPT_DURATION}s"

    # Fast-fail detection (kernel never even ran long; structural problem likely)
    if [[ $ATTEMPT_DURATION -lt $FAST_FAIL_THRESHOLD_SEC ]]; then
        FAST_FAIL_COUNT=$((FAST_FAIL_COUNT + 1))
        log_super "fast-fail: ${ATTEMPT_DURATION}s < ${FAST_FAIL_THRESHOLD_SEC}s; count=$FAST_FAIL_COUNT/$FAST_FAIL_LIMIT"
        if [[ $FAST_FAIL_COUNT -ge $FAST_FAIL_LIMIT ]]; then
            log_super "[FATAL] $FAST_FAIL_COUNT consecutive fast-fail attempts; structural problem, aborting"
            touch "$FATAL_FLAG"
            set_state "FATAL" "Fast-fail loop: $FAST_FAIL_LIMIT consecutive attempts under ${FAST_FAIL_THRESHOLD_SEC}s"
            update_status "FATAL" "Fast-fail loop"
            exit 1
        fi
    else
        FAST_FAIL_COUNT=0
    fi

    # Backoff before next retry
    if [[ $ATTEMPT -lt $MAX_RETRIES ]]; then
        log_super "sleeping ${CURRENT_BACKOFF}s before retry $((ATTEMPT + 1))/$MAX_RETRIES..."
        set_state "BACKOFF" "Sleeping ${CURRENT_BACKOFF}s before next attempt"
        update_status "BACKOFF" "Sleeping ${CURRENT_BACKOFF}s before attempt $((ATTEMPT + 1))"

        # Sleep in 1-sec increments so stop sentinel is detected within 1 sec
        for ((i=0; i<CURRENT_BACKOFF; i++)); do
            if [[ -f "$STOP_SENTINEL" ]]; then
                log_super "stop sentinel during backoff; exiting"
                rm -f "$STOP_SENTINEL"
                update_status "STOPPED" "Stop sentinel during backoff"
                exit 0
            fi
            sleep 1
        done

        # Exponential backoff for next retry
        CURRENT_BACKOFF=$((CURRENT_BACKOFF * RETRY_BACKOFF_MULT))
    fi
done

log_super "[FATAL] max retries ($MAX_RETRIES) exhausted"
touch "$FATAL_FLAG"
set_state "FATAL" "Max retries ($MAX_RETRIES) exhausted"
update_status "FATAL" "Max retries ($MAX_RETRIES) exhausted"
exit 1
