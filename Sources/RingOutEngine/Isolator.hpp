// Isolator stage: runs on the notched signal with the detector's side vector
// as a conditioning input and removes residual feedback the notches missed.
//
// MODEL SEAM. The PRD's isolator is a causal TCN compiled to BNNSGraph. No
// trained weights exist yet, so the only implementation today is
// ResidualIsolator, a plain DSP fallback. A model-backed implementation
// (e.g. `BnnsGraphIsolator`) would subclass Isolator, compile the graph and
// allocate its state tensors in prepare(), run one sample-aligned
// BNNSGraphContextExecute per block in process(), and be returned from
// makeIsolator() below. Everything else in the engine is unaware of which one
// is running.
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
