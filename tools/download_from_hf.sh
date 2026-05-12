#!/usr/bin/env bash
# Reliable downloader for large files from HuggingFace Buckets (Linux/Mac).
#
# Mirrors the Windows download_from_hf.ps1 logic. Uses `hf sync` — the ONLY
# verified-reliable path for multi-gigabyte files. wget/curl on the resolve
# URL endpoint hits the same CDN reset issues that fail on browser.
#
# Usage:
#   ./download_from_hf.sh <bucket> <pattern> [local_dir] [token]
#
# Examples:
#   ./download_from_hf.sh bochen2079/buddhabrot "*.cp8320.bin"
#   ./download_from_hf.sh bochen2079/buddhabrot64k "*.cp4130.*" ./downloads
#   ./download_from_hf.sh bochen2079/buddhabrot "*.bin" /tank/renders hf_TOKENXYZ

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <bucket> <pattern> [local_dir] [token]"
    echo ""
    echo "  bucket:     bochen2079/buddhabrot or similar"
    echo "  pattern:    *.cp8320.bin or *.cp4130.* etc"
    echo "  local_dir:  destination (default: current dir)"
    echo "  token:      hf_xxx (default: use cached login)"
    exit 1
fi

BUCKET="$1"
PATTERN="$2"
LOCAL_DIR="${3:-.}"
TOKEN="${4:-}"

echo "==========================================="
echo "HuggingFace Bucket downloader"
echo "==========================================="
echo "Bucket:    hf://buckets/$BUCKET/"
echo "Pattern:   $PATTERN"
echo "Local dir: $LOCAL_DIR"
echo ""

# [1/4] verify hf CLI
if ! command -v hf >/dev/null 2>&1; then
    echo "[1/4] hf CLI not found; installing..."
    if command -v pip3 >/dev/null; then
        pip3 install -U --break-system-packages huggingface_hub 2>/dev/null \
            || pip3 install -U huggingface_hub 2>/dev/null \
            || pip3 install -U --user huggingface_hub
    else
        python3 -m pip install -U --user huggingface_hub
    fi
    if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi
echo "[1/4] hf: $(command -v hf)"

# [2/4] auth
if [ -n "$TOKEN" ]; then
    echo "[2/4] logging in..."
    hf auth login --token "$TOKEN"
else
    echo "[2/4] checking existing auth..."
    if ! hf auth whoami >/dev/null 2>&1; then
        echo "ERROR: not logged in. Pass a token as argv[4], or run:"
        echo "  hf auth login --token YOUR_HF_TOKEN"
        exit 1
    fi
    echo "  auth OK: $(hf auth whoami | head -1)"
fi

# [3/4] local dir
mkdir -p "$LOCAL_DIR"
ABS_LOCAL=$(realpath "$LOCAL_DIR")
echo "[3/4] local dir: $ABS_LOCAL"

# [4/4] download
echo ""
echo "[4/4] downloading..."
echo "  Command: hf sync hf://buckets/$BUCKET/ $LOCAL_DIR --include \"$PATTERN\""
echo ""

START=$(date +%s)
hf sync "hf://buckets/$BUCKET/" "$LOCAL_DIR" --include "$PATTERN"
EXIT=$?
ELAPSED=$(( $(date +%s) - START ))

echo ""
if [ "$EXIT" = "0" ]; then
    echo "==========================================="
    echo "Download complete in $(( ELAPSED / 60 )) min $(( ELAPSED % 60 )) sec"
    echo "==========================================="
    echo ""
    echo "Files matching '$PATTERN':"
    ls -lh "$LOCAL_DIR"/$PATTERN 2>/dev/null || echo "  (no matches found)"
else
    echo "==========================================="
    echo "Download FAILED (exit code $EXIT)"
    echo "==========================================="
    echo ""
    echo "Verify bucket contents:"
    echo "  hf buckets ls hf://buckets/$BUCKET/"
    exit "$EXIT"
fi
