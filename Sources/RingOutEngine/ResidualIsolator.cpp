// ResidualIsolator: the DSP stand-in for the neural isolator.
//
// Two mechanisms, both causal and zero-latency:
//  1. Soft cuts: up to 4 shallow, slightly wider peaking cuts that follow
//     "suspicious" detector candidates (confidence 0.5..0.7, below the notch
//     threshold, not already covered by a notch). Depth scales with
//     confidence and fades out once the candidate goes away.
//  2. Ring duck: a gentle broadband gain reduction (a few dB) while a ring
//     that is already notched keeps growing, i.e. the notch alone is not
//     winning. Released slowly once the growth stops.
// On clean voice neither engages, so the stage is transparent.

#include "Biquad.hpp"
#include "Isolator.hpp"
#include "NotchBank.hpp"

namespace ro {

namespace {

struct IsolatorTuning {
    float maxCutDb;   // soft cut depth at confidence 0.7
    float maxDuckDb;  // broadband duck while a notched ring still grows
};

constexpr IsolatorTuning kSpeech{-6.0f, -3.0f};
constexpr IsolatorTuning kSinging{-3.0f, -2.0f};
constexpr IsolatorTuning kCustom{-4.5f, -2.5f};

class ResidualIsolator final : public Isolator {
public:
    bool prepare(double fs, int /*maxFrames*/) override {
        fs_ = fs;
        // Per-block coefficients are cheap; ramps are time based.
        reset();
        return true;
    }

    void reset() override {
        for (auto& c : cuts_) c = Cut{};
        duckDb_ = 0.0f;
        duckGain_.setLength(64);
        duckGain_.snap(1.0f);
        activity_ = 0.0f;
    }

    void setPreset(int preset) override {
        tune_ = preset == RO_PRESET_SINGING ? kSinging : preset == RO_PRESET_CUSTOM ? kCustom : kSpeech;
    }

    void process(float* x, int n, const IsolatorSide& in) override {
        const float dt = static_cast<float>(n / fs_);
        if (in.newFrame && in.side) updateTargets(*in.side, in.notches);

        // Soft cut ramps: ~10 ms attack, ~250 ms release.
        float act = 0.0f;
        for (auto& c : cuts_) {
            if (!c.active) continue;
            const float target = c.seen ? c.targetDb : 0.0f;
            const float rate = target < c.depthDb ? 600.0f : 24.0f;  // dB/s
            const float step = rate * dt;
            if (c.depthDb > target) c.depthDb = std::max(target, c.depthDb - step);
            else c.depthDb = std::min(target, c.depthDb + step);
            if (!c.seen && c.depthDb >= -0.01f) {
                c.active = false;
                continue;
            }
            if (std::fabs(c.depthDb - c.appliedDb) > 0.05f || c.freq != c.appliedFreq) {
                c.filt.setTarget(designPeaking(fs_, c.freq, kCutQ, c.depthDb), 64);
                c.appliedDb = c.depthDb;
                c.appliedFreq = c.freq;
            }
            act = std::max(act, c.depthDb / tune_.maxCutDb);
        }

        // Duck ramp: 20 ms attack, 400 ms release toward the target.
        const float duckRate = duckTarget_ < duckDb_ ? std::fabs(tune_.maxDuckDb) / 0.02f
                                                     : std::fabs(tune_.maxDuckDb) / 0.4f;
        const float dstep = duckRate * dt;
        if (duckDb_ > duckTarget_) duckDb_ = std::max(duckTarget_, duckDb_ - dstep);
        else duckDb_ = std::min(duckTarget_, duckDb_ + dstep);
        duckGain_.set(duckDb_ < -0.001f ? dbToAmp(duckDb_) : 1.0f);
        if (tune_.maxDuckDb < 0.0f) act = std::max(act, duckDb_ / tune_.maxDuckDb);
        activity_ = clampv(act, 0.0f, 1.0f);

        bool anyCut = false;
        for (auto& c : cuts_) anyCut |= c.active;
        if (anyCut) {
            for (auto& c : cuts_) {
                if (!c.active) continue;
                for (int i = 0; i < n; ++i) x[i] = static_cast<float>(c.filt.tick(x[i]));
                if (!c.filt.stateFinite()) c.filt.reset();
            }
        }
        if (!duckGain_.settled() || duckGain_.cur != 1.0f)
            for (int i = 0; i < n; ++i) x[i] *= duckGain_.next();
    }

    float activity() const override { return activity_; }

private:
    static constexpr int kCuts = 4;
    static constexpr double kCutQ = 40.0;

    struct Cut {
        bool active = false;
        bool seen = false;
        float freq = 1000.0f;
        float targetDb = 0.0f;
        float depthDb = 0.0f;
        float appliedDb = 0.0f, appliedFreq = 0.0f;
        SmoothBiquad filt;
    };

    void updateTargets(const SideVector& sv, const NotchBank* notches) {
        for (auto& c : cuts_) c.seen = false;
        bool ringStillGrowing = false;
        for (int i = 0; i < sv.count; ++i) {
            const Candidate& cand = sv.c[i];
            const bool notched = notches && notches->hasNotchNear(cand.freq);
            if (cand.conf >= 0.9f && notched && cand.growth > 1.0f) ringStillGrowing = true;
            if (cand.conf < 0.5f || cand.conf >= 0.7f || notched) continue;

            const float target = tune_.maxCutDb * clampv((cand.conf - 0.5f) / 0.2f, 0.0f, 1.0f);
            const float tol = std::max(2.0f, cand.freq / 80.0f);
            int idx = -1;
            for (int k = 0; k < kCuts; ++k)
                if (cuts_[k].active && std::fabs(cuts_[k].freq - cand.freq) <= tol) { idx = k; break; }
            if (idx < 0) {
                for (int k = 0; k < kCuts; ++k)
                    if (!cuts_[k].active) { idx = k; break; }
                if (idx < 0) {
                    // Replace the shallowest cut if this one wants to go deeper.
                    int shallow = 0;
                    for (int k = 1; k < kCuts; ++k)
                        if (cuts_[k].depthDb > cuts_[shallow].depthDb) shallow = k;
                    if (target >= cuts_[shallow].depthDb) continue;
                    idx = shallow;
                }
                Cut& c = cuts_[idx];
                c = Cut{};
                c.active = true;
                c.freq = cand.freq;
                c.filt.snap(designPeaking(fs_, c.freq, kCutQ, 0.0));
                c.appliedFreq = c.freq;
            }
            Cut& c = cuts_[idx];
            c.seen = true;
            c.freq = cand.freq;
            c.targetDb = target;
        }
        duckTarget_ = ringStillGrowing ? tune_.maxDuckDb : 0.0f;
    }

    double fs_ = 48000;
    IsolatorTuning tune_ = kSpeech;
    Cut cuts_[kCuts];
    float duckDb_ = 0.0f, duckTarget_ = 0.0f;
    LinearRamp duckGain_;
    float activity_ = 0.0f;
};

}  // namespace

std::unique_ptr<Isolator> makeIsolator() { return std::make_unique<ResidualIsolator>(); }

}  // namespace ro
