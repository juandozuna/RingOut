#include "Talker.hpp"

namespace ro {

namespace {

// F1..F4 (Hz) for five vowels: /a/ /i/ /u/ /e/ /o/.
constexpr float kVowels[5][4] = {
    {730, 1090, 2440, 3400},
    {270, 2290, 3010, 3700},
    {300, 870, 2240, 3400},
    {530, 1840, 2480, 3500},
    {570, 840, 2410, 3400},
};
constexpr float kBandwidths[4] = {70, 90, 120, 180};
constexpr float kScale[6] = {0, 2, 4, 7, 9, 12};  // pentatonic, semitones
constexpr float kTargetRmsDb = -24.0f;            // active-voice RMS at the mic

inline float onePole(float tauS, double fs) { return static_cast<float>(1.0 - std::exp(-1.0 / (tauS * fs))); }

}  // namespace

void Talker::init(double fs, uint32_t seed) {
    fs_ = fs;
    // Calibrate the output gain on 4 s of material, then restart identically.
    for (int pass = 0; pass < 2; ++pass) {
        reset(seed);
        if (pass == 1) break;
        gain_ = 1.0f;
        double sum = 0;
        long count = 0;
        const int n = static_cast<int>(4.0 * fs);
        for (int i = 0; i < n; ++i) {
            const float v = next();
            if (env_ > 0.5f) { sum += static_cast<double>(v) * v; ++count; }
        }
        const double rms = count > 0 ? std::sqrt(sum / count) : 1.0;
        gain_ = rms > 1e-9 ? static_cast<float>(std::pow(10.0, kTargetRmsDb / 20.0) / rms) : 1.0f;
    }
}

void Talker::setSource(int src) {
    if (src == source_) return;
    source_ = src;
    seg_ = Seg::Pause;
    segLeft_ = static_cast<int>(0.1 * fs_);
    envTarget_ = 0.0f;
}

void Talker::reset(uint32_t seed) {
    rng_.reseed(seed * 7919u + 17u);
    const int src = source_;
    const float gain = gain_;
    const double fs = fs_;
    *this = Talker{};
    fs_ = fs;
    source_ = src;
    gain_ = gain;
    rng_.reseed(seed * 7919u + 17u);
    baseF0_ = rng_.range(100.0f, 210.0f);
    formantScale_ = 1.0f + (baseF0_ - 100.0f) / 110.0f * 0.15f;
    vibRate_ = rng_.range(5.0f, 6.2f);
    vibDepthCents_ = rng_.range(35.0f, 65.0f);
    f0_ = f0Target_ = baseF0_;
    for (int k = 0; k < 4; ++k) fCur_[k] = fTarget_[k] = kVowels[0][k] * formantScale_;
    fricFilter_.c = designBandpass(fs_, 4500.0, 1.2);
    seg_ = Seg::Pause;
    segLeft_ = static_cast<int>(0.15 * fs_);
    updateFormants();
}

void Talker::nextSegment() {
    const bool singing = source_ == RO_SIM_SINGING;
    if (source_ == RO_SIM_SILENCE) {
        seg_ = Seg::Pause;
        envTarget_ = 0.0f;
        fricTarget_ = 0.0f;
        segLeft_ = static_cast<int>(0.5 * fs_);
        return;
    }
    const int vowel = static_cast<int>(rng_.uniform() * 5) % 5;
    if (singing) {
        if (seg_ == Seg::Vowel && notesInPhrase_ >= noteCount_) {
            seg_ = Seg::Pause;  // breath
            envTarget_ = 0.0f;
            segLeft_ = static_cast<int>(rng_.range(0.2f, 0.5f) * fs_);
            notesInPhrase_ = 0;
            return;
        }
        if (seg_ != Seg::Vowel) noteCount_ = 2 + static_cast<int>(rng_.uniform() * 3);
        seg_ = Seg::Vowel;
        ++notesInPhrase_;
        const float semis = kScale[static_cast<int>(rng_.uniform() * 6) % 6];
        // Sung pitch range sits higher than the speaking voice.
        f0Target_ = baseF0_ * 1.4f * std::pow(2.0f, semis / 12.0f);
        envTarget_ = 1.0f;
        noteAge_ = 0.0f;
        for (int k = 0; k < 4; ++k) fTarget_[k] = kVowels[vowel][k] * formantScale_;
        segLeft_ = static_cast<int>(rng_.range(0.7f, 2.4f) * fs_);
        return;
    }

    // Speech.
    if (seg_ == Seg::Vowel) {
        if (sylInPhrase_ >= sylCount_) {
            seg_ = Seg::Pause;
            envTarget_ = 0.0f;
            fricTarget_ = 0.0f;
            segLeft_ = static_cast<int>(rng_.range(0.25f, 0.8f) * fs_);
            sylInPhrase_ = 0;
            return;
        }
        seg_ = Seg::Gap;
        envTarget_ = 0.08f;
        fricTarget_ = rng_.uniform() < 0.4f ? 0.25f : 0.0f;
        segLeft_ = static_cast<int>(rng_.range(0.02f, 0.07f) * fs_);
        return;
    }
    if (seg_ == Seg::Pause) sylCount_ = 4 + static_cast<int>(rng_.uniform() * 6);
    seg_ = Seg::Vowel;
    ++sylInPhrase_;
    phraseProgress_ = static_cast<float>(sylInPhrase_) / static_cast<float>(sylCount_);
    const float contour = 1.15f - 0.3f * phraseProgress_;
    f0Target_ = baseF0_ * contour * (1.0f + 0.1f * rng_.bipolar());
    envTarget_ = rng_.range(0.75f, 1.0f);
    fricTarget_ = 0.0f;
    for (int k = 0; k < 4; ++k) fTarget_[k] = kVowels[vowel][k] * formantScale_ * (1.0f + 0.05f * rng_.bipolar());
    segLeft_ = static_cast<int>(rng_.range(0.12f, 0.28f) * fs_);
}

void Talker::updateFormants() {
    for (int k = 0; k < 4; ++k) {
        const double f = std::min(static_cast<double>(fCur_[k]), fs_ * 0.45);
        const double r = std::exp(-kPi * kBandwidths[k] / fs_);
        Formant& fm = formants_[k];
        fm.a1 = -2.0 * r * std::cos(kTwoPi * f / fs_);
        fm.a2 = r * r;
        fm.g = 1.0 + fm.a1 + fm.a2;  // unity gain at DC (Klatt cascade)
    }
}

float Talker::glottal(float p) const {
    constexpr float tp = 0.40f, tn = 0.16f;
    if (p < tp) return 0.5f * (1.0f - std::cos(static_cast<float>(kPi) * p / tp));
    if (p < tp + tn) return std::cos(static_cast<float>(kPi) * (p - tp) / (2.0f * tn));
    return 0.0f;
}

float Talker::next() {
    if (--segLeft_ <= 0) nextSegment();
    const bool singing = source_ == RO_SIM_SINGING;
    const float dt = static_cast<float>(1.0 / fs_);

    // Smoothed controls.
    const float envCoef = envTarget_ > env_ ? onePole(singing ? 0.06f : 0.015f, fs_)
                                            : onePole(singing ? 0.08f : 0.03f, fs_);
    env_ += (envTarget_ - env_) * envCoef;
    fric_ += (fricTarget_ - fric_) * onePole(0.01f, fs_);
    f0_ += (f0Target_ - f0_) * onePole(singing ? 0.05f : 0.04f, fs_);
    noteAge_ += dt;

    if (++formantCounter_ >= 16) {
        formantCounter_ = 0;
        const float c = onePole(0.025f, fs_ / 16.0);
        for (int k = 0; k < 4; ++k) fCur_[k] += (fTarget_[k] - fCur_[k]) * c;
        updateFormants();
    }

    // Instantaneous pitch: jitter per period, vibrato when singing.
    float f0 = f0_ * periodJitter_;
    if (singing) {
        vibPhase_ += vibRate_ * dt;
        if (vibPhase_ >= 1.0f) vibPhase_ -= 1.0f;
        const float fadeIn = clampv((noteAge_ - 0.15f) / 0.35f, 0.0f, 1.0f);
        const float cents = vibDepthCents_ * fadeIn * std::sin(static_cast<float>(kTwoPi) * vibPhase_);
        f0 *= std::pow(2.0f, cents / 1200.0f);
    }

    phase_ += f0 * dt;
    if (phase_ >= 1.0f) {
        phase_ -= 1.0f;
        periodJitter_ = 1.0f + 0.008f * rng_.bipolar();
        periodShimmer_ = 1.0f + 0.05f * rng_.bipolar();
    }
    const float g = glottal(phase_);
    const float src = (g - gPrev_) * static_cast<float>(fs_) / (f0 * 8.0f);
    gPrev_ = g;

    // Aspiration (breathy) noise on the source, and fricative bursts.
    const float white = rng_.bipolar();
    aspLp_ += (white - aspLp_) * 0.3f;
    double x = src * periodShimmer_ + 0.02f * aspLp_;
    for (auto& fm : formants_) x = fm.tick(x);
    const float voiced = static_cast<float>(x) * env_;
    const float fric = static_cast<float>(fricFilter_.tick(white)) * fric_;
    const float out = (voiced + fric) * gain_;
    return isFiniteF(out) ? out : 0.0f;
}

}  // namespace ro
