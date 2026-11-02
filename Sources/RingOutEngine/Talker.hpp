// Synthetic talker for the simulated loop: a glottal pulse train (Rosenberg
// pulse, jitter, shimmer, intonation or vibrato) through a cascade of four
// formant resonators, shaped into syllables/notes with pauses.
#pragma once

#include "Biquad.hpp"
#include "include/ringout_engine.h"

namespace ro {

class Talker {
public:
    void init(double fs, uint32_t seed);
    void setSource(int src);
    float next();

private:
    struct Formant {
        double a1 = 0, a2 = 0, g = 1, y1 = 0, y2 = 0;
        inline double tick(double x) {
            const double y = g * x - a1 * y1 - a2 * y2;
            y2 = y1;
            y1 = y;
            return y;
        }
    };

    void reset(uint32_t seed);
    void nextSegment();
    void updateFormants();
    float glottal(float p) const;

    double fs_ = 48000;
    int source_ = RO_SIM_SPEECH;
    Rng rng_;
    float gain_ = 1.0f;

    // Voice identity.
    float baseF0_ = 140.0f;
    float formantScale_ = 1.0f;
    float vibRate_ = 5.5f, vibDepthCents_ = 50.0f;

    // Segment state machine.
    enum class Seg { Vowel, Gap, Pause };
    Seg seg_ = Seg::Pause;
    int segLeft_ = 0;
    int sylInPhrase_ = 0, sylCount_ = 0;
    int notesInPhrase_ = 0, noteCount_ = 0;
    float envTarget_ = 0.0f, env_ = 0.0f;
    float fricTarget_ = 0.0f, fric_ = 0.0f;
    float f0Target_ = 140.0f, f0_ = 140.0f;
    float noteAge_ = 0.0f;
    float phraseProgress_ = 0.0f;

    // Glottal source.
    float phase_ = 0.0f, gPrev_ = 0.0f;
    float periodJitter_ = 1.0f, periodShimmer_ = 1.0f;
    float vibPhase_ = 0.0f;

    // Formants.
    float fTarget_[4]{}, fCur_[4]{};
    Formant formants_[4];
    int formantCounter_ = 0;
    Biquad fricFilter_;
    float aspLp_ = 0.0f;
};

}  // namespace ro
