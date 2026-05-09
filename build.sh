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
echo "=== Compiling buddhabrot (fat binary: sm_80, sm_86, sm_89, sm_90, sm_120)..."

nvcc -O3 -std=c++17 \
     -gencode arch=compute_80,code=sm_80 \
     -gencode arch=compute_86,code=sm_86 \
     -gencode arch=compute_89,code=sm_89 \
     -gencode arch=compute_90,code=sm_90 \
     -gencode arch=compute_120,code=sm_120 \
     -Xcompiler "-O3 -Wno-deprecated-gpu-targets" \
     -o buddhabrot \
     src/main.cu src/lodepng.cpp

echo "=== Build OK -> ./buddhabrot"
