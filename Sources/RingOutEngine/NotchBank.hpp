// Adaptive notch bank: 8 auto slots driven by the detector + 4 fixed slots.
#pragma once

#include "Biquad.hpp"
#include "Events.hpp"
#include "FeedbackDetector.hpp"

namespace ro {

struct NotchSettings {
    float holdS = 4.0f;      // release ramp time
    int maxAuto = 8;
    bool ringOutMode = false;
};

class NotchBank {
public:
    static constexpr int kAuto = RO_MAX_AUTO_NOTCHES;
    static constexpr int kFixed = RO_MAX_FIXED_NOTCHES;
    static constexpr int kSlots = RO_MAX_NOTCHES;
    static constexpr double kQ = 60.0;  // initial notch Q (auto notches widen to Q 30)
    static constexpr float kInitialDepth = -6.0f;
    static constexpr float kDeepenStep = 3.0f;
    static constexpr float kMaxDepth = -18.0f;
    static constexpr float kFixedMinDepth = -30.0f;

    void prepare(double fs);  // keeps fixed notches, clears auto ones
    void clearAuto();
    void setSettings(const NotchSettings& s);

    // Control-rate update, once per audio block. newFrame = detector produced
    // a fresh analysis frame since the last call.
    void update(const FeedbackDetector& det, bool newFrame, const EventSink& ev);

    // In-place, sample-accurate.
    void process(float* x, int n);

    // Commands.
    void pin(int slot, const EventSink& ev);
    void release(int slot);
    bool addFixed(float freq, float depthDb);
    void move(int slot, float freq);

    bool hasNotchNear(float f) const;
    int activeAuto() const;
    int activeFixed() const;
    bool loopGainWarning() const { return warning_; }
    double lastRingTime() const { return lastRingTime_; }
    float lastRingHz() const { return lastRingHz_; }
    void fillInfo(ro_notch_info* out, double now) const;

private:
    enum class Phase { Off, Hold, Releasing, Draining };
    struct Slot {
        Phase phase = Phase::Off;
        bool fixed = false;
        bool killed = false;       // released by command: never revived by detection
        float freq = 1000.0f;
        float depth = 0.0f;        // current target depth (dB)
        float holdDepth = 0.0f;    // depth before a release ramp started
        float q = static_cast<float>(kQ);  // auto notches widen when the ring sits on their skirt
        float appliedFreq = 0.0f, appliedDepth = 0.0f, appliedQ = 0.0f;
        double created = 0, lastDeepen = 0, quietSince = -1, releaseStart = 0, drainUntil = 0;
        double pressureSince = -1;  // fixed: a ring has been growing through it since
        float maxLevel = -120.0f, levelAtDeepen = -120.0f;
        SmoothBiquad filt;
    };

    int findNear(float f) const;      // nearest notch within the merge window
    int fixedBandAt(float f) const;   // fixed notch whose band contains f
    bool remembered(float f, double now) const;  // a notch was released near f recently
    void coalesce();
    int freeSlot(bool fixed) const;
    void place(int slot, float freq, float depth, bool fixed, double now, float q = static_cast<float>(kQ));
    void deepen(Slot& s, float level, double now, float conf, const EventSink& ev);
    bool pinToFixed(int autoSlot, double now, const EventSink& ev);
    void noteRing(float f, double now);
    void refreshCoeffs(Slot& s, bool snap);

    double fs_ = 48000;
    double now_ = 0;
    Slot slots_[kSlots];
    NotchSettings set_;

    // Recently released notches: a ring that comes back resumes at the depth
    // it needed last time instead of starting over at -6 dB.
    struct Memory {
        float freq = 0, depth = 0;
        double time = -1e9;
        float q = static_cast<float>(kQ);
    };
    static constexpr int kMemory = 8;
    Memory memory_[kMemory];
    int memoryNext_ = 0;

    // Oscillation guard.
    int reappear_ = 0;
    double lastRemoval_ = -1e9;
    double tripUntil_ = -1;
    bool warning_ = false;
    double lastRingTime_ = -1e9;
    float lastRingHz_ = 0.0f;
};

}  // namespace ro
