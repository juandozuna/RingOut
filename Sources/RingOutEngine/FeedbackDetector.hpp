// Feedback detector: sliding-window FFT analysis, peak tracking and a logistic
// feedback-vs-voice classifier. Detection only: it reads a copy of the signal
// and never sits in the audio path, so it adds no latency.
#pragma once

#include <Accelerate/Accelerate.h>

#include <vector>

#include "RtCommon.hpp"

namespace ro {

constexpr int kSideVectorSize = 8;

// One detector candidate. The side vector handed to the notch bank and the
// isolator is the top kSideVectorSize tracks sorted by confidence.
struct Candidate {
    float freq = 0;
    float conf = 0;
    float levelDb = -120;
    float growth = 0;  // dB per 100 ms
    int trackId = -1;
};

struct SideVector {
    int count = 0;
    Candidate c[kSideVectorSize];
};

// Logistic classifier weights. Hand-set (no training data is available yet);
// features are normalised to roughly [-1.5, 2] before weighting.
struct DetectorTuning {
    float bias;
    float wPapr;
    float wDom;
    float wHarm;      // negative: harmonic partials mean voice
    float wStab;
    float wGrowth;
    float wMono;
    float wPersist;   // reward for a stable, persisting, non-harmonic tone
    float persistS;   // seconds of stable persistence for full reward
    float ultraHarmDiscount;  // harmonic penalty removed for an ultra-stable tone
};

class FeedbackDetector {
public:
    static constexpr int kMaxPeaks = 32;     // peaks kept for harmonic checks
    static constexpr int kTrackPeaks = 16;   // top peaks eligible for tracking
    static constexpr int kMaxTracks = 24;
    static constexpr int kHistory = 96;
    static constexpr int kMinTrackFrames = 4;
    static constexpr float kFloorDb = -60.0f;          // tracking / candidate floor
    static constexpr float kPartialFloorDb = -85.0f;   // weaker peaks still count as partials

    FeedbackDetector() = default;
    ~FeedbackDetector();
    FeedbackDetector(const FeedbackDetector&) = delete;
    FeedbackDetector& operator=(const FeedbackDetector&) = delete;

    bool prepare(double fs);
    void reset();
    void setPreset(int preset);

    // Feeds n conditioned samples. Returns true when a new analysis frame ran.
    bool process(const float* x, int n);

    const SideVector& side() const { return side_; }
    double now() const { return static_cast<double>(samples_) / fs_; }
    float binHz() const { return binHz_; }

    // Level (dBFS) of the strongest bin around f in the last frame.
    float levelAtHz(float f) const;
    // Level of a ring-like track (conf >= minConf) within tolHz of f, or -120.
    float ringLevelNear(float f, float tolHz, float minConf) const;

    // 96 log-spaced bands 100 Hz..20 kHz, dBFS, clamped -120..0.
    void logSpectrum(float* out) const;

    // True if the last frame shows more than one independent harmonic series.
    bool multiTalkerFrame() const;

private:
    struct Peak {
        float bin;    // interpolated bin position
        float level;  // dB
        int k;        // integer bin
    };
    struct Track {
        bool alive = false;
        int id = 0;
        float bin = 0, freq = 0, level = -120, maxLevel = -120;
        int ageFrames = 0, misses = 0;
        double start = 0;
        int hCount = 0, hHead = 0;
        float hT[kHistory]{}, hF[kHistory]{}, hL[kHistory]{}, hO[kHistory]{};
        float conf = 0, growth = 0;
    };

    void analyse(int hop);
    void findPeaks();
    float refineFrequency(const Peak& p, int hop) const;
    void updateTracks(int hop);
    void scoreTrack(Track& t);
    float harmonicScore(float f, float level) const;
    float combScore(float f, float level) const;

    double fs_ = 48000;
    int n_ = 0, half_ = 0, mask_ = 0;
    int hopMin_ = 128;
    float binHz_ = 46.875f;
    int kMin_ = 2, kMax_ = 500;
    float magScale_ = 1.0f;
    vDSP_DFT_Setup setup_ = nullptr;

    std::vector<float> ring_, window_, frame_, inRe_, inIm_;
    std::vector<float> re_, im_, prevRe_, prevIm_, power_, db_;
    std::vector<int> bandLo_, bandHi_;
    std::vector<float> bandCenterBin_;
    int writePos_ = 0;
    int sinceLast_ = 0;
    int filled_ = 0;
    uint64_t samples_ = 0;
    uint64_t frames_ = 0;
    bool havePrev_ = false;
    float meanDb_ = -120;
    float bodyDb_ = -140;     // log-mean spectrum level: the broadband 'body'
    int kBody_ = 170;

    Peak peaks_[kMaxPeaks];
    int numPeaks_ = 0;
    Track tracks_[kMaxTracks];
    int nextTrackId_ = 1;
    SideVector side_;
    DetectorTuning tune_{};
};

}  // namespace ro
