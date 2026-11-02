// Internal helpers shared by the engine core. Not part of the public API.
#pragma once

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace ro {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 2.0 * kPi;

// The package builds with -ffast-math, so std::isfinite / x != x may be folded
// away by the optimiser. These bit tests cannot be.
inline bool isFiniteF(float x) {
    return (std::bit_cast<uint32_t>(x) & 0x7f800000u) != 0x7f800000u;
}
inline bool isFiniteD(double x) {
    return (std::bit_cast<uint64_t>(x) & 0x7ff0000000000000ull) != 0x7ff0000000000000ull;
}

template <class T>
inline T clampv(T v, T lo, T hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Replaces NaN/Inf with 0 and clamps to +-limit.
inline float sanitize(float x, float limit) {
    if (!isFiniteF(x)) return 0.0f;
    return clampv(x, -limit, limit);
}

inline float ampToDb(float a) { return a > 1e-6f ? 20.0f * std::log10(a) : -120.0f; }
inline float powToDb(float p) { return p > 1e-12f ? 10.0f * std::log10(p) : -120.0f; }
inline float dbToAmp(float db) { return std::pow(10.0f, db * 0.05f); }

// Linear ramp that lands exactly on its target (so 0.0f / 1.0f are reached
// bit-exactly, which the bit-exact dry paths rely on).
struct LinearRamp {
    float cur = 0.0f;
    float target = 0.0f;
    float inc = 0.0f;
    int remaining = 0;
    int length = 64;

    void setLength(int n) { length = n < 1 ? 1 : n; }
    void snap(float v) { cur = target = v; inc = 0.0f; remaining = 0; }
    void set(float t) {
        if (t == target) return;
        target = t;
        remaining = length;
        inc = (target - cur) / static_cast<float>(length);
    }
    float next() {
        if (remaining > 0) {
            if (--remaining == 0) cur = target;
            else cur += inc;
        }
        return cur;
    }
    bool settled() const { return remaining == 0; }
};

// Small deterministic PRNG (xorshift32) for the simulator.
struct Rng {
    uint32_t s = 0x12345678u;
    explicit Rng(uint32_t seed = 1) { reseed(seed); }
    void reseed(uint32_t seed) { s = seed ? seed * 2654435761u + 0x9E3779B9u : 0x12345678u; if (!s) s = 1; next(); next(); }
    uint32_t next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
    float uniform() { return static_cast<float>(next() >> 8) * (1.0f / 16777216.0f); }       // [0,1)
    float range(float a, float b) { return a + (b - a) * uniform(); }
    float bipolar() { return 2.0f * uniform() - 1.0f; }                                      // [-1,1)
};

}  // namespace ro
