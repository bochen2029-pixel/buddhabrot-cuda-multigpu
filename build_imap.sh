#!/usr/bin/env bash
# Build the Bitterli importance map (imap.bin) for the canonical view.
# Run once on each cloud instance (or transfer the file from local).
#
# Output: ./imap.bin (~4 MB, 1024x1024 uint32 + 40-byte header)
#
# Idempotent: if imap.bin already exists with valid magic, exits 0.

set -euo pipefail
cd "$(dirname "$0")"

IMAP_PATH="${IMAP_PATH:-imap.bin}"
IMAP_SAMPLES="${IMAP_SAMPLES:-1000000000}"   # 1 B uniform pre-pass
IMAP_RES="${IMAP_RES:-1024}"

# Canonical view (must match production render — DO NOT change)
VIEW_CX="${VIEW_CX:--0.5935417456742}"
VIEW_CY="${VIEW_CY:-0.04166264380232}"
ZOOM="${ZOOM:-0.5}"
ROTATION_DEG="${ROTATION_DEG:-90}"
SAMPLE_RADIUS="${SAMPLE_RADIUS:-2.5}"
ITER_R="${ITER_R:-2000}"
ITER_G="${ITER_G:-200}"
ITER_B="${ITER_B:-20}"

# Idempotent skip if already built
if [ -f "$IMAP_PATH" ]; then
    SIZE=$(stat -c%s "$IMAP_PATH" 2>/dev/null || echo 0)
    EXPECTED=$(( IMAP_RES * IMAP_RES * 4 + 40 ))
    if [ "$SIZE" = "$EXPECTED" ]; then
        echo "[imap] $IMAP_PATH already exists ($SIZE bytes); skipping"
        exit 0
    else
        echo "[imap] $IMAP_PATH exists but wrong size ($SIZE != $EXPECTED expected); rebuilding"
    fi
fi

if [ ! -x ./buddhabrot ]; then
    echo "ERROR: ./buddhabrot binary missing. Run build.sh first." >&2
    exit 1
fi

echo "[imap] building $IMAP_PATH at ${IMAP_RES}x${IMAP_RES} from $IMAP_SAMPLES uniform samples"
./buddhabrot \
    --build-imap "$IMAP_PATH" \
    --imap-samples "$IMAP_SAMPLES" \
    --width "$IMAP_RES" --height "$IMAP_RES" \
    --view-center-x "$VIEW_CX" --view-center-y "$VIEW_CY" \
    --zoom "$ZOOM" --rotation-deg "$ROTATION_DEG" \
    --sample-radius "$SAMPLE_RADIUS" \
    --iter-r "$ITER_R" --iter-g "$ITER_G" --iter-b "$ITER_B" \
    --devices 1

echo "[imap] built: $(ls -lh "$IMAP_PATH" | awk '{print $5}')"
