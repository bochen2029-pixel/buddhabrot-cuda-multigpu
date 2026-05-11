#!/usr/bin/env bash
# One-shot bootstrap for a fresh Hyperbolic.xyz instance.
#
# Usage on the cloud instance (after ssh in):
#   curl -sSL "https://raw.githubusercontent.com/bochen2079/buddhabrot-cuda/main/cuda-render-16k/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash
#
# The "?ts=$(date +%s)" suffix is a cache-bust: GitHub Raw URLs are fronted
# by Fastly with 5-min per-edge TTL. Within 5 min of a push, edges may
# serve the previous version (K0 lesson §2.7). The timestamp query string
# is part of Fastly's cache key but ignored by GitHub, forcing an origin
# fetch. Safe to omit if you know the bootstrap hasn't changed recently.
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
# Renderer files are at the repo root, not in a subdirectory.
SUBDIR=""

echo "============================================================"
echo "Hyperbolic.xyz bootstrap — Buddhabrot CUDA renderer"
echo "============================================================"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)"
echo "User: $(whoami)"

# Privilege detection. RunPod gives root by default; Hyperbolic/Lambda/Vast
# typically give an unprivileged user (often `ubuntu`) with passwordless sudo
# but no direct root. Cloud-init may have no sudo at all in some setups.
# Detect and set APT_PREFIX + PIP_USER_FLAG so install commands work in all
# three regimes without rolling dice on default behavior.
if [ "$(id -u)" = "0" ]; then
    APT_PREFIX=""
    PIP_USER_FLAG=""
    PRIVILEGE="root"
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    APT_PREFIX="sudo "
    PIP_USER_FLAG="--user"
    PRIVILEGE="sudo (passwordless)"
elif command -v sudo >/dev/null; then
    APT_PREFIX="sudo "
    PIP_USER_FLAG="--user"
    PRIVILEGE="sudo (interactive; may prompt for password)"
else
    APT_PREFIX=""
    PIP_USER_FLAG="--user"
    PRIVILEGE="unprivileged; no sudo — apt-get steps will be SKIPPED, manual install may be needed"
fi
echo "Privilege: $(whoami) (uid=$(id -u)); apt prefix='${APT_PREFIX:-<none>}'; pip flag='${PIP_USER_FLAG:-<none>}' — $PRIVILEGE"
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
    # K0 §2.8: chmod (run later in step 6) marks files as modified under
    # core.filemode=true (Linux default). Next `git pull --ff-only` then
    # refuses to merge. Set filemode=false BEFORE pulling so the pull
    # tolerates any prior chmod-dirty state. `|| true` ensures that if
    # `git config` itself fails for any reason, we proceed with the
    # original behavior — worst case is the same `local changes would be
    # overwritten` error you'd hit without this guard.
    git config core.filemode false 2>/dev/null || true
    # Defensive: if a prior chmod already dirtied the tree, attempt the
    # ff-only pull, then fall back to fetch+reset if it fails. Pod is
    # rented hardware — no local state to preserve.
    if ! git pull --ff-only 2>&1; then
        echo "[3/7] ff-only pull failed (likely stale chmod state); hard-resetting..."
        git fetch origin && git reset --hard origin/HEAD 2>/dev/null || \
            git reset --hard origin/master 2>/dev/null || \
            git reset --hard origin/main
    fi
else
    git clone "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
    git config core.filemode false 2>/dev/null || true
fi
if [ -n "$SUBDIR" ] && [ -d "$SUBDIR" ]; then
    cd "$SUBDIR"
fi
echo "[3/7] In: $(pwd)"

# 4. Install Python deps for HF sync (background).
# pip flag varies by privilege: root installs system-wide, non-root needs --user.
# K0 §2.4: Ubuntu 22.04+ marks system Python externally-managed (PEP 668);
# pip refuses to install without --break-system-packages. Probe whether pip
# supports the flag (pip 23.0+) and add it conditionally. If install fails
# WITH the flag, fall back to plain --user (original behavior). Triple-
# fallback chain ends at the pre-K0-advice install command, so we can't be
# worse off than before this hardening.
echo
echo "[4/7] Installing huggingface_hub (Python, pip $PIP_USER_FLAG)..."
BREAK_FLAG=""
if pip3 install --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    BREAK_FLAG="--break-system-packages"
elif python3 -m pip install --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    BREAK_FLAG="--break-system-packages"
fi
[ -n "$BREAK_FLAG" ] && echo "  pip supports --break-system-packages; using it (PEP 668 defense)"
if command -v pip3 >/dev/null; then
    pip3 install -q -U $PIP_USER_FLAG $BREAK_FLAG huggingface_hub \
        || python3 -m pip install -q -U $PIP_USER_FLAG $BREAK_FLAG huggingface_hub \
        || pip3 install -q -U $PIP_USER_FLAG huggingface_hub \
        || python3 -m pip install -q -U $PIP_USER_FLAG huggingface_hub
else
    python3 -m pip install -q -U $PIP_USER_FLAG $BREAK_FLAG huggingface_hub \
        || python3 -m pip install -q -U $PIP_USER_FLAG huggingface_hub
fi
# When pip installs with --user, ~/.local/bin may not be in PATH yet.
if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
    echo "  Added \$HOME/.local/bin to PATH (pip --user install location)"
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
if [ -n "$SUBDIR" ]; then
    echo "  cd $REPO_DIR/$SUBDIR"
else
    echo "  cd $REPO_DIR"
fi
echo "  export HF_TOKEN=<your_token>            # optional, for background sync"
echo "  ./run-cloud-hyperbolic.sh"
echo
echo "Or with parameter overrides:"
echo "  TARGET_SAMPLES=2000000000000 ./run-cloud-hyperbolic.sh"
echo "  WALLCLOCK_HARD_CAP=5400 ./run-cloud-hyperbolic.sh"
echo "============================================================"
