// One processing channel: trim -> DC block -> HPF -> detector -> notch bank ->
// isolator -> Strength mix -> limiter -> mute, plus all metering.
#pragma once

#include <memory>
#include <vector>

#include "Biquad.hpp"
#include "Events.hpp"
#include "FeedbackDetector.hpp"
#include "Isolator.hpp"
#include "NeuralIsolator.hpp"
#include "NotchBank.hpp"

namespace ro {

struct ChannelParams {
    float strength = 0.8f;
    bool bypass = false;
    bool mute = false;
    bool highpass = true;
    bool limiter = true;
    float holdS = 4.0f;
    int maxAuto = 8;
    int preset = RO_PRESET_SPEECH;
    bool ringOut = false;
    float trimDb = 0.0f;
    int isolator = -1;  // ro_isolator; -1 = default (see kDefaultIsolator in Channel.cpp)
};

class Channel {
public:
    Channel();

    bool prepare(double fs, int maxFrames, int index);
    void setParam(ro_param p, float v);
    void command(ro_command c, float a, float b, EventQueue* q);

    // in/out may alias. n <= maxFrames.
    void process(const float* in, float* out, int n, EventQueue* q);

    bool publishDue() const { return sincePublish_ >= publishInterval_; }
    void fillSnapshot(ro_channel_snapshot& s);

private:
    void applyParams(bool snap);
    void meterBlock(const float* x, int n, float& peakAcc, float& powEwma, bool& clip);
    void resetMeters();
    ro_isolator activeIsolator() const;
    // Runs one isolator stage in place, cross-faded by its enable ramp.
    float runStage(Isolator& iso, LinearRamp& mix, int n, const IsolatorSide& side);

    ChannelParams p_;
    double fs_ = 48000;
    int index_ = 0;
    int maxFrames_ = 0;
    bool prepared_ = false;
    uint64_t frames_ = 0;

    std::vector<float> dryRaw_, dry_, cond_, wet_, stage_;

    LinearRamp trim_, strength_, mute_, hpfMix_;
    double dcX1_ = 0, dcY1_ = 0, dcR_ = 0.9995;
    Biquad hpf_;

    FeedbackDetector det_;
    NotchBank notches_;
    // Isolator chain: [neural] -> [DSP], each stage enabled by a ramp so mode
    // switches cross-fade. Both are prepared up front; nothing is allocated
    // on the audio thread.
    std::unique_ptr<NeuralIsolator> neural_;
    std::unique_ptr<Isolator> dsp_;
    LinearRamp neuralMix_, dspMix_;

    // Strength mix: equal-power law using the measured dry/wet correlation.
    double cDW_ = 1, cDD_ = 1, cWW_ = 1;
    float rho_ = 1.0f;
    float kCached_ = 1.0f, sCached_ = -1.0f;

    // Limiter.
    float limGain_ = 1.0f, limRel_ = 0.0f;

    // Meters.
    float inPeakAcc_ = 0, outPeakAcc_ = 0;
    float inPow_ = 0, outPow_ = 0, powCoef_ = 0;
    bool inClip_ = false, outClip_ = false;
    float inHold_ = -120, outHold_ = -120;
    double inHoldT_ = 0, outHoldT_ = 0;
    double grDry_ = 0, grOut_ = 0;
    float multiTalker_ = 0;
    bool multiTalkerOn_ = false;
    float isoActivity_ = 0;
    int sincePublish_ = 0, publishInterval_ = 240;
};

}  // namespace ro
