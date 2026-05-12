#!/usr/bin/env bash
# Generate the complete guide hierarchy from the highest-quality available
# source .bin on the pod. Produces guide_4k/8k/16k/32k.gbin and uploads all
# four to HF as a reusable "render cheat" artifact set.
#
# These guides power future tile-pyramid renders: each tile uses one of these
# as its bin-guide during view-IMap construction. Resolution choice:
#
#   guide_4k  → smallest, fastest, ~24 MB    → use for 32K-64K stitched output
#   guide_8k  → balanced, ~96 MB              → use for 64K-128K stitched
#   guide_16k → fine, ~384 MB                 → use for 128K-256K stitched
#   guide_32k → finest, ~1.5 GB               → use for 256K-512K+ stitched
#
# All four together = ~2 GB, downloadable forever as the render-cheat asset.
#
# Usage on the pod:
#   bash generate_guide_hierarchy.sh
#
# Override source bin via env:
#   SOURCE_BIN=path/to/cp.bin bash generate_guide_hierarchy.sh

set -euo pipefail
cd "$(dirname "$0")"

echo "============================================================"
echo "Guide hierarchy generator (4k/8k/16k/32k)"
echo "============================================================"

# Find the highest-cp .bin on disk if not specified
if [ -z "${SOURCE_BIN:-}" ]; then
    SOURCE_BIN=$(ls -1 buddhabrot_cloud_32k_h100_24h.cp*.bin 2>/dev/null | sort -V | tail -1)
    if [ -z "$SOURCE_BIN" ]; then
        echo "ERROR: no buddhabrot_cloud_32k_h100_24h.cp*.bin files on disk."
        echo "       Set SOURCE_BIN=path/to/your/source.bin and re-run."
        exit 1
    fi
fi

if [ ! -f "$SOURCE_BIN" ]; then
    echo "ERROR: source not found: $SOURCE_BIN"
    exit 1
fi

SOURCE_SIZE=$(stat -c %s "$SOURCE_BIN" 2>/dev/null || stat -f %z "$SOURCE_BIN")
echo "[source] $SOURCE_BIN  ($(( SOURCE_SIZE / 1073741824 )) GB)"

# HF auth
if [ -z "${HF_TOKEN:-}" ] && [ -f "$HOME/.hf_token" ]; then
    HF_TOKEN=$(cat "$HOME/.hf_token"); export HF_TOKEN
fi
if [ -z "${HF_BUCKET:-}" ]; then export HF_BUCKET="bochen2079/buddhabrot"; fi
hf auth login --token "$HF_TOKEN" --add-to-git-credential 2>&1 | tail -1 || true

# ============================================================================
# Generate all four resolutions
# ============================================================================
for FACTOR in 8 4 2 1; do
    case $FACTOR in
        8) NAME=guide_4k.gbin ;;
        4) NAME=guide_8k.gbin ;;
        2) NAME=guide_16k.gbin ;;
        1) NAME=guide_32k.gbin ;;
    esac

    if [ -f "$NAME" ]; then
        EXISTING_SIZE=$(stat -c %s "$NAME" 2>/dev/null || stat -f %z "$NAME")
        echo
        echo "[$NAME] already exists ($(( EXISTING_SIZE / 1048576 )) MB), skipping generation"
        continue
    fi

    echo
    echo "============================================================"
    echo "Generating $NAME (factor $FACTOR)"
    echo "============================================================"
    python3 tools/downsample_bin.py "$SOURCE_BIN" "$NAME" --factor "$FACTOR"
done

# ============================================================================
# Verify + summarize
# ============================================================================
echo
echo "============================================================"
echo "Guide hierarchy complete"
echo "============================================================"
ls -lh guide_*.gbin

# ============================================================================
# Upload all four to HF in artifacts_v1/ namespace
# ============================================================================
echo
echo "============================================================"
echo "Uploading to hf://buckets/$HF_BUCKET/artifacts_v1/"
echo "============================================================"

# Stage in a temp dir with the artifacts_v1/ prefix so the upload lands in
# the right HF namespace.
mkdir -p artifacts_v1
for f in guide_*.gbin; do
    if [ ! -f "artifacts_v1/$f" ]; then
        # Hard-link instead of copy (same filesystem, near-zero cost).
        ln "$f" "artifacts_v1/$f" 2>/dev/null || cp "$f" "artifacts_v1/$f"
    fi
done

hf sync . hf://buckets/$HF_BUCKET/ --include "artifacts_v1/guide_*.gbin"

echo
echo "============================================================"
echo "DONE. Permanent artifacts on HF:"
echo "  hf://buckets/$HF_BUCKET/artifacts_v1/guide_4k.gbin   ~24 MB"
echo "  hf://buckets/$HF_BUCKET/artifacts_v1/guide_8k.gbin   ~96 MB"
echo "  hf://buckets/$HF_BUCKET/artifacts_v1/guide_16k.gbin  ~384 MB"
echo "  hf://buckets/$HF_BUCKET/artifacts_v1/guide_32k.gbin  ~1.5 GB"
echo
echo "Download any of these via:"
echo "  hf sync hf://buckets/$HF_BUCKET/ . --include 'artifacts_v1/guide_*.gbin'"
echo "============================================================"
