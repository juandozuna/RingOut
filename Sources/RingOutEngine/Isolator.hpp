// Isolator stage: runs on the notched signal with the detector's side vector
// as a conditioning input and removes residual feedback the notches missed.
//
// Two implementations: NeuralIsolator (the trained causal TCN from ml/,
// 48 kHz only) and ResidualIsolator, the plain DSP stand-in returned by
// makeIsolator(). Channel owns one of each and runs [neural] -> [DSP]
// according to RO_PARAM_ISOLATOR; everything else in the engine is unaware of
// which one is running.
#pragma once

#include <memory>

#include "FeedbackDetector.hpp"

namespace ro {

class NotchBank;

struct IsolatorSide {
    const SideVector* side = nullptr;
    const NotchBank* notches = nullptr;  // to skip candidates a notch already covers
    bool newFrame = false;
};

class Isolator {
public:
    virtual ~Isolator() = default;
    // Allocation allowed here only.
    virtual bool prepare(double fs, int maxFrames) = 0;
    virtual void reset() = 0;
    virtual void setPreset(int preset) = 0;
    // In-place, zero added latency, real-time safe.
    virtual void process(float* x, int n, const IsolatorSide& side) = 0;
    // 0..1, how much the stage is currently removing.
    virtual float activity() const = 0;
};

std::unique_ptr<Isolator> makeIsolator();

}  // namespace ro
