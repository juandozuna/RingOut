// NeuralIsolator: on-device inference for the trained feedback isolator, a
// causal gated TCN (see ml/model.py for the equations and StreamingTCN, the
// block-by-block reference this port matches sample for sample).
//
// Mono in / mono out, zero added latency: every output sample depends only on
// the current and past inputs. Per layer the only state is a ring buffer of
// the last `dilation` hidden vectors. Blocks of any size are processed in
// sub-blocks of kBlock frames with activations kept channel-major ([c][t]),
// so every matrix product is a small, auto-vectorised GEMM.
//
// The model was trained at 48 kHz. At any other rate prepare() returns false,
// usable() stays false and process() leaves the signal untouched; the caller
// is expected to fall back to the DSP isolator.
#pragma once

#include <vector>

#include "Isolator.hpp"

namespace ro {

class NeuralIsolator final : public Isolator {
public:
    static constexpr double kModelRate = 48000.0;
    static constexpr int kBlock = 64;  // internal sub-block, frames

    // Allocates history + scratch. Returns usable().
    bool prepare(double fs, int maxFrames) override;
    // Zero history (as if preceded by silence through a fresh model). No fade.
    void reset() override;
    void setPreset(int /*preset*/) override {}
    void process(float* x, int n, const IsolatorSide& side) override;
    float activity() const override { return activity_; }

    bool usable() const { return usable_; }
    // True for the generated placeholder (untrained) weights.
    static bool placeholderWeights();
    static const char* modelId();

private:
    void processBlock(float* x, int n);
    void clearHistory();

    bool usable_ = false;
    double fs_ = kModelRate;

    std::vector<float> ring_;  // per layer [C][dilation], concatenated
    int ringOff_[16] = {};     // start of each layer in ring_
    int ringPos_[16] = {};     // index of the oldest sample per layer

    // Block scratch, row stride kBlock. act_ rows: [0,C) delayed h, [C,2C) h,
    // [2C,3C) skip sum, so rows [0,2C) are the dilated conv's input.
    std::vector<float> act_, z_, g_, u_, y_;

    // Safety guard: after a trip the correction fades back in.
    int fadeLen_ = 2400, fadePos_ = 0;

    // Silence gate on the correction (see kGateSilence in the .cpp).
    bool ungated_ = false;
    float gate_ = 0.0f, env_ = 0.0f;
    float gateAttack_ = 0.0f, gateRelease_ = 0.0f, envRelease_ = 0.0f;

    // Activity: smoothed correction / input energy.
    double eCorr_ = 0, eIn_ = 0;
    float activity_ = 0.0f;
};

}  // namespace ro
