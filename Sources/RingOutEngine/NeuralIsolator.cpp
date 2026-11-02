// NeuralIsolator: streaming forward pass of the gated TCN in ml/model.py.
//
// Per sub-block of n <= kBlock frames (all buffers channel-major, stride kBlock):
//   h      = W_in x + b_in
//   per layer: D = h delayed by d (from the layer's ring buffer), then
//          z = [W0 | W1] [D; h] + b          one 2C x 2C GEMM
//          g = tanh(z_a) * sigmoid(z_b)
//          [h; s] += [Wr; Ws] g + [br; bs]   one 2C x C GEMM
//   y      = x + w_o . relu(W_h relu(s) + b_h) + b_o
// Weights are repacked at compile time into [in][out] order so the GEMM
// micro-kernel reads a contiguous run of output weights per input row.
//
// This is the only translation unit that includes NeuralWeights.inc.

#include "NeuralIsolator.hpp"

#include <cstring>

#include "NeuralWeights.inc"
#include "include/ringout_engine.h"
#include "RtCommon.hpp"

namespace ro {

namespace {

namespace w = ro::nnw;

constexpr int C = w::kChannels;
constexpr int L = w::kLayers;
constexpr int S = NeuralIsolator::kBlock;  // row stride of every block buffer
constexpr int kTileO = 8, kTileT = 8;      // GEMM register tile (outputs x frames)

static_assert(L <= 16, "ringOff_/ringPos_ hold at most 16 layers");
static_assert(C % kTileO == 0 && S % kTileT == 0);
static_assert(sizeof(w::kDilW0) == sizeof(float) * L * 2 * C * C);
static_assert(sizeof(w::kResW) == sizeof(float) * L * C * C);
static_assert(sizeof(w::kHeadW) == sizeof(float) * C * C);

constexpr float kGuardLimit = 4.0f;   // |y| above this trips the guard
constexpr float kOutputLimit = 2.0f;  // final clamp
constexpr double kFadeS = 0.05;       // correction fade-in after a trip
constexpr float kActivityFull = 0.5f; // correction/input amplitude ratio for activity 1
constexpr double kActivityS = 0.1;    // activity smoothing
constexpr double kInputFloor = 1e-6;  // per-sample energy floor (-60 dBFS)
// Silence gate. Room noise below -60 dBFS is never a ring, so there the
// correction is held off and the stage is bit-exact (no residual offset from
// the network's biases). A per-sample peak envelope drives it, so samples
// ahead of an onset in the same block stay untouched; the gate opens in ~5 ms.
// (Gating on detector confidence was tried and dropped: the detector is
// deliberately blind to held sung notes, which cost ~10 dB of singing margin.)
constexpr float kGateSilence = 1e-3f;  // -60 dBFS peak
constexpr double kEnvReleaseS = 0.05, kGateAttackS = 0.005, kGateReleaseS = 0.05;

struct Packed {
    float dil[L][2 * C][2 * C];  // [l][in][out]; in [0,C) multiplies h[t-d], [C,2C) h[t]
    float dilB[L][2 * C];
    float rs[L][C][2 * C];       // [l][in][out]; out [0,C) residual, [C,2C) skip
    float rsB[L][2 * C];
    float head[C][C];            // [in][out]
};

constexpr Packed pack() {
    Packed p{};
    for (int l = 0; l < L; ++l) {
        for (int o = 0; o < 2 * C; ++o) {
            for (int i = 0; i < C; ++i) {
                p.dil[l][i][o] = w::kDilW0[(l * 2 * C + o) * C + i];
                p.dil[l][C + i][o] = w::kDilW1[(l * 2 * C + o) * C + i];
            }
            p.dilB[l][o] = w::kDilB[l * 2 * C + o];
        }
        for (int o = 0; o < C; ++o) {
            for (int i = 0; i < C; ++i) {
                p.rs[l][i][o] = w::kResW[(l * C + o) * C + i];
                p.rs[l][i][C + o] = w::kSkipW[(l * C + o) * C + i];
            }
            p.rsB[l][o] = w::kResB[l * C + o];
            p.rsB[l][C + o] = w::kSkipB[l * C + o];
        }
    }
    for (int o = 0; o < C; ++o)
        for (int i = 0; i < C; ++i) p.head[i][o] = w::kHeadW[o * C + i];
    return p;
}

alignas(64) constexpr Packed kW = pack();

// 4-lane vectors via the clang vector extension (NEON on arm64). Plain
// scalar loops here get SLP-vectorised into 2-lane code with spills, so the
// micro-kernel spells the vectors out.
using f4 = float __attribute__((ext_vector_type(4)));
inline f4 load4(const float* p) {
    f4 v;
    std::memcpy(&v, p, sizeof v);
    return v;
}
inline void store4(float* p, f4 v) { std::memcpy(p, &v, sizeof v); }

// Z[o][t] = (Accumulate ? Z[o][t] : 0) + b[o] + sum_k W[k][o] X[k][t], for
// t < nt (a multiple of kTileT). W is [K][O]; X and Z have row stride S.
// An 8 (outputs) x 8 (frames) accumulator tile = 16 vector registers; each
// input row costs 2 weight loads + 2 activation loads for 16 lane-indexed FMAs.
template <int K, int O, bool Accumulate>
inline void gemm(const float* __restrict W, const float* __restrict b, const float* __restrict X,
                 float* __restrict Z, int nt) {
    static_assert(kTileO == 8 && kTileT == 8);
    for (int o0 = 0; o0 < O; o0 += kTileO) {
        const f4 b0 = load4(b + o0), b1 = load4(b + o0 + 4);
        for (int t0 = 0; t0 < nt; t0 += kTileT) {
            f4 lo[kTileO], hi[kTileO];  // frames t0..t0+3, t0+4..t0+7
            for (int oo = 0; oo < kTileO; ++oo) {
                const float bo = oo < 4 ? b0[oo] : b1[oo - 4];
                lo[oo] = bo;
                hi[oo] = bo;
                if (Accumulate) {
                    lo[oo] += load4(Z + (o0 + oo) * S + t0);
                    hi[oo] += load4(Z + (o0 + oo) * S + t0 + 4);
                }
            }
            for (int k = 0; k < K; ++k) {
                const f4 w0 = load4(W + k * O + o0), w1 = load4(W + k * O + o0 + 4);
                const f4 x0 = load4(X + k * S + t0), x1 = load4(X + k * S + t0 + 4);
                for (int oo = 0; oo < kTileO; ++oo) {
                    const float wv = oo < 4 ? w0[oo] : w1[oo - 4];
                    lo[oo] += wv * x0;
                    hi[oo] += wv * x1;
                }
            }
            for (int oo = 0; oo < kTileO; ++oo) {
                store4(Z + (o0 + oo) * S + t0, lo[oo]);
                store4(Z + (o0 + oo) * S + t0 + 4, hi[oo]);
            }
        }
    }
}

// Rational tanh (Eigen's float approximation, a few ulp on [-7.9, 7.9] and
// saturated outside). Branch free so the gate loop vectorises.
inline float fastTanh(float x) {
    x = clampv(x, -7.90531110763549805f, 7.90531110763549805f);
    const float x2 = x * x;
    float p = -2.76076847742355e-16f;
    p = p * x2 + 2.00018790482477e-13f;
    p = p * x2 - 8.60467152213735e-11f;
    p = p * x2 + 5.12229709037114e-08f;
    p = p * x2 + 1.48572235717979e-05f;
    p = p * x2 + 6.37261928875436e-04f;
    p = p * x2 + 4.89352455891786e-03f;
    p = p * x;
    float q = 1.19825839466702e-06f;
    q = q * x2 + 1.18534705686654e-04f;
    q = q * x2 + 2.26843463243900e-03f;
    q = q * x2 + 4.89352518554385e-03f;
    return p / q;
}

// dst[0..len) = ring[pos..] read circularly (ring length d).
inline void readWrapped(float* dst, const float* ring, int d, int pos, int len) {
    const int first = std::min(len, d - pos);
    std::memcpy(dst, ring + pos, sizeof(float) * first);
    if (len > first) std::memcpy(dst + first, ring, sizeof(float) * (len - first));
}

inline void writeWrapped(float* ring, const float* src, int d, int pos, int len) {
    const int first = std::min(len, d - pos);
    std::memcpy(ring + pos, src, sizeof(float) * first);
    if (len > first) std::memcpy(ring, src + first, sizeof(float) * (len - first));
}

}  // namespace

bool NeuralIsolator::placeholderWeights() { return std::strncmp(w::kModelId, "random-init", 11) == 0; }
const char* NeuralIsolator::modelId() { return w::kModelId; }

bool NeuralIsolator::prepare(double fs, int /*maxFrames*/) {
    fs_ = fs;
    usable_ = std::fabs(fs - kModelRate) < 0.5;
    int total = 0;
    for (int l = 0; l < L; ++l) {
        ringOff_[l] = total;
        total += C * w::kDilations[l];
    }
    ring_.assign(total, 0.0f);
    act_.assign(3 * C * S, 0.0f);
    z_.assign(2 * C * S, 0.0f);
    g_.assign(C * S, 0.0f);
    u_.assign(C * S, 0.0f);
    y_.assign(S, 0.0f);
    fadeLen_ = std::max(1, static_cast<int>(std::lround(kFadeS * fs)));
    gateAttack_ = static_cast<float>(1.0 - std::exp(-1.0 / (kGateAttackS * fs)));
    gateRelease_ = static_cast<float>(1.0 - std::exp(-1.0 / (kGateReleaseS * fs)));
    envRelease_ = static_cast<float>(std::exp(-1.0 / (kEnvReleaseS * fs)));
    reset();
    return usable_;
}

void NeuralIsolator::clearHistory() {
    std::fill(ring_.begin(), ring_.end(), 0.0f);
    for (int l = 0; l < L; ++l) ringPos_[l] = 0;
}

void NeuralIsolator::reset() {
    clearHistory();
    fadePos_ = fadeLen_;
    gate_ = env_ = 0.0f;
    ungated_ = false;
    eCorr_ = eIn_ = 0;
    activity_ = 0.0f;
}

void NeuralIsolator::process(float* x, int n, const IsolatorSide& side) {
    if (!usable_ || ring_.empty()) return;
    ungated_ = side.side == nullptr;  // self-test: plain network output
    for (int done = 0; done < n;) {
        const int m = std::min(S, n - done);
        processBlock(x + done, m);
        done += m;
    }
}

void NeuralIsolator::processBlock(float* x, int n) {
    // Padded columns [n, nt) carry finite junk; every op except the ring
    // update is per column, so they never reach the real outputs.
    const int nt = (n + kTileT - 1) / kTileT * kTileT;
    float* const D = act_.data();
    float* const H = D + C * S;
    float* const Sk = H + C * S;
    float* const Z = z_.data();
    float* const G = g_.data();
    float* const U = u_.data();
    float* const Y = y_.data();

    // Input layer; skip sum starts at zero.
    for (int c = 0; c < C; ++c) {
        const float wc = w::kInW[c], bc = w::kInB[c];
        float* h = H + c * S;
        for (int t = 0; t < n; ++t) h[t] = wc * x[t] + bc;
        for (int t = n; t < nt; ++t) h[t] = bc;
    }
    std::memset(Sk, 0, sizeof(float) * C * S);

    for (int l = 0; l < L; ++l) {
        // Delayed taps from the ring (which keeps the last d hidden vectors,
        // oldest at ringPos_), then push this block's h into it.
        const int d = w::kDilations[l];
        const int pos = ringPos_[l];
        float* ring = ring_.data() + ringOff_[l];
        for (int c = 0; c < C; ++c) {
            float* r = ring + c * d;
            float* dc = D + c * S;
            const float* hc = H + c * S;
            if (d >= n) {
                readWrapped(dc, r, d, pos, n);
                writeWrapped(r, hc, d, pos, n);
            } else {
                readWrapped(dc, r, d, pos, d);
                std::memcpy(dc + d, hc, sizeof(float) * (n - d));
                std::memcpy(r, hc + n - d, sizeof(float) * d);
            }
        }
        ringPos_[l] = d >= n ? (pos + n) % d : 0;

        gemm<2 * C, 2 * C, false>(&kW.dil[l][0][0], kW.dilB[l], D, Z, nt);

        // Gate: tanh(a) * sigmoid(b), sigmoid(b) = 0.5 + 0.5 tanh(b / 2).
        for (int c = 0; c < C; ++c) {
            const float* za = Z + c * S;
            const float* zb = Z + (C + c) * S;
            float* gc = G + c * S;
            for (int t = 0; t < nt; ++t) gc[t] = fastTanh(za[t]) * (0.5f + 0.5f * fastTanh(0.5f * zb[t]));
        }

        // Residual into h, skip into s (rows H..Sk are contiguous).
        gemm<C, 2 * C, true>(&kW.rs[l][0][0], kW.rsB[l], G, H, nt);
    }

    // Head.
    for (int i = 0; i < C * S; ++i) Sk[i] = std::max(Sk[i], 0.0f);
    gemm<C, C, false>(&kW.head[0][0], w::kHeadB, Sk, U, nt);
    for (int t = 0; t < nt; ++t) Y[t] = w::kOutB[0];
    for (int c = 0; c < C; ++c) {
        const float wc = w::kOutW[c];
        const float* uc = U + c * S;
        for (int t = 0; t < nt; ++t) Y[t] += wc * std::max(uc[t], 0.0f);
    }

    // Guard: a non-finite or out-of-range output (or a non-finite skip sum,
    // which can hide NaNs behind the ReLUs) resets the history and passes
    // this block through; the correction then fades back in.
    float sSum = 0.0f;
    for (int i = 0; i < C * S; ++i) sSum += Sk[i];
    bool bad = !isFiniteF(sSum);
    for (int t = 0; t < n; ++t) {
        const float v = x[t] + Y[t];
        if (!isFiniteF(v) || std::fabs(v) > kGuardLimit) bad = true;
    }
    if (bad) {
        clearHistory();
        fadePos_ = 0;
    }

    double eCorr = 0, eIn = 0;
    for (int t = 0; t < n; ++t) {
        const float xi = x[t];
        float corr = 0.0f;
        if (!bad) {
            env_ = std::max(std::fabs(xi), env_ * envRelease_);
            const float target = ungated_ || env_ > kGateSilence ? 1.0f : 0.0f;
            gate_ += (target - gate_) * (target > gate_ ? gateAttack_ : gateRelease_);
            if (gate_ < 1e-6f) gate_ = 0.0f;
            corr = Y[t] * (ungated_ ? 1.0f : gate_);
            if (fadePos_ < fadeLen_) corr *= static_cast<float>(++fadePos_) / static_cast<float>(fadeLen_);
        }
        const float yi = clampv(xi + corr, -kOutputLimit, kOutputLimit);
        const double dc = static_cast<double>(yi) - xi;
        eCorr += dc * dc;
        eIn += static_cast<double>(xi) * xi;
        x[t] = yi;
    }

    const double a = std::exp(-n / (kActivityS * fs_));
    eCorr_ = a * eCorr_ + (1 - a) * eCorr;
    eIn_ = a * eIn_ + (1 - a) * (eIn + kInputFloor * n);
    const double ratio = eCorr_ / eIn_;
    activity_ = isFiniteD(ratio) ? clampv(static_cast<float>(std::sqrt(ratio)) / kActivityFull, 0.0f, 1.0f) : 0.0f;
}

}  // namespace ro

// ---- C API ----------------------------------------------------------------

namespace {

// ml/export.py parity_input(): two sines, a growing 2.5 kHz ring and 31-bit
// LCG noise, in double precision, each sample rounded to float.
void parityInput(float* out, int n) {
    int64_t state = 12345;
    for (int i = 0; i < n; ++i) {
        state = (1103515245LL * state + 12345LL) & 0x7FFFFFFFLL;
        const double noise = (static_cast<double>(state) / 2147483647.0) * 2.0 - 1.0;
        const double t = i / 48000.0;
        const double ring = std::min(1.0, static_cast<double>(i) / n * 2.0) * 0.4 * std::sin(2 * ro::kPi * 2500.0 * t);
        const double v = 0.2 * std::sin(2 * ro::kPi * 220.0 * t) + 0.1 * std::sin(2 * ro::kPi * 1210.0 * t) + ring + 0.05 * noise;
        out[i] = static_cast<float>(v);
    }
}

}  // namespace

extern "C" {

float ro_neural_selftest(void) {
    constexpr int n = ro::nnw::kParityLength;
    std::vector<float> x(n);
    parityInput(x.data(), n);
    ro::NeuralIsolator iso;
    if (!iso.prepare(ro::NeuralIsolator::kModelRate, RO_MAX_FRAMES)) return 1.0e9f;
    // Irregular block sizes, including 1, sizes around and above kBlock.
    constexpr int kSizes[] = {1, 31, 32, 64, 7, 1000, 63, 65, 128, 3, 500};
    int pos = 0;
    for (int k = 0; pos < n; ++k) {
        const int m = std::min(n - pos, kSizes[k % (sizeof(kSizes) / sizeof(kSizes[0]))]);
        iso.process(x.data() + pos, m, ro::IsolatorSide{});
        pos += m;
    }
    float err = 0.0f;
    for (int i = 0; i < n; ++i) {
        const float e = std::fabs(x[i] - ro::nnw::kParityOutput[i]);
        if (!ro::isFiniteF(e)) return 1.0e9f;
        err = std::max(err, e);
    }
    return err;
}

const char* ro_neural_model_id(void) { return ro::nnw::kModelId; }

}  // extern "C"
