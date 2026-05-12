#!/usr/bin/env bash
# Fast-tile render on H100 with the FULL corrected pipeline (all three fixes):
#
# 1. Per-tile classification (--classify-threshold): dim tiles use canonical
#    IMap (no bin-guided concentration), preventing tonal-island artifacts at
#    tile boundaries in low-zoom pyramid views.
#
# 2. Weight floor in bin-guided IMap kernel (--guide-min-weight): even bright-
#    classified tiles still give baseline sampling to all viewport regions,
#    smoothing tile-tile tonal discontinuities.
#
# 3. Full apron-crossfade in stitching pipeline:
#       stitch_tiles.py --keep-apron  (retain apron pixels)
#       compose_blended.py            (linear-alpha crossfade at apron overlap)
#       build_dz_pyramid.py --composite-tif  (single blended composite → DZI)
#
# The previous run-fast-tiles-h100.sh skipped compose_blended.py and trimmed
# aprons in stitch (= hard cuts at every tile junction). This launcher does
# the full pipeline.
#
# Usage (after rebuilding buddhabrot binary with the new kernel):
#   export HF_TOKEN=$(cat ~/.hf_token)
#   export HF_BUCKET=bochen2079/buddhabrot
#   bash run-fast-tiles-blended-h100.sh
#
# Env overrides:
#   GRID=16x16 RESOLUTION=4096x3072 SECONDS_PER_TILE=60 GUIDE=guide_4k.gbin
#   CLASSIFY_THRESHOLD=2000 GUIDE_MIN_WEIGHT=8 OUTPUT_DIR=tiles_v2_h100

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v nvcc >/dev/null 2>&1; then
    if [ -d /usr/local/cuda/bin ]; then export PATH=/usr/local/cuda/bin:$PATH; fi
fi

echo "============================================================"
echo "Fast-tile render v2 (classified + weight-floored + blended)"
echo "============================================================"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ ! -x ./buddhabrot ]; then
    echo "[build] compiling buddhabrot (with new guide-min-weight kernel)..."
    ./build.sh
fi

# Configuration
export GRID="${GRID:-16x16}"
export RESOLUTION="${RESOLUTION:-4096x3072}"
export SECONDS_PER_TILE="${SECONDS_PER_TILE:-60}"
export THROUGHPUT_EST="${THROUGHPUT_EST:-12}"
export GUIDE="${GUIDE:-guide_4k.gbin}"
export OUTPUT_DIR="${OUTPUT_DIR:-tiles_v2_h100}"
export APRON="${APRON:-64}"
export TRIM_R="${TRIM_R:-0.137}"
export TRIM_G="${TRIM_G:-0.098}"
export TRIM_B="${TRIM_B:-0.056}"

# v2 corrections
export CLASSIFY_THRESHOLD="${CLASSIFY_THRESHOLD:-2000}"
export GUIDE_MIN_WEIGHT="${GUIDE_MIN_WEIGHT:-8}"

if [ ! -f "$GUIDE" ]; then
    echo "ERROR: guide file '$GUIDE' missing. Generate via:"
    echo "  python3 tools/downsample_bin.py <source.bin> $GUIDE --factor 8"
    exit 1
fi

# HF auth
if [ -z "${HF_TOKEN:-}" ] && [ -f "$HOME/.hf_token" ]; then
    HF_TOKEN=$(cat "$HOME/.hf_token"); export HF_TOKEN
fi
if [ -z "${HF_BUCKET:-}" ]; then export HF_BUCKET="bochen2079/buddhabrot"; fi
hf auth login --token "$HF_TOKEN" --add-to-git-credential 2>&1 | tail -1
echo "[hf] bucket: $HF_BUCKET"

# Print plan
N_TILES=$(echo "$GRID" | awk -Fx '{print $1*$2}')
echo
echo "[config] grid:        $GRID  ($N_TILES tiles)"
echo "[config] resolution:  $RESOLUTION per tile"
echo "[config] budget:      ${SECONDS_PER_TILE}s @ ${THROUGHPUT_EST} M/s = $(( SECONDS_PER_TILE * THROUGHPUT_EST ))M samples per tile"
echo "[config] guide:       $GUIDE"
echo "[config] CLASSIFY threshold: $CLASSIFY_THRESHOLD (dim tiles use canonical IMap)"
echo "[config] GUIDE_MIN_WEIGHT:   $GUIDE_MIN_WEIGHT (kernel floor for bin-guided weights)"
echo "[config] apron:       $APRON px (each side; retained through compose_blended)"
echo "[config] output:      $OUTPUT_DIR"
echo

# ============================================================================
# Step 1: render the tiles (with classification + weight floor)
# ============================================================================
echo "============================================================"
echo "STEP 1/4: render $N_TILES tiles"
echo "============================================================"
mkdir -p "$OUTPUT_DIR"
python3 tools/render_fast_tiles.py \
    --grid "$GRID" \
    --resolution "$RESOLUTION" \
    --seconds-per-tile "$SECONDS_PER_TILE" \
    --throughput-est "$THROUGHPUT_EST" \
    --guide-bin "$GUIDE" \
    --classify-threshold "$CLASSIFY_THRESHOLD" \
    --guide-min-weight "$GUIDE_MIN_WEIGHT" \
    --hf-bucket "$HF_BUCKET" \
    --output-dir "$OUTPUT_DIR" \
    --apron "$APRON" \
    --trim-r "$TRIM_R" --trim-g "$TRIM_G" --trim-b "$TRIM_B"

# ============================================================================
# Step 2: stitch tiles into TIFFs WITH apron retained (for compose_blended)
# ============================================================================
echo
echo "============================================================"
echo "STEP 2/4: stitch tiles into per-tile TIFFs (--keep-apron)"
echo "============================================================"
mkdir -p "$OUTPUT_DIR/stitched"
python3 tools/stitch_tiles.py \
    --tile-dir "$OUTPUT_DIR" \
    --output-dir "$OUTPUT_DIR/stitched" \
    --trim-r "$TRIM_R" --trim-g "$TRIM_G" --trim-b "$TRIM_B" \
    --keep-apron

# ============================================================================
# Step 3: compose_blended — single composite TIFF with crossfade
# ============================================================================
echo
echo "============================================================"
echo "STEP 3/4: compose_blended (linear-alpha crossfade at tile junctions)"
echo "============================================================"
python3 tools/compose_blended.py \
    --stitched-dir "$OUTPUT_DIR/stitched" \
    --output "$OUTPUT_DIR/composite.tif"

# ============================================================================
# Step 4: build DZI pyramid from the single blended composite
# ============================================================================
echo
echo "============================================================"
echo "STEP 4/4: build DZI pyramid for OpenSeadragon"
echo "============================================================"
python3 tools/build_dz_pyramid.py \
    --composite-tif "$OUTPUT_DIR/composite.tif" \
    --output "$OUTPUT_DIR/viewer"

# ============================================================================
# Tar + upload
# ============================================================================
echo
echo "============================================================"
echo "STEP 5/5 (bonus): tar viewer + upload to HF"
echo "============================================================"
tar cf "$OUTPUT_DIR/viewer.tar" -C "$OUTPUT_DIR" viewer.dzi viewer_files/
echo "tarball: $(ls -lh $OUTPUT_DIR/viewer.tar | awk '{print $5}')"

hf sync . hf://buckets/$HF_BUCKET/ --include "$OUTPUT_DIR/viewer.tar"

echo
echo "============================================================"
echo "DONE."
echo "  Tarball:    hf://buckets/$HF_BUCKET/$OUTPUT_DIR/viewer.tar"
echo "  Composite:  $OUTPUT_DIR/composite.tif  (16-bit TIFF, blended)"
echo "  Per-tile bins: $OUTPUT_DIR/r*c*.bin (recolorable forever)"
echo "============================================================"
