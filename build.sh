#!/bin/bash
# Linux build for cloud GPU instances. Produces a fat binary covering the
# common modern NVIDIA architectures, so the same build works on Ampere
# (A100, 3090), Ada (4090, 4070 Ti SUPER) and Hopper (H100, H200).
#
# Requires: CUDA toolkit (12.x+), gcc with C++17 support.
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
echo "=== Compiling buddhabrot (fat binary: sm_80, sm_86, sm_89, sm_90)..."

nvcc -O3 -std=c++17 \
     -gencode arch=compute_80,code=sm_80 \
     -gencode arch=compute_86,code=sm_86 \
     -gencode arch=compute_89,code=sm_89 \
     -gencode arch=compute_90,code=sm_90 \
     -Xcompiler "-O3 -Wno-deprecated-gpu-targets" \
     -o buddhabrot \
     src/main.cu src/lodepng.cpp

echo "=== Build OK -> ./buddhabrot"
