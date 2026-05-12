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
#include <random>
#include <atomic>
#if defined(__unix__) || defined(__APPLE__)
#include <signal.h>
#endif
#include "lodepng.h"

// Graceful-terminate flag — set by SIGUSR1 (Linux/cloud only). Watchdog sends
// SIGUSR1 a few minutes before the hard wallclock cap; the render loop checks
// at every round boundary, finishes the current round, saves, and exits.
// Windows has no equivalent path; the flag stays zero on Win32 so behavior is
// unchanged there.
static std::atomic<int> g_terminate_requested(0);
#if defined(__unix__) || defined(__APPLE__)
extern "C" void buddhabrot_sigusr1_handler(int /*sig*/) {
    g_terminate_requested.store(1);
}
#endif

// Integer-precision factor for histogram weights. Uniform-mode increment
// represents 1.0 as HIST_SCALE; IS-mode increment is round(HIST_SCALE / p(c)).
// Histograms are uint64 (4.83 GB at 16K) to absorb any IS weight without
// overflow. Trim values are ratio-invariant across SCALE so canonical 0.2673
// etc. continue to work.
static constexpr unsigned long long HIST_SCALE = 1000ULL;

// -----------------------------------------------------------------------------
// §B7 RAW histogram dump + resume-from header. 128-byte fixed-layout struct
// written at the start of <output>.bin files. Allows crash recovery, RAW format
// preservation for re-grading, and (v1.1) spot-instance resumption.
// Field order chosen so natural C struct alignment lands at exactly 128 bytes.
// Offsets called out in comments so a reader can `od -An -t u8 -j NN -N 8` to
// pull individual fields without parsing the full struct.
// See cloud_render_plan.md "RAW histogram format and resume protocol".
// -----------------------------------------------------------------------------
struct HistHeader {
    char     magic[4];               // offset 0   "BHRA"
    unsigned int version;            // offset 4   1
    unsigned int width;              // offset 8
    unsigned int height;             // offset 12
    unsigned int reserved0;          // offset 16
    unsigned int reserved_pad0;      // offset 20  (explicit padding for hist_count's 8-byte alignment)
    unsigned long long hist_count;   // offset 24  pixels*3 + 3, for sanity match
    unsigned long long samples_done; // offset 32  total trajectories accumulated
    unsigned long long base_seed_used; // offset 40
    double view_center_x;            // offset 48
    double view_center_y;            // offset 56
    double zoom;                     // offset 64
    double rotation_deg;             // offset 72
    double sample_center_x;          // offset 80
    double sample_center_y;          // offset 88
    double sample_radius;            // offset 96
    unsigned int iter_r;             // offset 104
    unsigned int iter_g;             // offset 108
    unsigned int iter_b;             // offset 112
    unsigned int hist_scale;         // offset 116  (HIST_SCALE used)
    unsigned int imap_used;          // offset 120  1 if --imap was active, 0 otherwise
    char     imap_marker[4];         // offset 124  first 4 bytes of imap.bin (poor-man's sanity check)
};                                   // total 128 bytes
static_assert(sizeof(HistHeader) == 128, "HistHeader must be exactly 128 bytes");

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
    // Precomputed cos(-rotation) and sin(-rotation) for world_to_pixel.
    // Computed once on host before kernel launch; calling cos/sin per orbit
    // step (especially in double precision) is a significant slowdown
    // (measured 19× on view_imap_pass_kernel).
    float cos_neg_rot;
    float sin_neg_rot;

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
    // Spatial binning at deep zoom (per-tile renders at 4× canonical scale or
    // beyond) requires double-precision coordinate arithmetic. float32 has ~7
    // decimal digits of precision near c=2.0, which gives ~350 representable
    // floats across the width of one pixel at 4× zoom — finite, so it aliases
    // with pixel boundaries and produces faint Moiré in heavily-converged body
    // regions. Iteration loop stays in float for speed; only this projection
    // step uses double. Cost: ~5 extra fp64 ops per pixel write, negligible
    // against atomic latency.
    double dx = (double)p.x - (double)P.view_center_x;
    double dy = (double)p.y - (double)P.view_center_y;
    // cos/sin precomputed on host into Params (calling cos/sin per orbit step
    // is catastrophically slow, ~19× perf hit in double precision).
    double cos_r = (double)P.cos_neg_rot;
    double sin_r = (double)P.sin_neg_rot;
    double off_x = cos_r * dx - sin_r * dy;
    double off_y = sin_r * dx + cos_r * dy;
    double half_w = (double)P.view_y_span * 0.5 * (double)P.view_aspect_ratio;
    double half_h = (double)P.view_y_span * 0.5;
    double norm_x = (off_x + half_w) / (2.0 * half_w);
    double norm_y = (off_y + half_h) / (2.0 * half_h);

    int2 px;
    px.x = (int)floor(norm_x * (double)P.width);
    px.y = (int)floor(norm_y * (double)P.height);
    return px;
}

__device__ __forceinline__ void increment_pixel_channel(
    unsigned long long* histogram, int2 pixel, unsigned int channel,
    unsigned long long weight, const Params& P)
{
    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= P.width || pixel.y >= P.height) return;
    unsigned int pixels  = (unsigned int)P.width * (unsigned int)P.height;
    unsigned int idx     = ((unsigned int)pixel.y * (unsigned int)P.width
                          + (unsigned int)pixel.x) * 3u + channel;
    unsigned long long new_val = atomicAdd(&histogram[idx], weight) + weight;
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
    unsigned long long* histogram,
    float2 z0, float ex, float ey, float2 c,
    unsigned int iterations, unsigned long long weight, const Params& P)
{
    float2 z = z0;
    for (unsigned int i = 0u; i < iterations; i++) {
        z = complex_pow(z, ex, ey);
        z.x += c.x; z.y += c.y;
        int2 pixel = world_to_pixel(z, P);
        if (i <= P.max_iter_1) increment_pixel_channel(histogram, pixel, 0u, weight, P);
        if (i <= P.max_iter_2) increment_pixel_channel(histogram, pixel, 1u, weight, P);
        if (i <= P.max_iter_3) increment_pixel_channel(histogram, pixel, 2u, weight, P);
    }
}

// -----------------------------------------------------------------------------
// IS draw via Vose alias method on the IMap. Each thread:
//   1. Picks a cell uniformly from [0, n_cells)
//   2. Compares a uniform [0,1) against the cell's threshold; if below, picks
//      the cell, otherwise picks alias[cell].
//   3. Jitters uniformly inside the chosen cell to get c.
//   4. Computes p(c) = imap[cell] / total_mass / cell_area (the IS density).
//
// Returns c via the output param; p(c) via *p_out.
// -----------------------------------------------------------------------------
// Look up IMap probability density at an arbitrary c (used by the defensive
// uniform branch of the mixture sampler — we need p_imap(c) even when c was
// drawn uniformly, not via the alias method).
__device__ __forceinline__ double imap_density_at(
    float2 c,
    const unsigned int* __restrict__ imap_data,
    unsigned long long total_mass,
    unsigned int imap_resolution,
    unsigned int n_cells,
    float disk_cx, float disk_cy, float disk_r)
{
    if (total_mass == 0ULL) return 0.0;
    float dx = c.x - disk_cx;
    float dy = c.y - disk_cy;
    float inv_box = 0.5f / disk_r;
    float u = dx * inv_box + 0.5f;
    float v = dy * inv_box + 0.5f;
    if (u < 0.0f || u >= 1.0f || v < 0.0f || v >= 1.0f) return 0.0;
    unsigned int cx = (unsigned int)(u * (float)imap_resolution);
    unsigned int cy = (unsigned int)(v * (float)imap_resolution);
    if (cx >= imap_resolution) cx = imap_resolution - 1u;
    if (cy >= imap_resolution) cy = imap_resolution - 1u;
    unsigned int cell_idx = cy * imap_resolution + cx;
    double cell_area = (double)(2.0f * disk_r) * (double)(2.0f * disk_r) / (double)n_cells;
    double cell_prob = (double)imap_data[cell_idx] / (double)total_mass;
    return cell_prob / cell_area;
}

__device__ __forceinline__ float2 random_complex_imap(
    unsigned int* state,
    const unsigned int* __restrict__ alias_table,
    const float* __restrict__ alias_threshold,
    const unsigned int* __restrict__ imap_data,
    unsigned long long total_mass,
    unsigned int imap_resolution,
    unsigned int n_cells,
    float disk_cx, float disk_cy, float disk_r,
    double* p_out)
{
    unsigned int u_idx = xorshift32(state) % n_cells;
    float u_thr = random_f32_unit(state);
    unsigned int cell_idx = (u_thr < alias_threshold[u_idx]) ? u_idx : alias_table[u_idx];

    unsigned int cy = cell_idx / imap_resolution;
    unsigned int cx = cell_idx - cy * imap_resolution;

    float jx = random_f32_unit(state);
    float jy = random_f32_unit(state);

    float u = ((float)cx + jx) / (float)imap_resolution;  // [0,1)
    float v = ((float)cy + jy) / (float)imap_resolution;

    float2 c;
    c.x = (u - 0.5f) * 2.0f * disk_r + disk_cx;
    c.y = (v - 0.5f) * 2.0f * disk_r + disk_cy;

    // p(c) = (imap[cell] / total_mass) / cell_area
    // cell_area = (2*disk_r)^2 / n_cells
    double cell_area = (double)(2.0f * disk_r) * (double)(2.0f * disk_r) / (double)n_cells;
    double cell_prob = (double)imap_data[cell_idx] / (double)total_mass;
    *p_out = cell_prob / cell_area;
    return c;
}

// -----------------------------------------------------------------------------
// Compute kernel — uint64 seed mixing + uint64 weighted histogram.
// When `alias_table != nullptr`, samples c via Bitterli IS and weights orbit
// contributions by HIST_SCALE / p(c). Otherwise uniform-on-disk with weight =
// HIST_SCALE (the original behavior, scaled).
// -----------------------------------------------------------------------------
__global__ void buddhabrot_kernel(
    unsigned long long* __restrict__ histogram,
    const Params P,
    const unsigned int* __restrict__ alias_table,
    const float* __restrict__ alias_threshold,
    const unsigned int* __restrict__ imap_data,
    unsigned long long total_mass,
    unsigned int imap_resolution,
    unsigned int min_iter_r,
    unsigned int min_iter_g,
    unsigned int min_iter_b)
{
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

    bool is_mode = (alias_table != nullptr);
    unsigned int n_cells = imap_resolution * imap_resolution;

    // Apply min-iter as channel-cap masks: if escape_iter < min_iter[ch], that
    // channel's accumulate_orbit calls are gated. Cheapest implementation:
    // shadow max_iter_* in a local Params copy when escape is below the floor.
    Params local_P = P;

    float2 z0 = make_float2(P.initial_z_x, P.initial_z_y);

    // Defensive IS — mix 95% IMap-sampled c with 5% uniform c. Bounds the
    // maximum weight by ensuring p_mix(c) is never tiny (uniform contributes
    // a floor of p_uniform = 1 / disk_area). Eliminates firefly outliers
    // (rare orbits with absurd weights) while remaining mathematically
    // unbiased — the weight uses the FULL mixture density regardless of
    // which branch sampled c.
    const float defensive_uniform_frac = 0.05f;   // 5% uniform, 95% imap
    double disk_area = 0.0;
    double p_uniform_density = 0.0;
    if (is_mode) {
        // Disk area for p_uniform = 1 / area. Uniform-on-disk uses √u radial,
        // giving p_uniform(c) = 1 / (π * r²) for c inside the disk, 0 outside.
        // For uniform-on-square (P.uniform_sample_distribution false), the
        // density is 1 / (2r)² on the bounding box.
        disk_area = (P.uniform_sample_distribution != 0)
                  ? (3.14159265358979323846 * (double)P.sample_radius * (double)P.sample_radius)
                  : (4.0 * (double)P.sample_radius * (double)P.sample_radius);
        p_uniform_density = 1.0 / disk_area;
    }

    for (unsigned int s = 0u; s < P.samples_per_thread; s++) {
        float2 c;
        unsigned long long weight;
        if (is_mode) {
            double p_imap_c;
            // Defensive IS branch: 5% uniform, 95% IMap. Always use mixture
            // density for the inverse-probability weight.
            float u_branch = random_f32_unit(&seed);
            if (u_branch < defensive_uniform_frac) {
                c = random_complex_delta(&seed,
                        P.sample_center_x, P.sample_center_y,
                        P.sample_radius, P.uniform_sample_distribution);
                p_imap_c = imap_density_at(c,
                        imap_data, total_mass, imap_resolution, n_cells,
                        P.sample_center_x, P.sample_center_y, P.sample_radius);
            } else {
                c = random_complex_imap(&seed,
                        alias_table, alias_threshold, imap_data,
                        total_mass, imap_resolution, n_cells,
                        P.sample_center_x, P.sample_center_y, P.sample_radius,
                        &p_imap_c);
            }
            // Mixture density (always — regardless of which branch sampled c).
            double p_mix = (1.0 - (double)defensive_uniform_frac) * p_imap_c
                         + (double)defensive_uniform_frac * p_uniform_density;
            if (p_mix <= 0.0) continue;        // c outside disk in defensive branch
            // weight = HIST_SCALE / p_mix. Stochastic rounding to preserve the
            // expected value when p_mix is large enough that w < 1 (which
            // happens at deep-zoom view-aware IS where p(c) is concentrated).
            // Round-to-nearest with min=1 (the original code) BIASED the
            // estimator: every w in [0, 0.5) became 1.0. Stochastic rounding
            // preserves E[weight] = w exactly.
            double w_real = (double)HIST_SCALE / p_mix;
            unsigned long long w_int = (unsigned long long)w_real;
            double w_frac = w_real - (double)w_int;
            float u_round = random_f32_unit(&seed);
            if ((double)u_round < w_frac) w_int += 1ULL;
            if (w_int == 0ULL) continue;       // stochastic round dropped this sample
            weight = w_int;
        } else {
            c = random_complex_delta(&seed,
                    P.sample_center_x, P.sample_center_y,
                    P.sample_radius, P.uniform_sample_distribution);
            weight = HIST_SCALE;
        }

        unsigned int i = count_iterations(z0, P.exponent_x, P.exponent_y, c, max_iter, P.bailout_radius_sq);

        bool inside = (i >= max_iter);
        bool anti   = (P.anti != 0);
        if (inside != anti) continue;

        // Apply min-iter channel gating via local_P (per-thread mutation OK).
        local_P.max_iter_1 = (i >= min_iter_r) ? P.max_iter_1 : 0u;
        local_P.max_iter_2 = (i >= min_iter_g) ? P.max_iter_2 : 0u;
        local_P.max_iter_3 = (i >= min_iter_b) ? P.max_iter_3 : 0u;
        // If all three channels are gated off, skip the orbit entirely.
        if (local_P.max_iter_1 == 0u && local_P.max_iter_2 == 0u && local_P.max_iter_3 == 0u) continue;

        accumulate_orbit(histogram, z0, P.exponent_x, P.exponent_y, c, i, weight, local_P);
    }
}

// -----------------------------------------------------------------------------
// Multi-GPU merge kernels.
// `sum_pixels_kernel` adds one peer histogram into the master's pixel data only
// (skipping the 3 max-tracking tail slots, which we recompute afterward).
// `compute_max_kernel` rebuilds those tail slots from the merged pixel data.
// -----------------------------------------------------------------------------
__global__ void sum_pixels_kernel(
    unsigned long long* __restrict__ dest,
    const unsigned long long* __restrict__ src,
    unsigned int n_pixel_words)
{
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_pixel_words) return;
    dest[idx] += src[idx];
}

__global__ void compute_max_kernel(
    unsigned long long* __restrict__ hist,
    unsigned int pixels)
{
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= pixels * 3u) return;
    unsigned int channel = idx % 3u;
    unsigned int max_idx = pixels * 3u + channel;
    atomicMax(&hist[max_idx], hist[idx]);
}

// -----------------------------------------------------------------------------
// Importance-map construction kernel — Phase 1 of Bitterli importance sampling.
//
// For each thread: take uniform-on-disk samples of c, run the orbit, and on
// escape add `orbit_length` (linear, per Bitterli 2014) into the IMap cell that
// contains c. The resulting IMap[N×N] approximates the density of long-orbit
// c-values across the disk and feeds Phase 2's alias-method IS sampler.
//
// IMap covers a square [-sample_radius, +sample_radius]^2 centered at
// (sample_center). Cells outside the inscribed disk stay at 0 (never sampled).
// -----------------------------------------------------------------------------
__global__ void imap_pass_kernel(
    unsigned int* __restrict__ imap,
    const Params P,
    unsigned int imap_resolution,
    unsigned int imap_iter_cap)
{
    unsigned int gid = blockIdx.x * blockDim.x + threadIdx.x;

    unsigned long long s64 = P.seed_64 ^ ((unsigned long long)gid * 0x9E3779B97F4A7C15ULL);
    unsigned int seed = pcg_hash_64(s64);
    if (seed == 0u) seed = 1u;

    float2 z0 = make_float2(P.initial_z_x, P.initial_z_y);
    float inv_box_size = 0.5f / P.sample_radius;  // dx in [-r,+r] -> u in [0,1]

    for (unsigned int s = 0u; s < P.samples_per_thread; s++) {
        float2 c = random_complex_delta(&seed,
                       P.sample_center_x, P.sample_center_y,
                       P.sample_radius, P.uniform_sample_distribution);

        unsigned int i = count_iterations(z0, P.exponent_x, P.exponent_y,
                            c, imap_iter_cap, P.bailout_radius_sq);

        bool inside = (i >= imap_iter_cap);
        bool anti   = (P.anti != 0);
        if (inside != anti) continue;

        float dx = c.x - P.sample_center_x;
        float dy = c.y - P.sample_center_y;
        float u = dx * inv_box_size + 0.5f;
        float v = dy * inv_box_size + 0.5f;
        if (u < 0.0f || u >= 1.0f || v < 0.0f || v >= 1.0f) continue;

        unsigned int cx = (unsigned int)(u * (float)imap_resolution);
        unsigned int cy = (unsigned int)(v * (float)imap_resolution);
        if (cx >= imap_resolution) cx = imap_resolution - 1u;
        if (cy >= imap_resolution) cy = imap_resolution - 1u;
        unsigned int cell_idx = cy * imap_resolution + cx;

        atomicAdd(&imap[cell_idx], i);
    }
}

// -----------------------------------------------------------------------------
// View-aware IMap pass — variant of imap_pass_kernel that weights cells by
// VIEWPORT-HIT count rather than orbit length. For tile-pyramid renders where
// each tile shows 1/N of the canonical c-image, the canonical orbit-length
// IMap wastes most of its weight on c-values whose orbits don't visit THIS
// tile. The view-aware IMap directs samples to c-values whose orbits actually
// land in the active viewport.
//
// The accumulation: for each escaping c, replay the orbit from z=0 and count
// how many of its z-points fall within the visible viewport. atomicAdd that
// hit-count into the IMap cell containing c. The kernel uses the same
// world_to_pixel logic as accumulate_orbit, so cells weighted by THIS
// kernel's pre-pass match the cells whose c-values produce orbits visible in
// the production-render's viewport.
// -----------------------------------------------------------------------------
__global__ void view_imap_pass_kernel(
    unsigned int* __restrict__ imap,
    const Params P,
    unsigned int imap_resolution,
    unsigned int imap_iter_cap)
{
    unsigned int gid = blockIdx.x * blockDim.x + threadIdx.x;

    unsigned long long s64 = P.seed_64 ^ ((unsigned long long)gid * 0x9E3779B97F4A7C15ULL);
    unsigned int seed = pcg_hash_64(s64);
    if (seed == 0u) seed = 1u;

    float2 z0 = make_float2(P.initial_z_x, P.initial_z_y);
    float inv_box_size = 0.5f / P.sample_radius;

    for (unsigned int s = 0u; s < P.samples_per_thread; s++) {
        float2 c = random_complex_delta(&seed,
                       P.sample_center_x, P.sample_center_y,
                       P.sample_radius, P.uniform_sample_distribution);

        // Determine cell (skip orbit work for c outside box).
        float dx_c = c.x - P.sample_center_x;
        float dy_c = c.y - P.sample_center_y;
        float u_c = dx_c * inv_box_size + 0.5f;
        float v_c = dy_c * inv_box_size + 0.5f;
        if (u_c < 0.0f || u_c >= 1.0f || v_c < 0.0f || v_c >= 1.0f) continue;

        // Replay orbit, count z-points that land in viewport.
        unsigned int hits = 0u;
        float2 z = z0;
        unsigned int it = 0u;
        bool escaped = false;
        while (it < imap_iter_cap) {
            z = complex_pow(z, P.exponent_x, P.exponent_y);
            z.x += c.x; z.y += c.y;
            it++;
            int2 pixel = world_to_pixel(z, P);
            if (pixel.x >= 0 && pixel.y >= 0 &&
                pixel.x < P.width && pixel.y < P.height) {
                hits++;
            }
            if (z.x * z.x + z.y * z.y > P.bailout_radius_sq) {
                escaped = true;
                break;
            }
        }
        bool inside = !escaped;
        bool anti   = (P.anti != 0);
        if (inside != anti) continue;
        if (hits == 0u) continue;

        unsigned int cx = (unsigned int)(u_c * (float)imap_resolution);
        unsigned int cy = (unsigned int)(v_c * (float)imap_resolution);
        if (cx >= imap_resolution) cx = imap_resolution - 1u;
        if (cy >= imap_resolution) cy = imap_resolution - 1u;
        unsigned int cell_idx = cy * imap_resolution + cx;

        atomicAdd(&imap[cell_idx], hits);
    }
}

// -----------------------------------------------------------------------------
// Tonemap kernel — port of render.wgsl fs_main, GPU byte-swap to PNG big-endian.
// -----------------------------------------------------------------------------
__device__ __forceinline__ uint16_t bswap16(uint16_t v) {
    return (uint16_t)((v << 8) | (v >> 8));
}

__global__ void tonemap_kernel(
    const unsigned long long* __restrict__ histogram,
    uint16_t* __restrict__ out,
    const Params P)
{
    unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= (unsigned)P.width || y >= (unsigned)P.height) return;

    unsigned int pixels   = (unsigned int)P.width * (unsigned int)P.height;
    unsigned int hist_idx = (y * (unsigned)P.width + x) * 3u;

    // uint64 → double cast for tonemap arithmetic. fp64 has 53 bits of
    // mantissa, so up to ~9e15 represents exactly; well within budget.
    double r_count = (double)histogram[hist_idx + 0u];
    double g_count = (double)histogram[hist_idx + 1u];
    double b_count = (double)histogram[hist_idx + 2u];

    // Per-channel trim: multiplier on the effective max for tone-grading.
    // trim < 1 brightens that channel (lower effective max → higher t).
    // trim = 1 is the WGSL behavior. The HIST_SCALE factor cancels because
    // both count and max carry it.
    unsigned int max_base = pixels * 3u;
    double r_max = fmax((double)histogram[max_base + 0u] * (double)P.trim_r, (double)P.normalization_floor);
    double g_max = fmax((double)histogram[max_base + 1u] * (double)P.trim_g, (double)P.normalization_floor);
    double b_max = fmax((double)histogram[max_base + 2u] * (double)P.trim_b, (double)P.normalization_floor);

    float rt = (float)fmin(fmax(r_count / r_max, 0.0), 1.0);
    float gt = (float)fmin(fmax(g_count / g_max, 0.0), 1.0);
    float bt = (float)fmin(fmax(b_count / b_max, 0.0), 1.0);

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
        "  --checkpoint-schedule LIST  comma-separated list of specific round\n"
        "                           numbers at which to checkpoint. Combines with\n"
        "                           --checkpoint-every (both can fire). Example:\n"
        "                           --checkpoint-schedule 590,1180,1770,2950,4130\n"
        "                           gives non-uniform cadence (30/30/30/60/60 min\n"
        "                           at 22 M/s). Entries less than resume-from\n"
        "                           starting round are silently skipped.\n"
        "  --build-imap PATH        build importance map (Phase 1 of Bitterli IS),\n"
        "                           weighted by orbit length. Run once for canonical view\n"
        "                           and reuse via --imap.\n"
        "  --build-view-imap PATH   build VIEW-AWARE importance map. Cells weighted by\n"
        "                           viewport-hit count from THIS run's --view-* params,\n"
        "                           not orbit length. Required for tile-pyramid renders\n"
        "                           where each tile sees only 1/N of the canonical view.\n"
        "                           Save to PATH, exit. Skips render entirely.\n"
        "  --imap-resolution N      IMap grid resolution (default 1024)\n"
        "  --imap-samples N         total uniform samples for IMap construction\n"
        "                           (default 100000000)\n"
        "  --imap-iter-cap N        iteration cap for orbit-length weighting in\n"
        "                           the IMap pass (default 2000)\n"
        "  --imap-heatmap PATH      also write 16-bit grayscale PNG heatmap of\n"
        "                           the IMap for visual inspection.\n"
        "  --imap PATH              load importance map; switch to Bitterli IS\n"
        "                           sampling with inverse-probability weighting.\n"
        "                           Without this, sampling is uniform on disk.\n"
        "  --min-iter-r N           min escape iterations to contribute to R\n"
        "                           channel (default 0 = all escapes counted).\n"
        "                           Aramant filtering: 100-200 for sharper R.\n"
        "  --min-iter-g N           min escape iter for G channel (default 0).\n"
        "  --min-iter-b N           min escape iter for B channel (default 0).\n"
        "  --output-raw PATH        write raw uint64 histogram to PATH (.bin) at\n"
        "                           every save. Default: derived from --output\n"
        "                           (e.g., output.png -> output.bin). 128-byte\n"
        "                           HistHeader + uint64[hist_count] data. Enables\n"
        "                           --resume-from + EXR generation + cheap trim\n"
        "                           retune via tools/retune_trims.py.\n"
        "                           File is ~4.83 GB at 16K, ~19.3 GB at 32K.\n"
        "                           Atomic write: tmp + rename.\n"
        "  --no-output-raw          suppress the .bin dump entirely (disk-\n"
        "                           constrained scenarios; loses cheap-retune\n"
        "                           ability — see CLAUDE.md B14/B15).\n"
        "  --resume-from PATH       load <PATH>.bin into the histogram before\n"
        "                           rendering; continues accumulation. Validates\n"
        "                           header (magic, dims, iter caps, hist_scale).\n"
        "                           samples_done from header is subtracted from\n"
        "                           --samples target so render does only the delta.\n"
        "                           Requires a matching .bin from a prior --output-raw run.\n"
        "  --allow-view-mismatch    skip the view-parameter sanity check on\n"
        "                           --resume-from (use with care).\n"
        "  --help                   show this message\n",
        argv0);
}

int main(int argc, char** argv) {
    // Install SIGUSR1 graceful-terminate handler (Linux/cloud only). Watchdog
    // fires SIGUSR1 at T-300s before hard wallclock cap; render loop checks
    // g_terminate_requested at every round boundary, runs final save, exits 0.
#if defined(__unix__) || defined(__APPLE__)
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = buddhabrot_sigusr1_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;  // restart interrupted syscalls
    sigaction(SIGUSR1, &sa, nullptr);
#endif

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
    std::vector<unsigned long long> checkpoint_schedule;  // explicit list of round numbers
    size_t checkpoint_schedule_idx = 0;    // next unfired entry; advanced as schedule entries pass

    // Phase 1 (Bitterli importance map) build mode flags. Empty path = render mode.
    std::string build_imap_path;
    unsigned int imap_resolution = 1024;
    unsigned long long imap_samples = 100000000ULL;
    unsigned int imap_iter_cap = 2000;
    std::string imap_heatmap_path;
    int build_view_aware_imap = 0;     // 0 = orbit-length weighting (Bitterli §B7),
                                        // 1 = viewport-hit weighting (per-tile renders)

    // Phase 2/3/4 (Bitterli IS sampling + min-escape) flags.
    std::string imap_path;                  // empty = uniform sampling
    unsigned int min_iter_r_main = 0;
    unsigned int min_iter_g_main = 0;
    unsigned int min_iter_b_main = 0;

    // §B7 RAW histogram dump + resume-from flags.
    // output_raw_path: empty = auto-derive from --output (write <output>.bin) by default.
    //   Override with explicit --output-raw <path> for custom location.
    //   Suppress entirely with --no-output-raw (disk-constrained users only).
    // The auto-on default is per CLAUDE.md B15 (persistence audit): the histogram is
    // the expensive artifact, the .bin is free architectural insurance — always write
    // it unless explicitly suppressed.
    std::string output_raw_path;
    int output_raw_explicit = 0;            // 1 if --output-raw <path> was given
    int output_raw_disabled = 0;            // 1 if --no-output-raw was given
    std::string resume_from_path;           // empty = fresh render
    int allow_view_mismatch = 0;            // override view-param validation on resume

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
        else if (!strcmp(a, "--checkpoint-schedule")) {
            // Parse comma-separated list of unsigned long long round numbers.
            const char* csv = need(a);
            const char* p = csv;
            while (*p) {
                char* end = nullptr;
                unsigned long long r = strtoull(p, &end, 10);
                if (end == p) break;
                if (r > 0) checkpoint_schedule.push_back(r);
                p = end;
                while (*p == ',' || *p == ' ' || *p == '\t') p++;
            }
            std::sort(checkpoint_schedule.begin(), checkpoint_schedule.end());
        }
        else if (!strcmp(a, "--build-imap"))         build_imap_path = need(a);
        else if (!strcmp(a, "--build-view-imap"))    { build_imap_path = need(a); build_view_aware_imap = 1; }
        else if (!strcmp(a, "--imap-resolution"))    imap_resolution = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--imap-samples"))       imap_samples = strtoull(need(a), nullptr, 10);
        else if (!strcmp(a, "--imap-iter-cap"))      imap_iter_cap = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--imap-heatmap"))       imap_heatmap_path = need(a);
        else if (!strcmp(a, "--imap"))               imap_path = need(a);
        else if (!strcmp(a, "--min-iter-r"))         min_iter_r_main = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--min-iter-g"))         min_iter_g_main = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--min-iter-b"))         min_iter_b_main = (unsigned)atoi(need(a));
        else if (!strcmp(a, "--output-raw"))         { output_raw_path = need(a); output_raw_explicit = 1; }
        else if (!strcmp(a, "--no-output-raw"))      output_raw_disabled = 1;
        else if (!strcmp(a, "--resume-from"))        resume_from_path = need(a);
        else if (!strcmp(a, "--allow-view-mismatch")) allow_view_mismatch = 1;
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { print_usage(argv[0]); return 0; }
        else { fprintf(stderr, "Unknown arg: %s\n", a); print_usage(argv[0]); return 1; }
    }

    // §B7 unconditional .bin dump: derive path from --output unless explicitly set or disabled.
    // Per CLAUDE.md B15 (persistence audit): the histogram is the expensive artifact;
    // .bin is free architectural insurance — always written by default. Suppress only with
    // explicit --no-output-raw (disk-constrained users).
    if (!output_raw_disabled && !output_raw_explicit) {
        std::string base = output_path;
        auto dot = base.rfind('.');
        if (dot != std::string::npos && dot > 0) {
            output_raw_path = base.substr(0, dot) + ".bin";
        } else {
            output_raw_path = base + ".bin";
        }
    } else if (output_raw_disabled) {
        output_raw_path.clear();
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
    P.cos_neg_rot                 = cosf(-P.rotation);
    P.sin_neg_rot                 = sinf(-P.rotation);
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

    // -----------------------------------------------------------------------
    // Phase 1 — IMap build mode. If --build-imap is set, build the importance
    // map and exit; the render path below is skipped entirely. Output is a
    // self-describing imap.bin (40-byte header + N*N uint32 cells) plus an
    // optional 16-bit grayscale heatmap PNG for visual inspection.
    // -----------------------------------------------------------------------
    if (!build_imap_path.empty()) {
        fprintf(stderr, "===========================================\n");
        fprintf(stderr, "Buddhabrot CUDA — Phase 1 (IMap build pass)\n");
        fprintf(stderr, "Output IMap     : %s  (%ux%u cells)\n",
            build_imap_path.c_str(), imap_resolution, imap_resolution);
        fprintf(stderr, "Sample budget   : %llu uniform-on-disk samples\n",
            (unsigned long long)imap_samples);
        fprintf(stderr, "IMap iter cap   : %u\n", imap_iter_cap);
        fprintf(stderr, "Sample disk     : center=(%.4f,%.4f) radius=%.4f\n",
            P.sample_center_x, P.sample_center_y, P.sample_radius);
        if (!imap_heatmap_path.empty()) {
            fprintf(stderr, "Heatmap PNG     : %s\n", imap_heatmap_path.c_str());
        }
        fprintf(stderr, "Base seed (u64) : %llu\n", (unsigned long long)base_seed);
        fprintf(stderr, "===========================================\n");

        int total_devices_imap = 0;
        check(cudaGetDeviceCount(&total_devices_imap), "GetDeviceCount");
        if (total_devices_imap < 1) {
            fprintf(stderr, "No CUDA devices found.\n");
            return 1;
        }
        check(cudaSetDevice(0), "set dev 0 imap");
        cudaDeviceProp prop_imap{};
        check(cudaGetDeviceProperties(&prop_imap, 0), "device props imap");
        fprintf(stderr, "Device          : [0] %s  sm_%d%d  %.1f GB\n",
            prop_imap.name, prop_imap.major, prop_imap.minor,
            (double)prop_imap.totalGlobalMem / (double)(1ULL << 30));

        size_t imap_cells = (size_t)imap_resolution * (size_t)imap_resolution;
        size_t imap_bytes = imap_cells * sizeof(unsigned int);
        unsigned int* d_imap = nullptr;
        check(cudaMalloc(&d_imap, imap_bytes), "cudaMalloc imap");
        check(cudaMemset(d_imap, 0, imap_bytes), "cudaMemset imap");

        unsigned long long samples_per_launch =
            (unsigned long long)blocks_per_launch * threads_per_block * samples_per_thread;
        unsigned long long n_launches =
            (imap_samples + samples_per_launch - 1) / samples_per_launch;
        fprintf(stderr, "Launch grid     : %d blocks x %d threads x %u samples/thr\n",
            blocks_per_launch, threads_per_block, samples_per_thread);
        fprintf(stderr, "Launches        : %llu (covers ~%llu samples)\n",
            (unsigned long long)n_launches,
            (unsigned long long)(n_launches * samples_per_launch));

        cudaStream_t stream_imap;
        check(cudaStreamCreate(&stream_imap), "stream create imap");

        double t_start_imap = now_seconds();
        for (unsigned long long L = 0; L < n_launches; L++) {
            Params local_P = P;
            // Distinct seed domain from render to avoid correlation if both run.
            local_P.seed_64 = base_seed
                            ^ (L * 0x9E3779B97F4A7C15ULL)
                            ^ 0x12345678ABCDEF01ULL;
            if (build_view_aware_imap) {
                view_imap_pass_kernel<<<blocks_per_launch, threads_per_block, 0, stream_imap>>>(
                    d_imap, local_P, imap_resolution, imap_iter_cap);
            } else {
                imap_pass_kernel<<<blocks_per_launch, threads_per_block, 0, stream_imap>>>(
                    d_imap, local_P, imap_resolution, imap_iter_cap);
            }
        }
        check(cudaStreamSynchronize(stream_imap), "stream sync imap");
        double t_compute_imap = now_seconds() - t_start_imap;

        std::vector<unsigned int> h_imap(imap_cells, 0u);
        check(cudaMemcpy(h_imap.data(), d_imap, imap_bytes, cudaMemcpyDeviceToHost),
              "memcpy imap");

        unsigned long long total_mass = 0ULL;
        unsigned int max_cell = 0u;
        unsigned int nonzero_cells = 0u;
        for (size_t i = 0; i < imap_cells; i++) {
            unsigned int v = h_imap[i];
            total_mass += (unsigned long long)v;
            if (v > max_cell) max_cell = v;
            if (v > 0u) nonzero_cells++;
        }
        fprintf(stderr, "===========================================\n");
        fprintf(stderr, "Compute time    : %.3f s  (%.1f M samples / s)\n",
            t_compute_imap,
            (double)(n_launches * samples_per_launch) / t_compute_imap / 1e6);
        fprintf(stderr, "Total mass      : %llu (sum of orbit lengths over escaped c)\n",
            (unsigned long long)total_mass);
        fprintf(stderr, "Nonzero cells   : %u / %zu  (%.2f%%)\n",
            nonzero_cells, imap_cells,
            100.0 * (double)nonzero_cells / (double)imap_cells);
        fprintf(stderr, "Max cell        : %u\n", max_cell);
        if (max_cell > 0u) {
            fprintf(stderr, "Mean nonzero    : %.1f (mass/nonzero_cells)\n",
                (double)total_mass / (double)nonzero_cells);
        }
        fprintf(stderr, "===========================================\n");

        // Write imap.bin: 40-byte header + raw uint32 data.
        {
            FILE* f = fopen(build_imap_path.c_str(), "wb");
            if (!f) {
                fprintf(stderr, "Failed to open %s for writing\n", build_imap_path.c_str());
                cudaFree(d_imap);
                cudaStreamDestroy(stream_imap);
                return 1;
            }
            const char magic[4] = {'I','M','A','P'};
            unsigned int version = 1u;
            unsigned int reserved = 0u;
            float disk_cx = P.sample_center_x;
            float disk_cy = P.sample_center_y;
            float disk_r  = P.sample_radius;
            float reserved2 = 0.0f;
            fwrite(magic, 1, 4, f);
            fwrite(&version, sizeof(unsigned int), 1, f);
            fwrite(&imap_resolution, sizeof(unsigned int), 1, f);
            fwrite(&imap_resolution, sizeof(unsigned int), 1, f); // square
            fwrite(&reserved, sizeof(unsigned int), 1, f);
            fwrite(&total_mass, sizeof(unsigned long long), 1, f);
            fwrite(&disk_cx, sizeof(float), 1, f);
            fwrite(&disk_cy, sizeof(float), 1, f);
            fwrite(&disk_r,  sizeof(float), 1, f);
            fwrite(&reserved2, sizeof(float), 1, f);
            fwrite(h_imap.data(), sizeof(unsigned int), imap_cells, f);
            fclose(f);
            fprintf(stderr, "Wrote IMap: %s (%.1f KB)\n",
                build_imap_path.c_str(),
                (double)(40 + imap_bytes) / 1024.0);
        }

        // Optional heatmap PNG. Use sqrt compression so mid-density cells are
        // visible (linear would only show the brightest boundary cells; log
        // would crush the dynamic range). 16-bit grayscale PNG via lodepng.
        if (!imap_heatmap_path.empty()) {
            std::vector<unsigned char> heatmap(imap_cells * 2);
            float inv_max = (max_cell > 0u) ? 1.0f / (float)max_cell : 0.0f;
            for (size_t i = 0; i < imap_cells; i++) {
                float t = sqrtf((float)h_imap[i] * inv_max);
                if (t < 0.0f) t = 0.0f;
                if (t > 1.0f) t = 1.0f;
                uint16_t v16 = (uint16_t)(t * 65535.0f);
                heatmap[i * 2 + 0] = (unsigned char)(v16 >> 8);   // big-endian
                heatmap[i * 2 + 1] = (unsigned char)(v16 & 0xFF);
            }
            lodepng::State state;
            state.info_raw.bitdepth = 16;
            state.info_raw.colortype = LCT_GREY;
            state.info_png.color.bitdepth = 16;
            state.info_png.color.colortype = LCT_GREY;
            state.encoder.auto_convert = 0;
            std::vector<unsigned char> png;
            unsigned err = lodepng::encode(png, heatmap, imap_resolution, imap_resolution, state);
            if (!err) err = lodepng::save_file(png, imap_heatmap_path);
            if (err) {
                fprintf(stderr, "Heatmap encode/save error %u: %s\n",
                    err, lodepng_error_text(err));
            } else {
                fprintf(stderr, "Wrote heatmap: %s (%.1f KB)\n",
                    imap_heatmap_path.c_str(),
                    (double)png.size() / 1024.0);
            }
        }

        cudaFree(d_imap);
        cudaStreamDestroy(stream_imap);
        return 0;
    }

    // Memory budget
    size_t pixels     = (size_t)width * (size_t)height;
    size_t hist_count = pixels * 3 + 3;
    size_t hist_bytes = hist_count * sizeof(unsigned long long);
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

    // Allocate per-device histograms (uint64 for IS-weight headroom)
    std::vector<unsigned long long*> d_hist(n_devices, nullptr);
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
    if (!checkpoint_schedule.empty()) {
        fprintf(stderr, "Checkpoint sched: %zu explicit round(s):", checkpoint_schedule.size());
        for (size_t i = 0; i < checkpoint_schedule.size() && i < 10; i++) {
            fprintf(stderr, " %llu", (unsigned long long)checkpoint_schedule[i]);
        }
        if (checkpoint_schedule.size() > 10) {
            fprintf(stderr, " ... %llu",
                (unsigned long long)checkpoint_schedule[checkpoint_schedule.size() - 1]);
        }
        fprintf(stderr, "\n");
    }
    fprintf(stderr, "===========================================\n");

    // Allocate the merge staging buffer once (kept for reuse at every checkpoint).
    unsigned long long* d_staging = nullptr;
    if (n_devices > 1) {
        check(cudaSetDevice(0), "set dev 0 staging");
        check(cudaMalloc(&d_staging, hist_bytes), "cudaMalloc staging");
    }

    // -----------------------------------------------------------------------
    // Phase 2/3 — IMap loading + Vose alias method tables.
    // When --imap is set, switch from uniform-on-disk to Bitterli IS sampling
    // with inverse-probability weighting. The kernel takes nullptr alias_table
    // when IS is disabled, falling back to the uniform path.
    // -----------------------------------------------------------------------
    // Per-device IMap arrays. On consumer cards (RTX 4090 etc.) P2P access is
    // disabled by NVIDIA driver, so a single device-0 allocation cannot be
    // read by kernels running on devices 1..N. Allocate independent copies on
    // every device that participates in the render.
    std::vector<unsigned int*> d_alias_table_per_dev;
    std::vector<float*>        d_alias_threshold_per_dev;
    std::vector<unsigned int*> d_imap_data_per_dev;
    unsigned long long  imap_total_mass   = 0ULL;
    unsigned int        imap_res_loaded   = 0u;

    if (!imap_path.empty()) {
        FILE* f = fopen(imap_path.c_str(), "rb");
        if (!f) {
            fprintf(stderr, "Failed to open IMap %s\n", imap_path.c_str());
            return 1;
        }
        char magic[4];
        unsigned int version = 0u;
        unsigned int imap_w = 0u, imap_h = 0u;
        unsigned int reserved = 0u;
        unsigned long long total_mass_loaded = 0ULL;
        float disk_cx = 0.0f, disk_cy = 0.0f, disk_r_loaded = 0.0f;
        float reserved2 = 0.0f;
        size_t nr = 0;
        nr += fread(magic, 1, 4, f);
        nr += fread(&version, sizeof(unsigned int), 1, f) * sizeof(unsigned int);
        nr += fread(&imap_w, sizeof(unsigned int), 1, f) * sizeof(unsigned int);
        nr += fread(&imap_h, sizeof(unsigned int), 1, f) * sizeof(unsigned int);
        nr += fread(&reserved, sizeof(unsigned int), 1, f) * sizeof(unsigned int);
        nr += fread(&total_mass_loaded, sizeof(unsigned long long), 1, f) * sizeof(unsigned long long);
        nr += fread(&disk_cx, sizeof(float), 1, f) * sizeof(float);
        nr += fread(&disk_cy, sizeof(float), 1, f) * sizeof(float);
        nr += fread(&disk_r_loaded, sizeof(float), 1, f) * sizeof(float);
        nr += fread(&reserved2, sizeof(float), 1, f) * sizeof(float);
        if (memcmp(magic, "IMAP", 4) != 0 || version != 1u || imap_w == 0u || imap_w != imap_h) {
            fprintf(stderr, "Invalid IMap header in %s\n", imap_path.c_str());
            fclose(f);
            return 1;
        }
        if (fabsf(disk_cx - P.sample_center_x) > 1e-3f ||
            fabsf(disk_cy - P.sample_center_y) > 1e-3f ||
            fabsf(disk_r_loaded - P.sample_radius) > 1e-3f) {
            fprintf(stderr, "WARNING: IMap disk (%.4f,%.4f r=%.4f) != render disk (%.4f,%.4f r=%.4f)\n",
                disk_cx, disk_cy, disk_r_loaded,
                P.sample_center_x, P.sample_center_y, P.sample_radius);
        }
        size_t n_cells = (size_t)imap_w * (size_t)imap_h;
        std::vector<unsigned int> imap_host(n_cells);
        size_t got = fread(imap_host.data(), sizeof(unsigned int), n_cells, f);
        fclose(f);
        if (got != n_cells) {
            fprintf(stderr, "IMap data short read: %zu / %zu cells\n", got, n_cells);
            return 1;
        }
        imap_res_loaded = imap_w;
        imap_total_mass = total_mass_loaded;

        // Build Vose alias method tables on host. Standard algorithm: scale
        // probabilities by n_cells so average = 1; partition into < 1 (small)
        // and >= 1 (large); for each pair, the small cell's threshold is its
        // scaled prob and its alias is the large cell; the large cell's mass
        // is reduced by what it gave away. Iterate until exhausted.
        std::vector<float> threshold(n_cells);
        std::vector<unsigned int> alias(n_cells);
        std::vector<float> p_scaled(n_cells);
        double inv_total = 1.0 / (double)total_mass_loaded;
        for (size_t i = 0; i < n_cells; i++) {
            p_scaled[i] = (float)((double)imap_host[i] * inv_total * (double)n_cells);
        }
        std::vector<unsigned int> small_q;
        std::vector<unsigned int> large_q;
        small_q.reserve(n_cells / 2);
        large_q.reserve(n_cells / 2);
        for (size_t i = 0; i < n_cells; i++) {
            if (p_scaled[i] < 1.0f) small_q.push_back((unsigned int)i);
            else                    large_q.push_back((unsigned int)i);
        }
        while (!small_q.empty() && !large_q.empty()) {
            unsigned int s = small_q.back(); small_q.pop_back();
            unsigned int l = large_q.back(); large_q.pop_back();
            threshold[s] = p_scaled[s];
            alias[s] = l;
            p_scaled[l] = (p_scaled[l] + p_scaled[s]) - 1.0f;
            if (p_scaled[l] < 1.0f) small_q.push_back(l);
            else                    large_q.push_back(l);
        }
        while (!large_q.empty()) {
            unsigned int l = large_q.back(); large_q.pop_back();
            threshold[l] = 1.0f;
            alias[l] = l;
        }
        while (!small_q.empty()) {
            unsigned int s = small_q.back(); small_q.pop_back();
            threshold[s] = 1.0f;
            alias[s] = s;
        }

        // Allocate IMap+alias tables on EVERY device. Total cost: n_devices ×
        // ~12 MB (1M cells × (uint32 alias + float threshold + uint32 imap))
        // = trivial (e.g. 72 MB across 6 devices). Necessary on consumer cards
        // where P2P is disabled.
        d_alias_table_per_dev.assign(n_devices, nullptr);
        d_alias_threshold_per_dev.assign(n_devices, nullptr);
        d_imap_data_per_dev.assign(n_devices, nullptr);
        for (int d = 0; d < n_devices; d++) {
            check(cudaSetDevice(d), "set dev imap upload");
            check(cudaMalloc(&d_alias_table_per_dev[d],     n_cells * sizeof(unsigned int)), "alias_table malloc");
            check(cudaMalloc(&d_alias_threshold_per_dev[d], n_cells * sizeof(float)),        "alias_threshold malloc");
            check(cudaMalloc(&d_imap_data_per_dev[d],       n_cells * sizeof(unsigned int)), "imap_data malloc");
            check(cudaMemcpy(d_alias_table_per_dev[d],     alias.data(),     n_cells * sizeof(unsigned int), cudaMemcpyHostToDevice), "memcpy alias");
            check(cudaMemcpy(d_alias_threshold_per_dev[d], threshold.data(), n_cells * sizeof(float),        cudaMemcpyHostToDevice), "memcpy threshold");
            check(cudaMemcpy(d_imap_data_per_dev[d],       imap_host.data(), n_cells * sizeof(unsigned int), cudaMemcpyHostToDevice), "memcpy imap");
        }

        fprintf(stderr, "IMap loaded     : %s  (%ux%u, total_mass=%llu)\n",
            imap_path.c_str(), imap_res_loaded, imap_res_loaded,
            (unsigned long long)imap_total_mass);
        fprintf(stderr, "Mode            : Bitterli IS + inverse-probability weighting\n");
        if (min_iter_r_main > 0u || min_iter_g_main > 0u || min_iter_b_main > 0u) {
            fprintf(stderr, "Min escape iter : R>=%u  G>=%u  B>=%u (Aramant filtering)\n",
                min_iter_r_main, min_iter_g_main, min_iter_b_main);
        }
        fprintf(stderr, "===========================================\n");
    } else {
        fprintf(stderr, "Mode            : uniform on disk (no --imap given)\n");
        fprintf(stderr, "===========================================\n");
    }

    // -----------------------------------------------------------------------
    // §B7 — Resume-from-raw-histogram. If --resume-from PATH is set, load the
    // .bin file's histogram into d_hist[0], validate header against current
    // invocation, and set samples_done_at_start so the render loop only does
    // the delta to reach total_samples target.
    // Failsafe: any validation error aborts with E220 (use --allow-view-mismatch
    // to override the soft view-param check). Atomic write of the .bin guarantees
    // a half-written tmp file from a crashed prior run won't be picked up.
    // -----------------------------------------------------------------------
    unsigned long long samples_done_at_start = 0ULL;
    if (!resume_from_path.empty()) {
        FILE* rf = fopen(resume_from_path.c_str(), "rb");
        if (!rf) {
            fprintf(stderr, "[ERROR E220] Failed to open resume file %s\n", resume_from_path.c_str());
            return 1;
        }
        HistHeader hdr{};
        size_t hdr_read = fread(&hdr, 1, sizeof(HistHeader), rf);
        if (hdr_read != sizeof(HistHeader)) {
            fprintf(stderr, "[ERROR E220] Short header read from %s (%zu bytes; expected %zu)\n",
                resume_from_path.c_str(), hdr_read, sizeof(HistHeader));
            fclose(rf); return 1;
        }
        if (memcmp(hdr.magic, "BHRA", 4) != 0) {
            fprintf(stderr, "[ERROR E220] Invalid magic in %s (expected BHRA)\n", resume_from_path.c_str());
            fclose(rf); return 1;
        }
        if (hdr.version != 1u) {
            fprintf(stderr, "[ERROR E220] Unsupported version %u in %s\n",
                hdr.version, resume_from_path.c_str());
            fclose(rf); return 1;
        }
        if (hdr.width != (unsigned)width || hdr.height != (unsigned)height) {
            fprintf(stderr, "[ERROR E220] Resume dim mismatch: file=%ux%u, current=%dx%d\n",
                hdr.width, hdr.height, width, height);
            fclose(rf); return 1;
        }
        if (hdr.iter_r != max_iter_r || hdr.iter_g != max_iter_g || hdr.iter_b != max_iter_b) {
            fprintf(stderr, "[ERROR E220] Resume iter cap mismatch: file=%u/%u/%u, current=%u/%u/%u\n",
                hdr.iter_r, hdr.iter_g, hdr.iter_b, max_iter_r, max_iter_g, max_iter_b);
            fclose(rf); return 1;
        }
        if (hdr.hist_scale != (unsigned)HIST_SCALE) {
            fprintf(stderr, "[ERROR E220] Resume HIST_SCALE mismatch: file=%u, current=%llu\n",
                hdr.hist_scale, (unsigned long long)HIST_SCALE);
            fclose(rf); return 1;
        }
        unsigned int cur_imap_used = imap_path.empty() ? 0u : 1u;
        if (hdr.imap_used != cur_imap_used) {
            fprintf(stderr, "[ERROR E220] Resume IS-mode mismatch: file imap_used=%u, current=%u\n",
                hdr.imap_used, cur_imap_used);
            fclose(rf); return 1;
        }
        if (hdr.hist_count != (unsigned long long)hist_count) {
            fprintf(stderr, "[ERROR E220] Resume hist_count mismatch: file=%llu, current=%zu\n",
                (unsigned long long)hdr.hist_count, hist_count);
            fclose(rf); return 1;
        }
        if (!allow_view_mismatch) {
            const double eps = 1e-6;
            if (fabs(hdr.view_center_x - view_center_x) > eps ||
                fabs(hdr.view_center_y - view_center_y) > eps ||
                fabs(hdr.zoom - zoom) > eps ||
                fabs(hdr.rotation_deg - rotation_deg) > eps ||
                fabs(hdr.sample_center_x - sample_center_x) > eps ||
                fabs(hdr.sample_center_y - sample_center_y) > eps ||
                fabs(hdr.sample_radius - sample_radius) > eps) {
                fprintf(stderr, "[ERROR E220] Resume view-param mismatch (override with --allow-view-mismatch)\n");
                fprintf(stderr, "  file: cx=%.10f cy=%.10f zoom=%.4f rot=%.2f sc=(%.4f,%.4f) sr=%.4f\n",
                    hdr.view_center_x, hdr.view_center_y, hdr.zoom, hdr.rotation_deg,
                    hdr.sample_center_x, hdr.sample_center_y, hdr.sample_radius);
                fprintf(stderr, "  curr: cx=%.10f cy=%.10f zoom=%.4f rot=%.2f sc=(%.4f,%.4f) sr=%.4f\n",
                    view_center_x, view_center_y, zoom, rotation_deg,
                    sample_center_x, sample_center_y, sample_radius);
                fclose(rf); return 1;
            }
        }
        // Read histogram body
        std::vector<unsigned long long> host_hist(hist_count);
        size_t hist_read = fread(host_hist.data(), sizeof(unsigned long long), hist_count, rf);
        fclose(rf);
        if (hist_read != hist_count) {
            fprintf(stderr, "[ERROR E220] Short histogram read from %s (%zu of %zu cells)\n",
                resume_from_path.c_str(), hist_read, hist_count);
            return 1;
        }
        // Copy to device 0 (other devices stay at zero; they'll add fresh samples and merge in).
        check(cudaSetDevice(0), "set dev 0 resume");
        check(cudaMemcpy(d_hist[0], host_hist.data(), hist_bytes, cudaMemcpyHostToDevice),
            "memcpy resume hist");
        samples_done_at_start = hdr.samples_done;
        fprintf(stderr, "===========================================\n");
        fprintf(stderr, "Resumed from   : %s\n", resume_from_path.c_str());
        fprintf(stderr, "Loaded samples : %llu (target %llu, delta to render %llu)\n",
            (unsigned long long)samples_done_at_start,
            (unsigned long long)total_samples,
            (unsigned long long)(total_samples > samples_done_at_start
                ? total_samples - samples_done_at_start : 0));
        if (samples_done_at_start >= total_samples) {
            fprintf(stderr, "Already at >= target samples; will re-save final + bin and exit.\n");
        }
        fprintf(stderr, "===========================================\n");
    }

    // Track cumulative samples for progress reporting + the raw header's
    // samples_done field. Initialized to samples_done_at_start; the render
    // loop adds this-run progress on top.
    unsigned long long samples_done_total = samples_done_at_start;

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
            check(cudaMemset(d_hist[0] + pixels * 3, 0, 3 * sizeof(unsigned long long)),
                  "zero master max slots");
            compute_max_kernel<<<blocks_sum, 256>>>(d_hist[0], (unsigned int)pixels);
            check(cudaDeviceSynchronize(), "merge max sync");
        }

        // Read channel maxima for diagnostics + optional auto-trim derivation.
        // Note: hist values are scaled by HIST_SCALE; reported maxes here are raw
        // (scaled). Trim ratios are invariant.
        std::vector<unsigned long long> tail(3);
        check(cudaMemcpy(tail.data(), d_hist[0] + pixels * 3, 3 * sizeof(unsigned long long),
                         cudaMemcpyDeviceToHost), "memcpy tail");
        fprintf(stderr, "  channel maxes  R=%llu  G=%llu  B=%llu\n",
            (unsigned long long)tail[0], (unsigned long long)tail[1], (unsigned long long)tail[2]);

        Params local_P = P;
        if (target_r > 0.0 || target_g > 0.0 || target_b > 0.0) {
            if (target_r > 0.0 && tail[0] > 0ULL) local_P.trim_r = (float)(target_r / (double)tail[0]);
            if (target_g > 0.0 && tail[1] > 0ULL) local_P.trim_g = (float)(target_g / (double)tail[1]);
            if (target_b > 0.0 && tail[2] > 0ULL) local_P.trim_b = (float)(target_b / (double)tail[2]);
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

        // §B7: write raw uint64 histogram alongside the PNG if --output-raw is set.
        // Atomic write via tmp + rename. Failure logs E400 but does NOT abort the
        // render — VRAM histogram is the source of truth, .bin is the snapshot.
        if (!output_raw_path.empty()) {
            std::string raw_path;
            auto dot = path.rfind('.');
            if (dot != std::string::npos && dot > 0) {
                raw_path = path.substr(0, dot) + ".bin";
            } else {
                raw_path = path + ".bin";
            }
            HistHeader hdr{};
            memcpy(hdr.magic, "BHRA", 4);
            hdr.version = 1u;
            hdr.width = (unsigned)width;
            hdr.height = (unsigned)height;
            hdr.reserved0 = 0u;
            hdr.hist_count = (unsigned long long)hist_count;
            hdr.samples_done = samples_done_total;
            hdr.base_seed_used = base_seed;
            hdr.view_center_x = view_center_x;
            hdr.view_center_y = view_center_y;
            hdr.zoom = zoom;
            hdr.rotation_deg = rotation_deg;
            hdr.sample_center_x = sample_center_x;
            hdr.sample_center_y = sample_center_y;
            hdr.sample_radius = sample_radius;
            hdr.iter_r = max_iter_r;
            hdr.iter_g = max_iter_g;
            hdr.iter_b = max_iter_b;
            hdr.hist_scale = (unsigned)HIST_SCALE;
            hdr.imap_used = imap_path.empty() ? 0u : 1u;
            memset(hdr.imap_marker, 0, 4);
            hdr.reserved_pad0 = 0u;

            std::vector<unsigned long long> host_hist(hist_count);
            check(cudaMemcpy(host_hist.data(), d_hist[0], hist_bytes, cudaMemcpyDeviceToHost),
                "memcpy raw hist out");

            std::string tmp_path = raw_path + ".tmp";
            FILE* rf = fopen(tmp_path.c_str(), "wb");
            if (!rf) {
                fprintf(stderr, "  [WARN E400] failed to open %s for raw write; skipping (render continues)\n",
                    tmp_path.c_str());
            } else {
                bool raw_ok = (fwrite(&hdr, 1, sizeof(HistHeader), rf) == sizeof(HistHeader));
                if (raw_ok) {
                    raw_ok = (fwrite(host_hist.data(), sizeof(unsigned long long), hist_count, rf) == hist_count);
                }
                fclose(rf);
                if (raw_ok) {
                    remove(raw_path.c_str()); // Windows requires removal before rename
                    if (rename(tmp_path.c_str(), raw_path.c_str()) == 0) {
                        fprintf(stderr, "  -> %s  (%.2f GB raw, samples_done=%llu)\n",
                            raw_path.c_str(),
                            (double)(sizeof(HistHeader) + hist_bytes) / (1024.0*1024.0*1024.0),
                            (unsigned long long)samples_done_total);
                    } else {
                        fprintf(stderr, "  [WARN E400] rename(%s -> %s) failed; tmp remains, render continues\n",
                            tmp_path.c_str(), raw_path.c_str());
                    }
                } else {
                    fprintf(stderr, "  [WARN E400] raw fwrite failed; cleaning %s, render continues\n",
                        tmp_path.c_str());
                    remove(tmp_path.c_str());
                }
            }
        }

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

    // §B7: skip render loop entirely if resume already has target samples.
    // The final save below still runs, producing a fresh PNG/.bin from the
    // loaded histogram (useful if the user wants to re-tonemap with new trims).
    if (samples_done_total >= total_samples && total_samples > 0ULL) {
        fprintf(stderr, "Resume state already at target samples (%llu >= %llu); skipping render loop.\n",
            (unsigned long long)samples_done_total, (unsigned long long)total_samples);
        n_rounds = 0;
    }

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
                    d_hist[d], local_P,
                    d_alias_table_per_dev[d], d_alias_threshold_per_dev[d], d_imap_data_per_dev[d],
                    imap_total_mass, imap_res_loaded,
                    min_iter_r_main, min_iter_g_main, min_iter_b_main);
            }
        }

        // Sync all devices before reporting
        for (int d = 0; d < n_devices; d++) {
            check(cudaSetDevice(d), "set device sync");
            check(cudaStreamSynchronize(streams[d]), "stream sync");
        }

        // Progress — cumulative samples include samples_done_at_start (resume offset).
        double elapsed = now_seconds() - t_start;
        double frac    = (double)round_end / (double)launches_per_device;
        double eta     = (frac > 0) ? (elapsed / frac - elapsed) : 0.0;
        unsigned long long samples_this_run = round_end * samples_per_launch * (unsigned long long)n_devices;
        samples_done_total = samples_done_at_start + samples_this_run;
        fprintf(stderr, "  round %4llu / %llu  (%5.1f%%)  samples %llu (this-run %llu)  elapsed %7.1fs  ETA %7.1fs  rate %.1f M/s\n",
            (unsigned long long)(round + 1), (unsigned long long)n_rounds,
            frac * 100.0,
            (unsigned long long)samples_done_total,
            (unsigned long long)samples_this_run,
            elapsed, eta,
            (double)samples_this_run / elapsed / 1e6);

        // Checkpoint if requested (and not the very last round — final save handles that)
        // Two trigger paths can each fire: --checkpoint-every (uniform cadence) and
        // --checkpoint-schedule (explicit round-number list). Both can be active;
        // a single round only saves once even if both conditions match.
        bool should_checkpoint = false;
        if (checkpoint_every_rounds > 0 &&
            (round + 1) % (unsigned long long)checkpoint_every_rounds == 0) {
            should_checkpoint = true;
        }
        // Schedule check: advance index past any entries the loop has already passed
        // (handles out-of-order entries defensively, plus resume-from edge cases where
        // the schedule list may contain rounds already completed in a prior invocation).
        while (checkpoint_schedule_idx < checkpoint_schedule.size() &&
               checkpoint_schedule[checkpoint_schedule_idx] < (round + 1)) {
            checkpoint_schedule_idx++;
        }
        if (checkpoint_schedule_idx < checkpoint_schedule.size() &&
            checkpoint_schedule[checkpoint_schedule_idx] == (round + 1)) {
            should_checkpoint = true;
            checkpoint_schedule_idx++;
        }

        if (should_checkpoint && (round + 1) < n_rounds) {
            std::string path = cp_path(round + 1);
            fprintf(stderr, "  checkpoint at round %llu (cumulative samples %llu)...\n",
                (unsigned long long)(round + 1), (unsigned long long)samples_done_total);
            double t_cp = now_seconds();
            save_image(path);
            fprintf(stderr, "  checkpoint took %.1fs\n", now_seconds() - t_cp);
        }

        // §B7: early-break if cumulative samples have reached target. Avoids
        // overshooting on resume where launches_per_device was sized for the full
        // target_samples; we may have extra rounds queued that aren't needed.
        if (samples_done_total >= total_samples) {
            fprintf(stderr, "  reached target %llu samples (cumulative %llu); breaking out of render loop\n",
                (unsigned long long)total_samples, (unsigned long long)samples_done_total);
            break;
        }

        // SIGUSR1 graceful-terminate (cloud watchdog wallclock-cap path).
        // The handler set this flag asynchronously; the round just synced so it
        // is safe to break, run the final save with whatever samples we have,
        // and exit 0. Output is .bin + .png at the partial-but-clean state.
        if (g_terminate_requested.load()) {
            fprintf(stderr, "  SIGUSR1 received; graceful-terminate at round %llu (cumulative %llu samples)\n",
                (unsigned long long)(round + 1), (unsigned long long)samples_done_total);
            break;
        }
    }
    double t_compute = now_seconds() - t_start;
    unsigned long long this_run_samples = (samples_done_total > samples_done_at_start)
        ? (samples_done_total - samples_done_at_start) : 0ULL;
    if (t_compute > 0.001) {
        fprintf(stderr, "Compute total   : %.2f s  (%.1f M samples / s aggregate, %llu this-run, %llu cumulative)\n",
            t_compute,
            (double)this_run_samples / t_compute / 1e6,
            (unsigned long long)this_run_samples,
            (unsigned long long)samples_done_total);
    } else {
        fprintf(stderr, "Compute total   : <0.001s (loop skipped, cumulative %llu samples from resume)\n",
            (unsigned long long)samples_done_total);
    }

    // Final save
    fprintf(stderr, "Final save...\n");
    double t_final = now_seconds();
    if (!save_image(output_path)) {
        return 2;
    }
    fprintf(stderr, "Final save took %.2f s\n", now_seconds() - t_final);

    // Cleanup
    if (d_staging) cudaFree(d_staging);
    for (int d = 0; d < (int)d_alias_table_per_dev.size(); d++) {
        if (d_alias_table_per_dev[d])     { cudaSetDevice(d); cudaFree(d_alias_table_per_dev[d]); }
        if (d_alias_threshold_per_dev[d]) { cudaSetDevice(d); cudaFree(d_alias_threshold_per_dev[d]); }
        if (d_imap_data_per_dev[d])       { cudaSetDevice(d); cudaFree(d_imap_data_per_dev[d]); }
    }
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
