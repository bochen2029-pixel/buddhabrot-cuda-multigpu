#!/bin/bash
# Local Buddhabrot render with §B7 autodetect / resume support and dual-format
# (.png + .bin) checkpoints. Resolution-flexible (16K default, 32K override via
# RESOLUTION=32K env). Same canonical view / iter / trim as the legacy reference.
#
# Hardened against the 2026-05-08 TDR incident:
#   - --samples-per-thread 8, --launches-per-round 64: per-launch ~1 sec at IS rate
#     (well under Windows TDR's 2 sec; harmless overhead on Linux)
#   - --checkpoint-every computed for ≥5 intermediate cpNNNN + final
#   - Auto-detect existing .bin: resume / fresh / abort prompt with 30 sec timeout
#     (default = resume on timeout if .bin exists; otherwise fresh)
#   - --output-raw enables resumability + RAW preservation for re-grading
#
# Env vars (all optional):
#   RESOLUTION         16K (default) or 32K
#   SAMPLES            target total samples (default depends on RESOLUTION)
#   MODE               is (default; uses imap.bin) or uniform
#   IMAP               path to imap.bin (default: imap.bin)
#   SAMPLES_PER_THREAD default 8 (TDR-safe)
#   LAUNCHES_PER_ROUND default 64
#   CP_INTERMEDIATE    target intermediate checkpoints, default 5
#   WALLCLOCK_HARD_CAP default 24h
#   RESUME_MODE        auto (default) | always | never
#   OUT                output PNG path (default depends on RESOLUTION + MODE)
#   FRESH              1 to force fresh render (alias for RESUME_MODE=never)
#
# Usage: ./run-local.sh   (interactive prompt if existing .bin found)
#        FRESH=1 ./run-local.sh   (skip prompt, always start fresh)
#        RESOLUTION=32K ./run-local.sh   (32K render — won't fit on 16 GB VRAM)
#        MODE=uniform ./run-local.sh   (uniform sampling, regression only)

set -euo pipefail
cd "$(dirname "$0")"

# CLAUDE.md section B1 guard
if grep -qE -- '--target-[rgb]' "$0"; then
    echo "ERROR: banned auto-derive flag in script. See CLAUDE.md section B1."
    exit 1
fi

BIN=""
for candidate in ./buddhabrot ./buddhabrot.exe; do
    [[ -x "$candidate" ]] && BIN="$candidate" && break
done
[[ -n "$BIN" ]] || { echo "ERROR: buddhabrot binary not found. Run build.bat (Windows) or build.sh (Linux)."; exit 1; }

# Detect §B7 feature support in the binary via --help.
HELP_OUTPUT=$("$BIN" --help 2>&1 || true)
if echo "$HELP_OUTPUT" | grep -q -- '--output-raw'; then
    SUPPORTS_RAW=1
else
    SUPPORTS_RAW=0
    echo "WARNING: this buddhabrot binary lacks --output-raw / --resume-from support."
    echo "         Render will be NON-RESUMABLE. Rebuild from source after adding §B7."
    echo "         Continuing with PNG-only checkpoints..."
fi

# Defaults per resolution
RESOLUTION="${RESOLUTION:-16K}"
case "$RESOLUTION" in
    16K|16k)
        WIDTH=16384; HEIGHT=12288
        SAMPLES_DEFAULT=50000000000  # 50B IS = production-quality 16K
        ;;
    32K|32k)
        WIDTH=32768; HEIGHT=24576
        SAMPLES_DEFAULT=25000000000000  # 25T (Plan B equivalent)
        ;;
    *)
        echo "ERROR: RESOLUTION must be 16K or 32K (got '$RESOLUTION')"
        exit 1
        ;;
esac

SAMPLES="${SAMPLES:-$SAMPLES_DEFAULT}"
WALLCLOCK_HARD_CAP="${WALLCLOCK_HARD_CAP:-24h}"
SAMPLES_PER_THREAD="${SAMPLES_PER_THREAD:-8}"
LAUNCHES_PER_ROUND="${LAUNCHES_PER_ROUND:-64}"
CP_INTERMEDIATE="${CP_INTERMEDIATE:-5}"
MODE="${MODE:-is}"
IMAP="${IMAP:-imap.bin}"
RESUME_MODE="${RESUME_MODE:-auto}"
[[ "${FRESH:-0}" == "1" ]] && RESUME_MODE="never"

# Compute checkpoint cadence for >= CP_INTERMEDIATE checkpoints + final.
SAMPLES_PER_LAUNCH=$((4096 * 256 * SAMPLES_PER_THREAD))
N_LAUNCHES=$(( (SAMPLES + SAMPLES_PER_LAUNCH - 1) / SAMPLES_PER_LAUNCH ))
N_ROUNDS=$(( (N_LAUNCHES + LAUNCHES_PER_ROUND - 1) / LAUNCHES_PER_ROUND ))
CP_EVERY=$(( N_ROUNDS / (CP_INTERMEDIATE + 1) ))
[[ "$CP_EVERY" -lt 1 ]] && CP_EVERY=1

if [[ "$MODE" == "is" ]]; then
    [[ -f "$IMAP" ]] || { echo "ERROR: --imap requires $IMAP. Build with: $BIN --build-imap $IMAP --imap-samples 1000000000"; exit 1; }
    TRIM_R=0.74; TRIM_G=0.74; TRIM_B=0.52
    IMAP_FLAGS=(--imap "$IMAP")
    OUT_DEFAULT="buddhabrot_local_${RESOLUTION,,}_IS_$(printf '%dT' $((SAMPLES / 1000000000000)))"
    [[ $SAMPLES -lt 1000000000000 ]] && OUT_DEFAULT="buddhabrot_local_${RESOLUTION,,}_IS_$(printf '%dB' $((SAMPLES / 1000000000)))"
elif [[ "$MODE" == "uniform" ]]; then
    TRIM_R=0.2673; TRIM_G=0.2051; TRIM_B=0.1270
    IMAP_FLAGS=()
    OUT_DEFAULT="buddhabrot_local_${RESOLUTION,,}_uniform_$(printf '%dT' $((SAMPLES / 1000000000000)))"
    [[ $SAMPLES -lt 1000000000000 ]] && OUT_DEFAULT="buddhabrot_local_${RESOLUTION,,}_uniform_$(printf '%dB' $((SAMPLES / 1000000000)))"
else
    echo "ERROR: MODE must be 'is' or 'uniform' (got '$MODE')"
    exit 1
fi

OUT="${OUT:-${OUT_DEFAULT}.png}"
OUT_BIN="${OUT%.png}.bin"

# §B7 autodetect: check for existing .bin matching the planned output base.
RESUME_FROM=""
if [[ "$SUPPORTS_RAW" == "1" && "$RESUME_MODE" != "never" && -f "$OUT_BIN" ]]; then
    BIN_SIZE=$(stat -c %s "$OUT_BIN" 2>/dev/null || echo 0)
    BIN_MTIME=$(stat -c %y "$OUT_BIN" 2>/dev/null || echo "?")
    echo ""
    echo "=== Existing render state detected ==="
    echo "    File:  $OUT_BIN"
    echo "    Size:  $((BIN_SIZE / 1024 / 1024)) MB"
    echo "    Mtime: $BIN_MTIME"
    echo ""
    if [[ "$RESUME_MODE" == "always" ]]; then
        echo "RESUME_MODE=always — resuming without prompt."
        RESUME_FROM="$OUT_BIN"
    else
        echo "Options:"
        echo "  [r] Resume from this .bin (continue accumulating to target $SAMPLES samples)"
        echo "  [f] Start fresh (archive existing files with timestamp suffix)"
        echo "  [a] Abort (leave files alone, don't launch)"
        echo ""
        read -t 30 -p "Choice [r/f/a, default=r after 30s]: " CHOICE || CHOICE="r"
        case "${CHOICE:-r}" in
            r|R|"")
                RESUME_FROM="$OUT_BIN"
                echo "Resuming from $OUT_BIN"
                ;;
            f|F)
                TS=$(date -u +%Y%m%dT%H%M%S)
                for f in "${OUT%.png}".png "${OUT%.png}".bin "${OUT%.png}".cp*.png "${OUT%.png}".cp*.bin "${OUT%.png}".stderr.log "${OUT%.png}".monitor.log; do
                    [[ -e "$f" ]] && mv "$f" "${f}.archived_${TS}" && echo "  archived $f -> ${f}.archived_${TS}"
                done
                ;;
            a|A)
                echo "Aborted by user."
                exit 0
                ;;
            *)
                echo "Unrecognized choice '$CHOICE'; aborting."
                exit 1
                ;;
        esac
    fi
fi

echo ""
echo "=== Running pre-flight dimensional audit (B13 mandatory)"
AUDIT_EXTRA_FLAGS=()
if [[ "$MODE" == "is" ]]; then
    # 4K validation reference for trim retune
    AUDIT_EXTRA_FLAGS+=(--validation-resolution 4K --validation-samples 5000000000)
fi
# Disable set -e around the audit: it returns nonzero on warnings/findings
# (which is correct behavior), and msys2 bash treats `var=$(cmd_with_nonzero)`
# as fatal under set -e even though the assignment itself succeeded.
set +e
AUDIT_OUTPUT=$(PYTHONIOENCODING=utf-8 python tools/preflight_audit.py \
    --resolution "$RESOLUTION" \
    --total-samples "$SAMPLES" \
    --mode "$MODE" \
    --reference-resolution 16K \
    --reference-samples 1024000000000 \
    "${AUDIT_EXTRA_FLAGS[@]}" 2>&1)
AUDIT_RC=$?
set -e
echo "$AUDIT_OUTPUT"
if [[ $AUDIT_RC -ne 0 ]]; then
    echo ""
    echo "=== AUDIT FAILED with $AUDIT_RC warnings/errors. ==="
    echo "    Per CLAUDE.md B13, you must acknowledge before launch."
    echo "    Type 'I understand' to proceed; anything else aborts."
    if [[ "${SKIP_AUDIT_PROMPT:-0}" == "1" ]]; then
        echo "    SKIP_AUDIT_PROMPT=1 — auto-acknowledging."
    else
        read -p "Acknowledgement: " ACK
        if [[ "$ACK" != "I understand" ]]; then
            echo "Aborted; audit not acknowledged."
            exit 1
        fi
    fi
    echo "    Audit acknowledged at $(date -u +'%Y-%m-%dT%H:%M:%SZ'). Proceeding."
fi

echo ""
echo "=== ${WIDTH} x ${HEIGHT} ($((WIDTH * HEIGHT / 1000000)) Mpx), $SAMPLES samples, --devices 1, MODE=$MODE"
echo "=== samples-per-thread=$SAMPLES_PER_THREAD launches-per-round=$LAUNCHES_PER_ROUND"
echo "=== Total: ~$N_LAUNCHES launches in ~$N_ROUNDS rounds"
echo "=== Checkpoints: every $CP_EVERY rounds (target $CP_INTERMEDIATE intermediate + final)"
echo "=== Trim: r=$TRIM_R g=$TRIM_G b=$TRIM_B"
echo "=== Hard wallclock cap: $WALLCLOCK_HARD_CAP"
echo "=== Output PNG: $OUT"
[[ "$SUPPORTS_RAW" == "1" ]] && echo "=== Output RAW: $OUT_BIN (uint64 histogram, ~$((WIDTH * HEIGHT * 3 * 8 / 1024 / 1024 / 1024)) GB)"
[[ -n "$RESUME_FROM" ]] && echo "=== Resuming from: $RESUME_FROM"
echo "=== Log: ${OUT%.png}.stderr.log (also per-attempt: ${OUT%.png}.attemptNNN.stderr.log)"
echo "=== Watchdog log: ${OUT%.png}.watchdog.log"
echo "=== Status HTML:  ${OUT%.png}.status.html  (open in Chrome; auto-refresh 10 sec)"
echo "=== Launching at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# Watchdog mode (default ON; disable via WATCHDOG=0). Auto-resumes on crash.
WATCHDOG="${WATCHDOG:-1}"

# IMAP flag string (whitespace-separated) for supervisor's env-passed array reconstruction
IMAP_FLAGS_STR=""
if [[ ${#IMAP_FLAGS[@]} -gt 0 ]]; then
    IMAP_FLAGS_STR="${IMAP_FLAGS[*]}"
fi

if [[ "$WATCHDOG" == "1" && -x ./_supervise.sh ]]; then
    # If user wants to resume from a specific .bin (auto-detect prompted earlier),
    # ensure $OUT_BIN exists at that path so supervisor's auto-resume picks it up.
    if [[ -n "$RESUME_FROM" && "$RESUME_FROM" != "$OUT_BIN" ]]; then
        cp -f "$RESUME_FROM" "$OUT_BIN"
    fi

    # Launch the supervisor; it handles all retries, status, and resume.
    BIN="$BIN" OUT="$OUT" \
    WIDTH="$WIDTH" HEIGHT="$HEIGHT" SAMPLES="$SAMPLES" \
    SAMPLES_PER_THREAD="$SAMPLES_PER_THREAD" LAUNCHES_PER_ROUND="$LAUNCHES_PER_ROUND" \
    CP_EVERY="$CP_EVERY" \
    TRIM_R="$TRIM_R" TRIM_G="$TRIM_G" TRIM_B="$TRIM_B" \
    WALLCLOCK_HARD_CAP="$WALLCLOCK_HARD_CAP" \
    IMAP_FLAGS_STR="$IMAP_FLAGS_STR" SUPPORTS_RAW="$SUPPORTS_RAW" \
    MAX_RETRIES="${MAX_RETRIES:-5}" \
    nohup ./_supervise.sh > "${OUT%.png}.supervisor.stdout.log" 2>&1 &
    RENDER_PID=$!
    disown $RENDER_PID

    # Optional Python HTTP server (default ON; disable via HTTP_SERVER=0)
    HTTP_SERVER="${HTTP_SERVER:-1}"
    HTTP_PORT="${HTTP_PORT:-8080}"
    if [[ "$HTTP_SERVER" == "1" ]] && command -v python >/dev/null 2>&1; then
        # Bind to localhost only (security; not internet-reachable)
        nohup python -m http.server "$HTTP_PORT" --bind 127.0.0.1 \
            > "${OUT%.png}.httpserver.log" 2>&1 &
        HTTP_PID=$!
        disown $HTTP_PID
        echo ""
        echo "=== Supervisor PID: $RENDER_PID"
        echo "=== HTTP server PID: $HTTP_PID (port $HTTP_PORT)"
        echo "=== Open in Chrome: http://localhost:$HTTP_PORT/$(basename "${OUT%.png}").status.html"
        echo "=== Stop supervisor: touch ${OUT%.png}.stop  (or  kill -TERM $RENDER_PID)"
    else
        echo ""
        echo "=== Supervisor PID: $RENDER_PID"
        echo "=== Status HTML (file://): $(realpath "${OUT%.png}.status.html" 2>/dev/null || echo "${OUT%.png}.status.html")"
        echo "=== Stop supervisor: touch ${OUT%.png}.stop  (or  kill -TERM $RENDER_PID)"
    fi
else
    # Single-shot mode (legacy; used if WATCHDOG=0 or _supervise.sh missing)
    RAW_FLAGS=()
    if [[ "$SUPPORTS_RAW" == "1" ]]; then
        RAW_FLAGS+=(--output-raw "$OUT_BIN")
        [[ -n "$RESUME_FROM" ]] && RAW_FLAGS+=(--resume-from "$RESUME_FROM")
    fi

    nohup timeout --signal=SIGTERM --kill-after=300 "$WALLCLOCK_HARD_CAP" \
    "$BIN" \
        --width "$WIDTH" \
        --height "$HEIGHT" \
        --samples "$SAMPLES" \
        --devices 1 \
        "${IMAP_FLAGS[@]}" \
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
        "${RAW_FLAGS[@]}" \
        --output "$OUT" \
        "$@" > "${OUT%.png}.stderr.log" 2>&1 &

    RENDER_PID=$!
    disown $RENDER_PID
    echo ""
    echo "=== Render PID: $RENDER_PID  (single-shot mode; WATCHDOG=0)"
    echo "=== Tail log: tail -f ${OUT%.png}.stderr.log"
fi
[[ "$SUPPORTS_RAW" == "1" ]] && echo "=== Resume next time will be auto-detected from $OUT_BIN"
