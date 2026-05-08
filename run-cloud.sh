#!/bin/bash
# Cloud (multi-GPU) render — defaults to Plan C: 32K resolution, 100 T samples,
# ~8 hours on 8× H200. Checkpoint-every-30-rounds means a usable PNG is saved
# roughly every 45 minutes — if the cloud session is killed early, the latest
# .cpNNNN.png is still a valid (if noisier) deliverable.
#
# Override anything via flags or env. Common alternatives:
#   PLAN=B  ./run-cloud.sh            # 32K + 25T, ~2 hr
#   PLAN=A  ./run-cloud.sh            # 16K + 25T, ~2 hr (the original plan)
#
# At any point during the run, the latest .cpNNNN.png in this directory is
# safe to download and use. The renderer auto-bakes the parent's blue tone
# via --target-r/g/b — no separate colorgrade pass needed.

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -x ./buddhabrot ]]; then
    echo "buddhabrot binary not found. Run ./build.sh first."
    exit 1
fi

PLAN="${PLAN:-C}"
case "$PLAN" in
    A)  WIDTH=16384; HEIGHT=12288; SAMPLES=25000000000000;  CP_EVERY=20 ;;  # 16K + 25T,  ~2 hr
    B)  WIDTH=32768; HEIGHT=24576; SAMPLES=25000000000000;  CP_EVERY=20 ;;  # 32K + 25T,  ~2 hr
    C)  WIDTH=32768; HEIGHT=24576; SAMPLES=100000000000000; CP_EVERY=30 ;;  # 32K + 100T, ~8 hr
    *)  echo "Unknown PLAN=$PLAN. Use A, B, or C."; exit 1 ;;
esac

OUT="${OUT:-buddhabrot_cloud_plan${PLAN}.png}"

echo "=== Plan $PLAN: ${WIDTH}x${HEIGHT}, ${SAMPLES} samples, checkpoint every $CP_EVERY rounds"
echo "=== Output base: $OUT"
echo ""

./buddhabrot \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --samples "$SAMPLES" \
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
    --target-r 49332 \
    --target-g 34610 \
    --target-b 20086 \
    --checkpoint-every "$CP_EVERY" \
    --launches-per-round 8 \
    --output "$OUT" \
    "$@"

echo ""
echo "=== Done: $OUT"
echo "=== Checkpoints (in order, in case render was interrupted):"
ls -1tr "${OUT%.png}".cp*.png 2>/dev/null || echo "    (no intermediate checkpoints written — render finished without interruption)"
