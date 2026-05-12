#!/usr/bin/env bash
# Fast-tile render on an H100 (Hyperbolic / RunPod) using bin-guided IMap.
#
# Premise: instead of a slow monolithic 32K/64K render, do an NxN grid of
# fast small tile renders. Each tile uses its own bin-guided view-aware
# IMap, concentrating sample budget on visually-important regions per the
# pre-existing high-quality .bin. Per-tile time ~60s; per-tile per-pixel
# density much higher than monolithic at the same wallclock; output
# scales seamlessly into OpenSeadragon.
#
# Defaults: 16x16 grid, 4K per tile, 60s each. Total stitched = 64K. Total
# time ~4.3 hrs on H100. Each tile auto-uploaded to HF as it lands.
#
# Pre-requisites (must exist on the pod):
#   - buddhabrot binary (rebuilt with bin-guided kernel support: commit 6673e5d+)
#   - guide_4k.gbin (or guide_8k.gbin / guide_16k.gbin) -- produced by
#     tools/downsample_bin.py from a high-quality 32K .bin
#
# Usage (on the H100 pod):
#   export HF_TOKEN=$(cat ~/.hf_token)
#   export HF_BUCKET=bochen2079/buddhabrot
#   bash run-fast-tiles-h100.sh
#
# Override defaults via env vars:
#   GRID=8x8 RESOLUTION=8192x6144 SECONDS_PER_TILE=120 bash run-fast-tiles-h100.sh
#
# Override guide:
#   GUIDE=guide_8k.gbin bash run-fast-tiles-h100.sh

set -euo pipefail
cd "$(dirname "$0")"

# Source CUDA env if nvcc not in PATH
if ! command -v nvcc >/dev/null 2>&1; then
    if [ -d /usr/local/cuda/bin ]; then
        export PATH=/usr/local/cuda/bin:$PATH
    fi
fi

# ---------- Pre-flight ----------
echo "============================================================"
echo "Fast-tile render -- bin-guided IMap, per-tile HF auto-sync"
echo "============================================================"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)"
echo "User: $(whoami)"

if ! command -v nvidia-smi >/dev/null; then
    echo "ERROR: nvidia-smi not found"; exit 1
fi
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
echo "[gpu] $GPU_NAME -- $GPU_MEM MiB"

if [ ! -x ./buddhabrot ]; then
    echo "[build] buddhabrot binary missing -- compiling..."
    ./build.sh
fi

# ---------- Configuration ----------
export GRID="${GRID:-16x16}"
export RESOLUTION="${RESOLUTION:-4096x3072}"
export SECONDS_PER_TILE="${SECONDS_PER_TILE:-60}"
export THROUGHPUT_EST="${THROUGHPUT_EST:-12}"     # H100 PCIe IS rate, M/s
export GUIDE="${GUIDE:-guide_4k.gbin}"
export OUTPUT_DIR="${OUTPUT_DIR:-tiles_fast_h100}"
export APRON="${APRON:-64}"

# Trim values for the per-tile renders. Used as a starting guess; final
# tonemap during stitching can override. These match the cp8320 32K
# density-correct trims from quality_report.
export TRIM_R="${TRIM_R:-0.137}"
export TRIM_G="${TRIM_G:-0.098}"
export TRIM_B="${TRIM_B:-0.056}"

# Verify guide exists
if [ ! -f "$GUIDE" ]; then
    echo "ERROR: guide file '$GUIDE' not found."
    echo "  Generate it first via: python3 tools/downsample_bin.py <source.bin> $GUIDE --factor 8"
    exit 1
fi
GUIDE_SIZE=$(stat -c %s "$GUIDE" 2>/dev/null || stat -f %z "$GUIDE")
echo "[guide] $GUIDE  ($(( GUIDE_SIZE / 1048576 )) MB)"

# HF auth
if [ -z "${HF_TOKEN:-}" ] && [ -f "$HOME/.hf_token" ]; then
    HF_TOKEN=$(cat "$HOME/.hf_token"); export HF_TOKEN
fi
if [ -z "${HF_BUCKET:-}" ]; then
    echo "[hf] HF_BUCKET not set -- defaulting to bochen2079/buddhabrot"
    export HF_BUCKET="bochen2079/buddhabrot"
fi
if [ -n "${HF_TOKEN:-}" ]; then
    hf auth login --token "$HF_TOKEN" --add-to-git-credential 2>&1 | tail -1
    echo "[hf] bucket: $HF_BUCKET"
    echo "[hf] tiles will sync to hf://buckets/$HF_BUCKET/$OUTPUT_DIR/ as they land"
else
    echo "WARN: HF_TOKEN not set; per-tile HF sync will fail."
    echo "      Set HF_TOKEN env or create ~/.hf_token first."
    exit 1
fi

# ---------- Summary ----------
echo
echo "[config] grid:        $GRID  (= $(echo "$GRID" | awk -Fx '{print $1*$2}') tiles)"
echo "[config] resolution:  $RESOLUTION per tile"
echo "[config] budget:      ${SECONDS_PER_TILE}s per tile @ ${THROUGHPUT_EST} M/s = $(( SECONDS_PER_TILE * THROUGHPUT_EST ))M samples per tile"
echo "[config] guide:       $GUIDE"
echo "[config] apron:       $APRON px (each side)"
echo "[config] trims:       R=$TRIM_R G=$TRIM_G B=$TRIM_B"
echo "[config] output dir:  $OUTPUT_DIR"

N_TILES=$(echo "$GRID" | awk -Fx '{print $1*$2}')
TOTAL_MIN=$(( N_TILES * (SECONDS_PER_TILE + 10) / 60 ))
TILE_W=$(echo "$RESOLUTION" | awk -Fx '{print $1}')
TILE_H=$(echo "$RESOLUTION" | awk -Fx '{print $2}')
COLS=$(echo "$GRID" | awk -Fx '{print $1}')
ROWS=$(echo "$GRID" | awk -Fx '{print $2}')
STITCH_W=$(( COLS * TILE_W ))
STITCH_H=$(( ROWS * TILE_H ))
echo "[config] stitched:    ${STITCH_W}x${STITCH_H}"
echo "[config] est total:   ${TOTAL_MIN} min"
echo

# ---------- Launch ----------
mkdir -p "$OUTPUT_DIR"
python3 tools/render_fast_tiles.py \
    --grid "$GRID" \
    --resolution "$RESOLUTION" \
    --seconds-per-tile "$SECONDS_PER_TILE" \
    --throughput-est "$THROUGHPUT_EST" \
    --guide-bin "$GUIDE" \
    --hf-bucket "$HF_BUCKET" \
    --output-dir "$OUTPUT_DIR" \
    --apron "$APRON" \
    --trim-r "$TRIM_R" --trim-g "$TRIM_G" --trim-b "$TRIM_B"

echo
echo "============================================================"
echo "Done. Final stitched render available via:"
echo "  python3 tools/stitch_tiles.py --tile-dir $OUTPUT_DIR \\"
echo "      --output-dir $OUTPUT_DIR/stitched/ \\"
echo "      --trim-r $TRIM_R --trim-g $TRIM_G --trim-b $TRIM_B"
echo "  python3 tools/build_dz_pyramid.py --stitched-dir $OUTPUT_DIR/stitched/ \\"
echo "      --output viewer_fast"
echo "============================================================"
