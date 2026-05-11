#!/bin/bash
# Linux build for cloud GPU instances. Produces a fat binary covering all
# modern NVIDIA architectures: Ampere (A100, 3090), Ada (4090, 4070 Ti SUPER),
# Hopper (H100, H200), and Blackwell (5090, B100, B200, GB200).
#
# Requires: CUDA toolkit 12.6+ (for sm_120 / Blackwell), gcc with C++17 support.
# Note: sm_120 needs CUDA 12.6+; older toolkits will fail. If on older CUDA,
# remove the sm_120 line and rebuild.
#
# Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v nvcc >/dev/null; then
    echo "nvcc not found in PATH. Source the CUDA env first, e.g.:"
    echo "  export PATH=/usr/local/cuda/bin:\$PATH"
    exit 1
fi

echo "=== nvcc: $(nvcc --version | grep release)"

# CUDA version detection. sm_120 (Blackwell / 5090) requires CUDA 12.6+;
# Hyperbolic.xyz ships CUDA 12.2 in the default Ubuntu image which would
# fail with 'unsupported gpu architecture compute_120'. Detect and drop
# sm_120 from the gencode list when nvcc is too old. sm_80/86/89/90 cover
# Ampere/Ada/Hopper which is everything pre-Blackwell.
NVCC_VER=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1)
NVCC_MAJOR=$(echo "$NVCC_VER" | cut -d. -f1)
NVCC_MINOR=$(echo "$NVCC_VER" | cut -d. -f2)
SM120_FLAG=""
if [ "$NVCC_MAJOR" -gt 12 ] || { [ "$NVCC_MAJOR" -eq 12 ] && [ "$NVCC_MINOR" -ge 6 ]; }; then
    SM120_FLAG="-gencode arch=compute_120,code=sm_120"
    echo "=== CUDA $NVCC_VER >= 12.6: including sm_120 (Blackwell / 5090) in fat binary"
else
    echo "=== CUDA $NVCC_VER < 12.6: SKIPPING sm_120 (Blackwell). Build covers sm_80/86/89/90."
    echo "    (If you need 5090 support, upgrade CUDA toolkit to 12.6+; OR upgrade driver to 570+"
    echo "     which usually pulls a newer CUDA. For H100/H200/4090/3090 this is fine as-is.)"
fi

echo "=== Compiling buddhabrot (fat binary)..."
nvcc -O3 -std=c++17 \
     -gencode arch=compute_80,code=sm_80 \
     -gencode arch=compute_86,code=sm_86 \
     -gencode arch=compute_89,code=sm_89 \
     -gencode arch=compute_90,code=sm_90 \
     $SM120_FLAG \
     -Xcompiler "-O3 -Wno-deprecated-gpu-targets" \
     -o buddhabrot \
     src/main.cu src/lodepng.cpp

echo "=== Build OK -> ./buddhabrot"
