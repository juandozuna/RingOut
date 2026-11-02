// Double-precision biquads (TDF-II) and RBJ-cookbook designs. Double state is
// used because Q=60 notches at low frequency put poles very close to z=1.
#pragma once

#include "RtCommon.hpp"

namespace ro {

struct BiquadCoeffs {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

inline BiquadCoeffs designPeaking(double fs, double f, double q, double gainDb) {
    f = clampv(f, 10.0, fs * 0.49);
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = kTwoPi * f / fs;
    const double cw = std::cos(w0), alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha / A;
    BiquadCoeffs c;
    c.b0 = (1.0 + alpha * A) / a0;
    c.b1 = (-2.0 * cw) / a0;
    c.b2 = (1.0 - alpha * A) / a0;
    c.a1 = c.b1;
    c.a2 = (1.0 - alpha / A) / a0;
    return c;
}

inline BiquadCoeffs designHighpass(double fs, double f, double q) {
    const double w0 = kTwoPi * f / fs;
    const double cw = std::cos(w0), alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    BiquadCoeffs c;
    c.b0 = (1.0 + cw) * 0.5 / a0;
    c.b1 = -(1.0 + cw) / a0;
    c.b2 = c.b0;
    c.a1 = -2.0 * cw / a0;
    c.a2 = (1.0 - alpha) / a0;
    return c;
}

inline BiquadCoeffs designLowpass(double fs, double f, double q) {
    const double w0 = kTwoPi * clampv(f, 10.0, fs * 0.49) / fs;
    const double cw = std::cos(w0), alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    BiquadCoeffs c;
    c.b0 = (1.0 - cw) * 0.5 / a0;
    c.b1 = (1.0 - cw) / a0;
    c.b2 = c.b0;
    c.a1 = -2.0 * cw / a0;
    c.a2 = (1.0 - alpha) / a0;
    return c;
}

// Band-pass with 0 dB peak gain at f.
inline BiquadCoeffs designBandpass(double fs, double f, double q) {
    const double w0 = kTwoPi * f / fs;
    const double cw = std::cos(w0), alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    BiquadCoeffs c;
    c.b0 = alpha / a0;
    c.b1 = 0.0;
    c.b2 = -alpha / a0;
    c.a1 = -2.0 * cw / a0;
    c.a2 = (1.0 - alpha) / a0;
    return c;
}

struct Biquad {
    BiquadCoeffs c;
    double z1 = 0, z2 = 0;
    void reset() { z1 = z2 = 0; }
    inline double tick(double x) {
        const double y = c.b0 * x + z1;
        z1 = c.b1 * x - c.a1 * y + z2;
        z2 = c.b2 * x - c.a2 * y;
        return y;
    }
    bool stateFinite() const { return isFiniteD(z1) && isFiniteD(z2); }
};

// Biquad whose coefficients glide linearly to a new target over N samples.
// Linear interpolation of (a1, a2) stays inside the stability triangle because
// that region is convex.
struct SmoothBiquad {
    BiquadCoeffs cur, target, inc;
    int remaining = 0;
    double z1 = 0, z2 = 0;

    void reset() { z1 = z2 = 0; }
    void snap(const BiquadCoeffs& c) { cur = target = c; remaining = 0; }
    void setTarget(const BiquadCoeffs& c, int steps = 64) {
        target = c;
        remaining = steps;
        const double k = 1.0 / steps;
        inc.b0 = (c.b0 - cur.b0) * k;
        inc.b1 = (c.b1 - cur.b1) * k;
        inc.b2 = (c.b2 - cur.b2) * k;
        inc.a1 = (c.a1 - cur.a1) * k;
        inc.a2 = (c.a2 - cur.a2) * k;
    }
    inline double tick(double x) {
        if (remaining > 0) {
            if (--remaining == 0) {
                cur = target;
            } else {
                cur.b0 += inc.b0; cur.b1 += inc.b1; cur.b2 += inc.b2;
                cur.a1 += inc.a1; cur.a2 += inc.a2;
            }
        }
        const double y = cur.b0 * x + z1;
        z1 = cur.b1 * x - cur.a1 * y + z2;
        z2 = cur.b2 * x - cur.a2 * y;
        return y;
    }
    bool stateFinite() const { return isFiniteD(z1) && isFiniteD(z2); }
};

}  // namespace ro
