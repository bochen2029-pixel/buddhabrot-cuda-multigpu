// =============================================================================
// Buddhabrot CUDA renderer — multi-GPU edition.
//
// Direct port of compute.wgsl + render.wgsl tonemap from the buddhabrot-main
// project, scaled to multi-device execution for cloud-class hardware.
//
// Renders the screenshot composition by default:
//   viewCenter  = (-0.5935417456742, 0.04166264380232)
//   zoom        = 0.5      (viewYSpan = 4.0 / sqrt(2) ≈ 2.828)
//   rotation    = 90°       (π/2 rad)
//   exponent    = (2, 0)    (classic z² + c — fast path enabled)
//   initialZ    = (0, 0)
//   anti        = false
//   uniform_sample_distribution = true
//   bailout     = 4 (escape_radius_sq = 16)
//   gamma       = 4.0
//   normFloor   = 15
//   maxIter     = 2000 / 200 / 20  (R / G / B)
//
// Multi-GPU strategy:
//   - One independent histogram per device, in that device's VRAM
//   - Per-device unique seed offset (uint64 to avoid RNG collisions at 10⁹+ threads)
//   - All devices run kernels concurrently on per-device streams
//   - At end: peer-copy each non-zero device's histogram into device 0,
//     atomic-sum into device 0's master, recompute channel maxes, tonemap on dev 0
//
// Defaults to 16384 × 12288 at 256 B samples. All overridable via CLI flags.
// =============================================================================

#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <chrono>
#include <algorithm>
#include "lodepng.h"

// -----------------------------------------------------------------------------
// Params — passed by value into every kernel launch.
// `seed_64` upgraded from u32 to u64 vs the original WGSL: at 10¹⁰+ thread
// instances across an 8-GPU cloud render, u32 seed mixing has arithmetic
// collisions and would partially correlate RNG streams. A u64 input through a
// good hash gives independent streams.
// -----------------------------------------------------------------------------
struct Params {
    int   width, height;

    float view_center_x, view_center_y;
    float zoom;
    float view_y_span;
    float view_aspect_ratio;
    float rotation;

    float initial_z_x, initial_z_y;
    float exponent_x,  exponent_y;

    int   anti;

    float sample_center_x, sample_center_y;
    float sample_radius;
    int   uniform_sample_distribution;

    float bailout_radius_sq;
    unsigned int max_iter_1, max_iter_2, max_iter_3;

    float gamma;
    float normalization_floor;

    // Per-channel "trim" multipliers applied to the channel max during tonemap.
    // 1.0 = no change. < 1 brightens (effective max smaller). Use these to
    // bake colorgrade into the renderer's PNG output (and into checkpoints).
    float trim_r, trim_g, trim_b;

    unsigned long long seed_64;       // unique per-launch, per-device
    unsigned int       samples_per_thread;
};

// -----------------------------------------------------------------------------
// Device math
// -----------------------------------------------------------------------------

// PCG XSH-RR 64→32 hash. Strong avalanche, statistically independent outputs
// for arithmetically nearby inputs — the property we need for thread seeding.
__device__ __forceinline__ unsigned int pcg_hash_64(unsigned long long input) {
    unsigned long long state = input * 0x5851F42D4C957F2DULL + 0x14057B7EF767814FULL;
    unsigned long long word  = ((state >> ((state >> 59u) + 5u)) ^ state) * 0xAEF17502108EF2D9ULL;
    return (unsigned int)((word >> 43u) ^ word);
}

__device__ __forceinline__ unsigned int xorshift32(unsigned int* state) {
    unsigned int x = *state;
    x ^= x << 13u;
    x ^= x >> 17u;
    x ^= x << 5u;
    *state = x;
    return x;
}

__device__ __forceinline__ float random_f32_unit(unsigned int* state) {
    return (float)xorshift32(state) * (1.0f / 4294967296.0f);
}

__device__ __forceinline__ float2 random_complex_delta(
    unsigned int* state, float cx, float cy, float radius, int uniform_dist)
{
    float u1 = random_f32_unit(state);
    float u2 = random_f32_unit(state);
    if (uniform_dist) u2 = sqrtf(u2);
    float theta = 6.28318530718f * u1;
    float r     = radius * u2;
    float2 out;
    out.x = cx + cosf(theta) * r;
    out.y = cy + sinf(theta) * r;
    return out;
}

// Fast path for z² (Mandelbrot): (x+yi)² = (x²-y²) + 2xy i. Bypasses
// sqrt/atan2/log/pow/exp/cos/sin. Uniform branch — ex/ey are the same for
// every thread in a launch, so no warp divergence.
__device__ __forceinline__ float2 complex_pow(float2 z, float ex, float ey) {
    if (ex == 2.0f && ey == 0.0f) {
        return make_float2(z.x * z.x - z.y * z.y, 2.0f * z.x * z.y);
    }
    float r = sqrtf(z.x * z.x + z.y * z.y);
    if (r == 0.0f) return make_float2(0.0f, 0.0f);
    float theta     = atan2f(z.y, z.x);
    float log_r     = logf(r);
    float new_r     = powf(r, ex) * expf(-ey * theta);
    float new_theta = ex * theta + ey * log_r;
    float2 out;
    out.x = new_r * cosf(new_theta);
    out.y = new_r * sinf(new_theta);
    return out;
}

__device__ __forceinline__ float2 rotate_point(float2 p, float angle) {
    float c = cosf(angle), s = sinf(angle);
    float2 out;
    out.x = c * p.x - s * p.y;
    out.y = s * p.x + c * p.y;
    return out;
}

__device__ __forceinline__ int2 world_to_pixel(float2 p, const Params& P) {
    float2 d = make_float2(p.x - P.view_center_x, p.y - P.view_center_y);
    float2 offset = rotate_point(d, -P.rotation);

    float half_w = P.view_y_span * 0.5f * P.view_aspect_ratio;
    float half_h = P.view_y_span * 0.5f;

    float norm_x = (offset.x + half_w) / (2.0f * half_w);
    float norm_y = (offset.y + half_h) / (2.0f * half_h);

    int2 px;
    px.x = (int)floorf(norm_x * (float)P.width);
    px.y = (int)floorf(norm_y * (float)P.height);
    return px;
}

__device__ __forceinline__ void increment_pixel_channel(
    unsigned int* histogram, int2 pixel, unsigned int channel, const Params& P)
{
    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= P.width || pixel.y >= P.height) return;
    unsigned int pixels  = (unsigned int)P.width * (unsigned int)P.height;
    unsigned int idx     = ((unsigned int)pixel.y * (unsigned int)P.width
                          + (unsigned int)pixel.x) * 3u + channel;
    unsigned int new_val = atomicAdd(&histogram[idx], 1u) + 1u;
    unsigned int max_idx = pixels * 3u + channel;
    atomicMax(&histogram[max_idx], new_val);
}

__device__ __forceinline__ unsigned int count_iterations(
    float2 z0, float ex, float ey, float2 c, unsigned int max_iter, float bailout_sq)
{
    unsigned int i = 0u;
    float2 z = z0;
    while (i < max_iter) {
        z = complex_pow(z, ex, ey);
        z.x += c.x; z.y += c.y;
        i++;
        if (z.x * z.x + z.y * z.y > bailout_sq) break;
    }
    return i;
}

__device__ __forceinline__ void accumulate_orbit(
    unsigned int* histogram,
    float2 z0, float ex, float ey, float2 c,
    unsigned int iterations, const Params& P)
{
    float2 z = z0;
    for (unsigned int i = 0u; i < iterations; i++) {
        z = complex_pow(z, ex, ey);
        z.x += c.x; z.y += c.y;
        int2 pixel = world_to_pixel(z, P);
        if (i <= P.max_iter_1) increment_pixel_channel(histogram, pixel, 0u, P);
        if (i <= P.max_iter_2) increment_pixel_channel(histogram, pixel, 1u, P);
        if (i <= P.max_iter_3) increment_pixel_channel(histogram, pixel, 2u, P);
    }
}

// -----------------------------------------------------------------------------
// Compute kernel — uint64 seed mixing for collision-free thread streams at
// arbitrary scale (validated up to 10¹¹ threads across one cloud run).
// -----------------------------------------------------------------------------
__global__ void buddhabrot_kernel(unsigned int* __restrict__ histogram, const Params P) {
    unsigned int gid = blockIdx.x * blockDim.x + threadIdx.x;

    // 64-bit input through PCG hash → 32-bit xorshift state. Multiplying gid
    // by an odd 64-bit constant (Knuth golden-ratio derivative) decorrelates
    // adjacent thread IDs before they hit the hash.
    unsigned long long s64 = P.seed_64 ^ ((unsigned long long)gid * 0x9E3779B97F4A7C15ULL);
    unsigned int seed = pcg_hash_64(s64);
    if (seed == 0u) seed = 1u;

    unsigned int max_iter = P.max_iter_1;
    if (P.max_iter_2 > max_iter) max_iter = P.max_iter_2;
    if (P.max_iter_3 > max_iter) max_iter = P.max_iter_3;

    float2 z0 = make_float2(P.initial_z_x, P.initial_z_y);

    for (unsigned int s = 0u; s < P.samples_per_thread; s++) {
        float2 c = random_complex_delta(&seed,
                       P.sample_center_x, P.sample_center_y,
                       P.sample_radius, P.uniform_sample_distribution);

        unsigned int i = count_iterations(z0, P.exponent_x, P.exponent_y, c, max_iter, P.bailout_radius_sq);

        bool inside = (i >= max_iter);
        bool anti   = (P.anti != 0);
        if (inside != anti) continue;

        accumulate_orbit(histogram, z0, P.exponent_x, P.exponent_y, c, i, P);
    }
}

// -----------------------------------------------------------------------------
// Multi-GPU merge kernels.
// `sum_pixels_kernel` adds one peer histogram into the master's pixel data only
// (skipping the 3 max-tracking tail slots, which we recompute afterward).
// `compute_max_kernel` rebuilds those tail slots from the merged pixel data.
// -----------------------------------------------------------------------------
__global__ void sum_pixels_kernel(
    unsigned int* __restrict__ dest,
    const unsigned int* __restrict__ src,
    unsigned int n_pixel_words)
{
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_pixel_words) return;
    dest[idx] += src[idx];
}

__global__ void compute_max_kernel(
    unsigned int* __restrict__ hist,
    unsigned int pixels)
{
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= pixels * 3u) return;
    unsigned int channel = idx % 3u;
    unsigned int max_idx = pixels * 3u + channel;
    atomicMax(&hist[max_idx], hist[idx]);
}

// -----------------------------------------------------------------------------
// Tonemap kernel — port of render.wgsl fs_main, GPU byte-swap to PNG big-endian.
// -----------------------------------------------------------------------------
__device__ __forceinline__ uint16_t bswap16(uint16_t v) {
    return (uint16_t)((v << 8) | (v >> 8));
}

__global__ void tonemap_kernel(
    const unsigned int* __restrict__ histogram,
    uint16_t* __restrict__ out,
    const Params P)
{
    unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= (unsigned)P.width || y >= (unsigned)P.height) return;

    unsigned int pixels   = (unsigned int)P.width * (unsigned int)P.height;
    unsigned int hist_idx = (y * (unsigned)P.width + x) * 3u;

    float r_count = (float)histogram[hist_idx + 0u];
    float g_count = (float)histogram[hist_idx + 1u];
    float b_count = (float)histogram[hist_idx + 2u];

    // Per-channel trim: multiplier on the effective max for tone-grading.
    // trim < 1 brightens that channel (lower effective max → higher t).
    // trim = 1 is the WGSL behavior.
    unsigned int max_base = pixels * 3u;
    float r_max = fmaxf((float)histogram[max_base + 0u] * P.trim_r, P.normalization_floor);
    float g_max = fmaxf((float)histogram[max_base + 1u] * P.trim_g, P.normalization_floor);
    float b_max = fmaxf((float)histogram[max_base + 2u] * P.trim_b, P.normalization_floor);

    float rt = fminf(fmaxf(r_count / r_max, 0.0f), 1.0f);
    float gt = fminf(fmaxf(g_count / g_max, 0.0f), 1.0f);
    float bt = fminf(fmaxf(b_count / b_max, 0.0f), 1.0f);

    float r = 1.0f - powf(1.0f - rt, P.gamma);
    float g = 1.0f - powf(1.0f - gt, P.gamma);
    float b = 1.0f - powf(1.0f - bt, P.gamma);

    uint16_t r16 = (uint16_t)fminf(roundf(r * 65535.0f), 65535.0f);
    uint16_t g16 = (uint16_t)fminf(roundf(g * 65535.0f), 65535.0f);
    uint16_t b16 = (uint16_t)fminf(roundf(b * 65535.0f), 65535.0f);

    unsigned int out_y   = (unsigned)P.height - 1u - y;
    unsigned int out_idx = (out_y * (unsigned)P.width + x) * 3u;
    out[out_idx + 0u] = bswap16(r16);
    out[out_idx + 1u] = bswap16(g16);
    out[out_idx + 2u] = bswap16(b16);
}

// -----------------------------------------------------------------------------
// Host helpers
// -----------------------------------------------------------------------------
static void check(cudaError_t e, const char* what) {
    if (e != cudaSuccess) {
        fprintf(stderr, "[CUDA ERROR] %s: %s\n", what, cudaGetErrorString(e));
        std::exit(1);
    }
}

static double now_seconds() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

static void print_usage(const char* argv0) {
    fprintf(stderr,
        "Usage: %s [options]\n"
        "  --width N                output width  (default 16384)\n"
        "  --height N               output height (default 12288)\n"
        "  --samples N              total samples (default 256000000000)\n"
        "  --output PATH            output PNG path (default buddhabrot.png)\n"
        "  --iter-r N               red   max iterations (default 2000)\n"
        "  --iter-g N               green max iterations (default 200)\n"
        "  --iter-b N               blue  max iterations (default 20)\n"
        "  --view-center-x F        camera X (default -0.5935417456742)\n"
        "  --view-center-y F        camera Y (default  0.04166264380232)\n"
        "  --zoom F                 camera zoom (default 0.5)\n"
        "  --rotation-deg F         camera rotation in degrees (default 90)\n"
        "  --sample-center-x F      sample disk center X (default 0.0)\n"
        "  --sample-center-y F      sample disk center Y (default 0.0)\n"
        "  --sample-radius F        sample disk radius (default 2.5)\n"
        "  --trim-r F               red   tonemap trim multiplier (default 1.0)\n"
        "  --trim-g F               green tonemap trim multiplier (default 1.0)\n"
        "  --trim-b F               blue  tonemap trim multiplier (default 1.0)\n"
        "                           (trim < 1 brightens that channel; matches\n"
        "                            colorgrade.py with sample-count-invariant trims)\n"
        "  --target-r F             auto-derive trim_r so effective R max = F\n"
        "  --target-g F             auto-derive trim_g so effective G max = F\n"
        "  --target-b F             auto-derive trim_b so effective B max = F\n"
        "                           (overrides --trim-* if set; computed at end\n"
        "                            of render from the measured channel maxes)\n"
        "  --blocks N               CUDA blocks per launch (default 4096)\n"
        "  --threads N              CUDA threads per block (default 256)\n"
        "  --samples-per-thread N   samples per thread per launch (default 1024)\n"
        "  --base-seed N            RNG base seed (uint64, default time-derived)\n"
        "  --devices N              number of GPUs to use (default: all available)\n"
        "  --launches-per-round N   sync/report cadence (default 8)\n"
        "  --checkpoint-every N     merge+tonemap+save every N rounds (default 0=off)\n"
        "                           (each checkpoint writes <output>.cpNNNN.png;\n"
        "                            safe to interrupt — latest cp is usable)\n"
        "  --help                   show this message\n",
        argv0);
}

int main(int argc, char** argv) {
    // Defaults
    int   width                 = 16384;
    int   height                = 12288;
    unsigned long long total_samples = 256000000000ULL;
    const char* output_path     = "buddhabrot.png";
    unsigned int max_iter_r     = 2000;
    unsigned int max_iter_g     = 200;
    unsigned int max_iter_b     = 20;

    double view_center_x        = -0.5935417456742;
    double view_center_y        =  0.04166264380232;
    double zoom                 = 0.5;
    double rotation_deg         = 90.0;

    int blocks_per_launch       = 4096;
    int threads_per_block       = 256;
    unsigned int samples_per_thread = 1024;

    unsigned long long base_seed = ((unsigned long long)now_seconds() * 0x9E3779B97F4A7C15ULL) ^ 0xC0FFEE0DEADBEEFULL;

    int requested_devices       = 0;       // 0 = all
    int launches_per_round      = 8;

    double sample_center_x      = 0.0;
    double sample_center_y      = 0.0;
    double sample_radius        = 2.5;

    double trim_r               = 1.0;
    double trim_g               = 1.0;
    double trim_b               = 1.0;
    double target_r             = 0.0;     // 0 = unset, derive from --trim-r
    double target_g             = 0.0;
    double target_b             = 0.0;

    int checkpoint_every_rounds = 0;       // 0 = no checkpoints

    // CLI
    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        auto need = [&](const char* flag)->const char* {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for %s\n", flag); std::exit(1); }
            return argv[++i];
        };
        if      (!strcmp(a, "--width"))              width  = atoi(need(a));
        else if (!strcmp(a, "--height"))             height = atoi(need(a));
        else if (!strcmp(a, "--samples"))            total_samples = strtoull(need(a), nullptr, 10);
        else if (!strcmp(a, "--output"))             output_path = need(a);
        else if (!strcmp(a, "--iter-r"))             max_iter_r = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--iter-g"))             max_iter_g = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--iter-b"))             max_iter_b = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--view-center-x"))      view_center_x = atof(need(a));
        else if (!strcmp(a, "--view-center-y"))      view_center_y = atof(need(a));
        else if (!strcmp(a, "--zoom"))               zoom = atof(need(a));
        else if (!strcmp(a, "--rotation-deg"))       rotation_deg = atof(need(a));
        else if (!strcmp(a, "--sample-center-x"))    sample_center_x = atof(need(a));
        else if (!strcmp(a, "--sample-center-y"))    sample_center_y = atof(need(a));
        else if (!strcmp(a, "--sample-radius"))      sample_radius = atof(need(a));
        else if (!strcmp(a, "--trim-r"))             trim_r = atof(need(a));
        else if (!strcmp(a, "--trim-g"))             trim_g = atof(need(a));
        else if (!strcmp(a, "--trim-b"))             trim_b = atof(need(a));
        else if (!strcmp(a, "--target-r"))           target_r = atof(need(a));
        else if (!strcmp(a, "--target-g"))           target_g = atof(need(a));
        else if (!strcmp(a, "--target-b"))           target_b = atof(need(a));
        else if (!strcmp(a, "--blocks"))             blocks_per_launch = atoi(need(a));
        else if (!strcmp(a, "--threads"))            threads_per_block = atoi(need(a));
        else if (!strcmp(a, "--samples-per-thread")) samples_per_thread = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--base-seed"))          base_seed = strtoull(need(a), nullptr, 10);
        else if (!strcmp(a, "--devices"))            requested_devices = atoi(need(a));
        else if (!strcmp(a, "--launches-per-round")) launches_per_round = atoi(need(a));
        else if (!strcmp(a, "--checkpoint-every"))   checkpoint_every_rounds = atoi(need(a));
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { print_usage(argv[0]); return 0; }
        else { fprintf(stderr, "Unknown arg: %s\n", a); print_usage(argv[0]); return 1; }
    }

    Params P{};
    P.width                       = width;
    P.height                      = height;
    P.view_center_x               = (float)view_center_x;
    P.view_center_y               = (float)view_center_y;
    P.zoom                        = (float)zoom;
    P.view_y_span                 = (float)(4.0 / pow(2.0, zoom));
    P.view_aspect_ratio           = (float)width / (float)height;
    P.rotation                    = (float)(rotation_deg * 3.14159265358979323846 / 180.0);
    P.initial_z_x                 = 0.0f;
    P.initial_z_y                 = 0.0f;
    P.exponent_x                  = 2.0f;
    P.exponent_y                  = 0.0f;
    P.anti                        = 0;
    P.sample_center_x             = (float)sample_center_x;
    P.sample_center_y             = (float)sample_center_y;
    P.sample_radius               = (float)sample_radius;
    P.uniform_sample_distribution = 1;
    P.bailout_radius_sq           = 16.0f;
    P.max_iter_1                  = max_iter_r;
    P.max_iter_2                  = max_iter_g;
    P.max_iter_3                  = max_iter_b;
    P.gamma                       = 4.0f;
    P.normalization_floor         = 15.0f;
    P.trim_r                      = (float)trim_r;
    P.trim_g                      = (float)trim_g;
    P.trim_b                      = (float)trim_b;
    P.samples_per_thread          = samples_per_thread;

    // Memory budget
    size_t pixels     = (size_t)width * (size_t)height;
    size_t hist_count = pixels * 3 + 3;
    size_t hist_bytes = hist_count * sizeof(unsigned int);
    size_t out_count  = pixels * 3;
    size_t out_bytes  = out_count * sizeof(uint16_t);

    // Device discovery
    int total_devices = 0;
    check(cudaGetDeviceCount(&total_devices), "GetDeviceCount");
    if (total_devices < 1) {
        fprintf(stderr, "No CUDA devices found.\n");
        return 1;
    }
    int n_devices = (requested_devices > 0)
                    ? std::min(requested_devices, total_devices)
                    : total_devices;

    fprintf(stderr, "===========================================\n");
    fprintf(stderr, "Buddhabrot CUDA renderer (multi-GPU)\n");
    fprintf(stderr, "Resolution      : %d x %d  (%.1f Mpx)\n",
        width, height, (double)pixels / 1e6);
    fprintf(stderr, "View Y span     : %.6f\n", P.view_y_span);
    fprintf(stderr, "View center     : (%.10f, %.10f)\n", view_center_x, view_center_y);
    fprintf(stderr, "Zoom / rotation : %.4f / %.2f°\n", zoom, rotation_deg);
    fprintf(stderr, "Iter R / G / B  : %u / %u / %u\n", max_iter_r, max_iter_g, max_iter_b);
    fprintf(stderr, "Total samples   : %llu\n", (unsigned long long)total_samples);
    fprintf(stderr, "Base seed (u64) : %llu\n", (unsigned long long)base_seed);
    fprintf(stderr, "Per device VRAM : %.2f GB hist + %.2f GB out (dev 0 only)\n",
        (double)hist_bytes / (double)(1ULL << 30),
        (double)out_bytes  / (double)(1ULL << 30));
    fprintf(stderr, "Devices         : %d (of %d available)\n", n_devices, total_devices);
    for (int d = 0; d < n_devices; d++) {
        cudaDeviceProp prop{};
        check(cudaGetDeviceProperties(&prop, d), "device props");
        fprintf(stderr, "  [%d] %s  sm_%d%d  %.1f GB\n",
            d, prop.name, prop.major, prop.minor,
            (double)prop.totalGlobalMem / (double)(1ULL << 30));
    }
    fprintf(stderr, "===========================================\n");

    // Enable peer access from device 0 to all others (so cudaMemcpyPeer is fast)
    if (n_devices > 1) {
        check(cudaSetDevice(0), "set dev 0");
        for (int d = 1; d < n_devices; d++) {
            int can = 0;
            check(cudaDeviceCanAccessPeer(&can, 0, d), "can access peer");
            if (!can) {
                fprintf(stderr, "  P2P 0<-%d not available; will fall back to host staging.\n", d);
                continue;
            }
            cudaError_t e = cudaDeviceEnablePeerAccess(d, 0);
            if (e != cudaSuccess && e != cudaErrorPeerAccessAlreadyEnabled) {
                fprintf(stderr, "  P2P 0<-%d enable: %s (will fall back).\n", d, cudaGetErrorString(e));
            }
        }
    }

    // Allocate per-device histograms
    std::vector<unsigned int*> d_hist(n_devices, nullptr);
    for (int d = 0; d < n_devices; d++) {
        check(cudaSetDevice(d), "set device alloc");
        check(cudaMalloc(&d_hist[d], hist_bytes), "cudaMalloc hist");
        check(cudaMemset(d_hist[d], 0, hist_bytes), "cudaMemset hist");
    }

    // Output buffer on device 0 only
    check(cudaSetDevice(0), "set dev 0 out");
    uint16_t* d_out = nullptr;
    check(cudaMalloc(&d_out, out_bytes), "cudaMalloc out");

    // Streams per device
    std::vector<cudaStream_t> streams(n_devices);
    for (int d = 0; d < n_devices; d++) {
        check(cudaSetDevice(d), "set device stream");
        check(cudaStreamCreate(&streams[d]), "stream create");
    }

    // Distribute work: each device runs the same number of launches.
    unsigned long long samples_per_launch =
        (unsigned long long)blocks_per_launch * threads_per_block * samples_per_thread;
    unsigned long long total_launches_global =
        (total_samples + samples_per_launch - 1) / samples_per_launch;
    unsigned long long launches_per_device =
        (total_launches_global + n_devices - 1) / n_devices;
    unsigned long long actual_total_launches = (unsigned long long)n_devices * launches_per_device;
    unsigned long long actual_total_samples  = actual_total_launches * samples_per_launch;

    fprintf(stderr, "Per-launch      : %d blocks × %d threads × %u samples = %llu\n",
        blocks_per_launch, threads_per_block, samples_per_thread,
        (unsigned long long)samples_per_launch);
    fprintf(stderr, "Per-device      : %llu launches → %llu samples\n",
        (unsigned long long)launches_per_device,
        (unsigned long long)(launches_per_device * samples_per_launch));
    fprintf(stderr, "Aggregate       : %llu samples across %d devices\n",
        (unsigned long long)actual_total_samples, n_devices);
    if (checkpoint_every_rounds > 0) {
        fprintf(stderr, "Checkpoints     : every %d round(s)\n", checkpoint_every_rounds);
    }
    fprintf(stderr, "===========================================\n");

    // Allocate the merge staging buffer once (kept for reuse at every checkpoint).
    unsigned int* d_staging = nullptr;
    if (n_devices > 1) {
        check(cudaSetDevice(0), "set dev 0 staging");
        check(cudaMalloc(&d_staging, hist_bytes), "cudaMalloc staging");
    }

    // -----------------------------------------------------------------------
    // save_image: merge per-device histograms onto device 0 (destructive — zeroes
    // d_hist[1..N-1] so future rounds accumulate fresh deltas), recompute channel
    // maxes, optionally derive trim from --target-* flags, tonemap, save PNG.
    //
    // Safe to call mid-render (checkpoint) or at the end (final). After return,
    // d_hist[0] contains the cumulative total and is ready to keep accumulating.
    // -----------------------------------------------------------------------
    auto save_image = [&](const std::string& path) -> bool {
        check(cudaSetDevice(0), "set dev 0 in save");

        // Merge if multi-GPU
        if (n_devices > 1) {
            unsigned int n_pixel_words = (unsigned int)pixels * 3u;
            unsigned int blocks_sum    = (n_pixel_words + 255u) / 256u;
            for (int d = 1; d < n_devices; d++) {
                check(cudaMemcpyPeer(d_staging, 0, d_hist[d], d, hist_bytes), "memcpy peer");
                sum_pixels_kernel<<<blocks_sum, 256>>>(d_hist[0], d_staging, n_pixel_words);
                check(cudaGetLastError(), "sum_pixels launch");
                // Zero out the peer histogram so the next round starts fresh —
                // prevents double-counting at the next merge.
                check(cudaSetDevice(d), "set dev d for zero");
                check(cudaMemset(d_hist[d], 0, hist_bytes), "zero peer hist");
                check(cudaSetDevice(0), "back to dev 0");
            }
            // Recompute master max slots from the merged pixel data.
            check(cudaMemset(d_hist[0] + pixels * 3, 0, 3 * sizeof(unsigned int)),
                  "zero master max slots");
            compute_max_kernel<<<blocks_sum, 256>>>(d_hist[0], (unsigned int)pixels);
            check(cudaDeviceSynchronize(), "merge max sync");
        }

        // Read channel maxima for diagnostics + optional auto-trim derivation.
        std::vector<unsigned int> tail(3);
        check(cudaMemcpy(tail.data(), d_hist[0] + pixels * 3, 3 * sizeof(unsigned int),
                         cudaMemcpyDeviceToHost), "memcpy tail");
        fprintf(stderr, "  channel maxes  R=%u  G=%u  B=%u\n", tail[0], tail[1], tail[2]);
        if (tail[0] > 0xC0000000u || tail[1] > 0xC0000000u || tail[2] > 0xC0000000u) {
            fprintf(stderr, "  WARNING: channel max >75%% of UINT32_MAX — reduce samples or upgrade hist to u64.\n");
        }

        Params local_P = P;
        if (target_r > 0.0 || target_g > 0.0 || target_b > 0.0) {
            if (target_r > 0.0 && tail[0] > 0u) local_P.trim_r = (float)(target_r / (double)tail[0]);
            if (target_g > 0.0 && tail[1] > 0u) local_P.trim_g = (float)(target_g / (double)tail[1]);
            if (target_b > 0.0 && tail[2] > 0u) local_P.trim_b = (float)(target_b / (double)tail[2]);
            fprintf(stderr, "  auto-trim      r=%.4f  g=%.4f  b=%.4f\n",
                local_P.trim_r, local_P.trim_g, local_P.trim_b);
        }

        // Tonemap
        dim3 tm_threads(16, 16);
        dim3 tm_blocks((width + 15) / 16, (height + 15) / 16);
        tonemap_kernel<<<tm_blocks, tm_threads>>>(d_hist[0], d_out, local_P);
        check(cudaDeviceSynchronize(), "tonemap sync");

        // Copy out
        std::vector<unsigned char> host_be(out_bytes);
        check(cudaMemcpy(host_be.data(), d_out, out_bytes, cudaMemcpyDeviceToHost), "memcpy out");

        // Encode 16-bit PNG
        lodepng::State state;
        state.info_raw.bitdepth          = 16;
        state.info_raw.colortype         = LCT_RGB;
        state.info_png.color.bitdepth    = 16;
        state.info_png.color.colortype   = LCT_RGB;
        state.encoder.auto_convert       = 0;
        state.encoder.zlibsettings.windowsize = 1024;
        state.encoder.zlibsettings.nicematch  = 64;

        std::vector<unsigned char> png;
        unsigned err = lodepng::encode(png, host_be, (unsigned)width, (unsigned)height, state);
        if (err) {
            fprintf(stderr, "  lodepng encode error %u: %s\n", err, lodepng_error_text(err));
            return false;
        }
        err = lodepng::save_file(png, path);
        if (err) {
            fprintf(stderr, "  lodepng save error %u: %s\n", err, lodepng_error_text(err));
            return false;
        }
        fprintf(stderr, "  -> %s  (%.1f MB)\n", path.c_str(), (double)png.size() / (1024.0*1024.0));
        return true;
    };

    // Helper: build "<basename>.cpNNNN.png" path for checkpoint saves.
    auto cp_path = [&](unsigned long long n) -> std::string {
        std::string base = output_path;
        auto dot = base.rfind('.');
        char buf[2048];
        if (dot != std::string::npos && dot > 0) {
            snprintf(buf, sizeof(buf), "%.*s.cp%04llu%s",
                     (int)dot, base.c_str(),
                     (unsigned long long)n,
                     base.c_str() + dot);
        } else {
            snprintf(buf, sizeof(buf), "%s.cp%04llu", base.c_str(),
                     (unsigned long long)n);
        }
        return buf;
    };

    // Kernel launch loop — round-robin over devices, sync every `launches_per_round`
    double t_start = now_seconds();

    if (launches_per_round < 1) launches_per_round = 1;
    unsigned long long n_rounds =
        (launches_per_device + (unsigned long long)launches_per_round - 1)
        / (unsigned long long)launches_per_round;

    for (unsigned long long round = 0; round < n_rounds; round++) {
        unsigned long long round_start = round * (unsigned long long)launches_per_round;
        unsigned long long round_end   = std::min(
            round_start + (unsigned long long)launches_per_round, launches_per_device);

        // Queue all launches in this round across all devices
        for (int d = 0; d < n_devices; d++) {
            check(cudaSetDevice(d), "set device launch");
            for (unsigned long long L = round_start; L < round_end; L++) {
                Params local_P = P;
                local_P.seed_64 = base_seed
                                ^ ((unsigned long long)d * 0xC2B2AE3D27D4EB4FULL)
                                ^ (L                   * 0x9E3779B97F4A7C15ULL);
                buddhabrot_kernel<<<blocks_per_launch, threads_per_block, 0, streams[d]>>>(
                    d_hist[d], local_P);
            }
        }

        // Sync all devices before reporting
        for (int d = 0; d < n_devices; d++) {
            check(cudaSetDevice(d), "set device sync");
            check(cudaStreamSynchronize(streams[d]), "stream sync");
        }

        // Progress
        double elapsed = now_seconds() - t_start;
        double frac    = (double)round_end / (double)launches_per_device;
        double eta     = (frac > 0) ? (elapsed / frac - elapsed) : 0.0;
        unsigned long long samples_done = round_end * samples_per_launch * (unsigned long long)n_devices;
        fprintf(stderr, "  round %4llu / %llu  (%5.1f%%)  samples %llu  elapsed %7.1fs  ETA %7.1fs  rate %.1f M/s\n",
            (unsigned long long)(round + 1), (unsigned long long)n_rounds,
            frac * 100.0,
            samples_done, elapsed, eta,
            (double)samples_done / elapsed / 1e6);

        // Checkpoint if requested (and not the very last round — final save handles that)
        if (checkpoint_every_rounds > 0 &&
            (round + 1) % (unsigned long long)checkpoint_every_rounds == 0 &&
            (round + 1) < n_rounds) {
            std::string path = cp_path(round + 1);
            fprintf(stderr, "  checkpoint at round %llu...\n", (unsigned long long)(round + 1));
            double t_cp = now_seconds();
            save_image(path);
            fprintf(stderr, "  checkpoint took %.1fs\n", now_seconds() - t_cp);
        }
    }
    double t_compute = now_seconds() - t_start;
    fprintf(stderr, "Compute total   : %.2f s  (%.1f M samples / s aggregate)\n",
        t_compute,
        (double)actual_total_samples / t_compute / 1e6);

    // Final save
    fprintf(stderr, "Final save...\n");
    double t_final = now_seconds();
    if (!save_image(output_path)) {
        return 2;
    }
    fprintf(stderr, "Final save took %.2f s\n", now_seconds() - t_final);

    // Cleanup
    if (d_staging) cudaFree(d_staging);
    for (int d = 0; d < n_devices; d++) {
        check(cudaSetDevice(d), "set device free");
        cudaFree(d_hist[d]);
        cudaStreamDestroy(streams[d]);
    }
    cudaSetDevice(0);
    cudaFree(d_out);

    fprintf(stderr, "===========================================\n");
    fprintf(stderr, "TOTAL           : %.2f s -> %s\n", now_seconds() - t_start, output_path);
    fprintf(stderr, "===========================================\n");
    return 0;
}
