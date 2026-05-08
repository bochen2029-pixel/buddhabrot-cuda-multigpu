#!/usr/bin/env bash
# One-shot bootstrap for a fresh Hyperbolic.xyz instance.
#
# Usage on the cloud instance (after ssh in):
#   curl -sSL https://raw.githubusercontent.com/bochen2079/buddhabrot-cuda/main/cuda-render-16k/bootstrap-hyperbolic.sh | bash
#
# Or if you've already cloned the repo:
#   cd buddhabrot-cuda/cuda-render-16k && ./bootstrap-hyperbolic.sh
#
# Sets HF_TOKEN from env or from $HOME/.hf_token if present. Does NOT auto-launch
# the render — drops you at a ready-to-go shell with `./run-cloud-hyperbolic.sh`
# as the next step.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu.git}"
REPO_DIR="${REPO_DIR:-$HOME/buddhabrot-cuda-multigpu}"
SUBDIR="cuda-render-16k"

echo "============================================================"
echo "Hyperbolic.xyz bootstrap — Buddhabrot CUDA renderer"
echo "============================================================"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)"
echo "User: $(whoami)"
echo

# 1. Verify CUDA presence
echo "[1/7] Verifying CUDA toolkit..."
if ! command -v nvcc >/dev/null; then
    echo "ERROR: nvcc not found. Try: export PATH=/usr/local/cuda/bin:\$PATH" >&2
    if [ -d /usr/local/cuda/bin ]; then
        echo "(Found /usr/local/cuda/bin; sourcing now)"
        export PATH=/usr/local/cuda/bin:$PATH
    else
        exit 1
    fi
fi
nvcc --version | grep release

# 2. Verify GPU presence
echo
echo "[2/7] Detecting GPUs..."
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

# 3. Clone repo
echo
echo "[3/7] Cloning repo..."
if [ -d "$REPO_DIR/.git" ]; then
    echo "Repo already exists at $REPO_DIR; pulling latest"
    cd "$REPO_DIR"
    git pull --ff-only
else
    git clone "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi
cd "$SUBDIR"
echo "[3/7] In: $(pwd)"

# 4. Install Python deps for HF sync (background)
echo
echo "[4/7] Installing huggingface_hub (Python)..."
if command -v pip3 >/dev/null; then
    pip3 install -q -U huggingface_hub
else
    python3 -m pip install -q -U huggingface_hub
fi
# Test hf CLI presence
if command -v hf >/dev/null; then
    HF_VER=$(hf --version 2>&1 | head -1 || echo "unknown")
    echo "[4/7] hf CLI: $HF_VER"
else
    echo "[4/7] WARN: 'hf' command not found after install. Will try huggingface-cli fallback."
fi

# 5. HF auth (if HF_TOKEN env or $HOME/.hf_token file)
echo
echo "[5/7] HuggingFace auth..."
if [ -z "${HF_TOKEN:-}" ] && [ -f "$HOME/.hf_token" ]; then
    HF_TOKEN=$(cat "$HOME/.hf_token")
    export HF_TOKEN
    echo "  Loaded HF_TOKEN from \$HOME/.hf_token"
fi
if [ -n "${HF_TOKEN:-}" ]; then
    if command -v hf >/dev/null; then
        hf auth login --token "$HF_TOKEN" --add-to-git-credential 2>/dev/null \
            && echo "[5/7] hf logged in" \
            || echo "[5/7] hf login failed (may already be logged in)"
    else
        huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential 2>/dev/null \
            && echo "[5/7] huggingface-cli logged in" \
            || echo "[5/7] huggingface-cli login failed"
    fi
else
    echo "[5/7] HF_TOKEN not set; HF sync will be skipped at render time."
    echo "       To enable: export HF_TOKEN=<your_token> before running."
fi

# 6. Build buddhabrot binary
echo
echo "[6/7] Building buddhabrot binary..."
chmod +x build.sh build_imap.sh run-cloud-hyperbolic.sh _supervise-cloud.sh 2>/dev/null || true
./build.sh

# 7. Build IMap (skipped if exists)
echo
echo "[7/7] Building IMap (idempotent)..."
./build_imap.sh

echo
echo "============================================================"
echo "Bootstrap complete."
echo
echo "To launch the production render:"
echo "  cd $REPO_DIR/$SUBDIR"
echo "  export HF_TOKEN=<your_token>            # optional, for background sync"
echo "  ./run-cloud-hyperbolic.sh"
echo
echo "Or with parameter overrides:"
echo "  TARGET_SAMPLES=2000000000000 ./run-cloud-hyperbolic.sh"
echo "  WALLCLOCK_HARD_CAP=5400 ./run-cloud-hyperbolic.sh"
echo "============================================================"
