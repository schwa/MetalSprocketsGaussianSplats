#pragma once

// Math primitives for the PointSplat renderer (RFC 0003), ported from the
// Gaussian Point Splatting reference implementation (Rijsdijk et al. 2026,
// src/core/random/). Written as C-compatible static inline functions so the
// exact same code runs in Metal kernels and in Swift unit tests.

#ifdef __METAL_VERSION__
#include <metal_stdlib>
typedef float2 GPSFloat2;
typedef uint2 GPSUInt2;
#define GPS_THREAD thread
#define GPS_FMA(a, b, c) metal::fma((a), (b), (c))
#define GPS_LOG(x) metal::log(x)
#define GPS_SQRT(x) metal::sqrt(x)
#define GPS_COS(x) metal::cos(x)
#define GPS_SIN(x) metal::sin(x)
#define GPS_FMAX(a, b) metal::fmax((a), (b))
#define GPS_FMIN(a, b) metal::fmin((a), (b))
#define GPS_FLOOR(x) metal::floor(x)
#define GPS_RINT(x) metal::rint(x)
#else
#include <simd/simd.h>
#include <math.h>
#include <stdint.h>
typedef simd_float2 GPSFloat2;
typedef simd_uint2 GPSUInt2;
#define GPS_THREAD
#define GPS_FMA(a, b, c) fmaf((a), (b), (c))
#define GPS_LOG(x) logf(x)
#define GPS_SQRT(x) sqrtf(x)
#define GPS_COS(x) cosf(x)
#define GPS_SIN(x) sinf(x)
#define GPS_FMAX(a, b) fmaxf((a), (b))
#define GPS_FMIN(a, b) fminf((a), (b))
#define GPS_FLOOR(x) floorf(x)
#define GPS_RINT(x) rintf(x)
#endif

#define GPS_PI 3.14159265358979323846f
// Li2(1) = pi^2 / 6
#define GPS_LI2_MAX 1.6449340668482264f

// MARK: - Dilogarithm

// Degree-7 fit of Li2(x) - (1-x)ln(1-x); coefficients from the reference
// implementation. Max abs error ~7.3e-5 on [0, 1].
static inline float gps_dilog(float x) {
    float y = -6.09201442e-01f;
    y = GPS_FMA(y, x, 1.79126616e+00f);
    y = GPS_FMA(y, x, -2.14953223e+00f);
    y = GPS_FMA(y, x, 1.26304372e+00f);
    y = GPS_FMA(y, x, -4.59069895e-01f);
    y = GPS_FMA(y, x, -1.87417414e-01f);
    y = GPS_FMA(y, x, 1.99603130e+00f);
    y = GPS_FMA(y, x, 5.99669467e-05f);
    float s = 1.0f - x;
    if (s > 0.0f) {
        y += s * GPS_LOG(GPS_FMAX(s, 1e-37f));
    }
    return y;
}

// Degree-10 minimax fit of the inverse dilogarithm over x/Li2(1).
// Max abs error ~7.1e-5.
static inline float gps_inv_dilog(float x) {
    float t = GPS_FMIN(x / GPS_LI2_MAX, 1.0f);
    float y = -1.27463503e+01f;
    y = GPS_FMA(y, t, 5.88993459e+01f);
    y = GPS_FMA(y, t, -1.16025780e+02f);
    y = GPS_FMA(y, t, 1.26945827e+02f);
    y = GPS_FMA(y, t, -8.43108826e+01f);
    y = GPS_FMA(y, t, 3.48799862e+01f);
    y = GPS_FMA(y, t, -8.89606235e+00f);
    y = GPS_FMA(y, t, 1.38640936e+00f);
    y = GPS_FMA(y, t, -7.80640876e-01f);
    y = GPS_FMA(y, t, 1.64841888e+00f);
    y = GPS_FMA(y, t, -2.82836687e-05f);
    return y;
}

// MARK: - RNG

static inline unsigned int gps_hash32(unsigned int x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

// Per-(index, frame) seed decorrelation.
static inline GPSUInt2 gps_make_seed(unsigned int idx, unsigned int frame) {
    const unsigned int C1 = 0x9E3779B9u;
    const unsigned int C2 = 0xBB67AE85u;
    const unsigned int C3 = 0x3C6EF372u;
    const unsigned int C4 = 0xA54FF53Au;
    unsigned int h1 = gps_hash32(idx ^ (frame * C1));
    unsigned int h2 = gps_hash32((idx * C2) ^ frame);
    h1 ^= (h2 * C3);
    h2 ^= (h1 * C4);
    GPSUInt2 result = { h1, h2 };
    return result;
}

static inline GPSUInt2 gps_pcg2d_uint(GPSUInt2 seed) {
    seed.x = seed.x * 1664525u + 1013904223u;
    seed.y = seed.y * 1664525u + 1013904223u;
    seed.x += seed.y * 1664525u;
    seed.y += seed.x * 1664525u;
    seed.x ^= seed.x >> 16;
    seed.y ^= seed.y >> 16;
    seed.x += seed.y * 1664525u;
    seed.y += seed.x * 1664525u;
    seed.x ^= seed.x >> 16;
    seed.y ^= seed.y >> 16;
    return seed;
}

#define GPS_RECIPROCAL_2E32 2.3283064365387e-10f

// Advances the seed and returns two uniform floats in [0, 1).
static inline GPSFloat2 gps_pcg2d(GPS_THREAD GPSUInt2 *seed) {
    *seed = gps_pcg2d_uint(*seed);
    GPSFloat2 result = { (float)seed->x * GPS_RECIPROCAL_2E32, (float)seed->y * GPS_RECIPROCAL_2E32 };
    return result;
}

// MARK: - Sampling

static inline GPSFloat2 gps_box_muller(float u1, float u2) {
    float clamped = GPS_FMIN(GPS_FMAX(u1, 1e-37f), 1.0f);
    float r = GPS_SQRT(GPS_FMAX(-2.0f * GPS_LOG(clamped), 0.0f));
    float theta = 2.0f * GPS_PI * u2;
    GPSFloat2 result = { r * GPS_COS(theta), r * GPS_SIN(theta) };
    return result;
}

// Box-Muller with the opacity-corrected radial density of RFC 0003
// (paper Sec. 3.4): inverse-CDF sampling via Li2 / Li2^-1.
static inline GPSFloat2 gps_corrected_box_muller(float u1, float u2, float alpha) {
    float a = 1.0f / GPS_FMAX(alpha, 1e-37f) * gps_inv_dilog((1.0f - u1) * gps_dilog(alpha));
    a = GPS_FMIN(GPS_FMAX(a, 1e-37f), 1.0f);
    float r = GPS_SQRT(GPS_FMAX(-2.0f * GPS_LOG(a), 0.0f));
    float theta = 2.0f * GPS_PI * u2;
    GPSFloat2 result = { r * GPS_COS(theta), r * GPS_SIN(theta) };
    return result;
}

// Poisson sampler using Giles' Q~_N3 normal asymptotic approximation.
// Giles, M.B. (2016), Algorithm 955, ACM TOMS 42(1). Accurate for the
// lambdas we care about (large Gaussians); small lambdas still have the
// right mean, which is what matters in aggregate.
static inline unsigned int gps_poisson(GPS_THREAD GPSUInt2 *seed, float lambda) {
    GPSFloat2 u = gps_pcg2d(seed);
    float w = gps_box_muller(u.x, u.y).x;
    float w2 = w * w;
    float w3 = w2 * w;
    float w4 = w2 * w2;

    float s = GPS_SQRT(lambda);
    float invS = 1.0f / s;
    float invL = 1.0f / lambda;

    float kf = lambda + s * w + (w2 - 1.0f) / 6.0f;
    kf += invS * (-(1.0f / 36.0f) * w - (1.0f / 72.0f) * w3);
    kf += invL * (-(8.0f / 405.0f) + (7.0f / 810.0f) * w2 + (1.0f / 270.0f) * w4);

    float ki = GPS_RINT(kf);
    return ki > 0.0f ? (unsigned int)ki : 0u;
}

// Rounds x up or down stochastically so the expectation equals x.
static inline int gps_stochastic_round(float x, float u) {
    int base = (int)GPS_FLOOR(x);
    float frac = x - (float)base;
    int rounded = (u < frac) ? (base + 1) : base;
    return rounded > 0 ? rounded : 0;
}
