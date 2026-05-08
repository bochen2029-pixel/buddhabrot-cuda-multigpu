#!/bin/bash
# Cloud (multi-GPU) render — defaults sized for an 8× H200 / 2-hour run.
# Total samples 25 T → ~5× cleaner than the local 1024 B render.
#
# Override anything via flags, e.g.:
#   ./run-cloud.sh --output myrender.png --samples 50000000000000
#
# Note on samples_per_thread: at 25 T total samples we have ~24 G thread-launches
# even at samples_per_thread=1024. uint64 seed mixing in main.cu is what keeps
# RNG streams independent at this scale (the WGSL/u32 path would correlate).

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -x ./buddhabrot ]]; then
    echo "buddhabrot binary not found. Run ./build.sh first."
    exit 1
fi

OUT="${OUT:-buddhabrot_cloud.png}"

./buddhabrot \
    --width 16384 \
    --height 12288 \
    --samples 25000000000000 \
    --iter-r 2000 \
    --iter-g 200 \
    --iter-b 20 \
    --view-center-x -0.5935417456742 \
    --view-center-y  0.04166264380232 \
    --zoom 0.5 \
    --rotation-deg 90 \
    --output "$OUT" \
    "$@"

echo ""
echo "=== Render complete: $OUT"
echo "=== Next step: post-process color trim with src/colorgrade.py to match the 4K_blue tone."
echo "    Use the channel maxima printed above and the formula:"
echo "      trim_r = 49332 / R_max"
echo "      trim_g = 34610 / G_max"
echo "      trim_b = 20086 / B_max"
echo "    Then run:"
echo "      python src/colorgrade.py $OUT ${OUT%.png}_blue.png \\"
echo "          --trim-r <r> --trim-g <g> --trim-b <b>"
