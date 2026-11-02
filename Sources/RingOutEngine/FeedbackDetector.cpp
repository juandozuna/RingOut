#include "FeedbackDetector.hpp"

#include "include/ringout_engine.h"

namespace ro {

namespace {

constexpr DetectorTuning kSpeechTuning{-3.0f, 1.0f, 1.0f, -4.0f, 1.5f, 1.0f, 0.8f, 2.0f, 0.5f, 0.75f};
// Singing holds stable pitched notes, so it needs more evidence before calling
// a steady tone feedback: lower bias, harsher harmonic penalty, slower persistence.
constexpr DetectorTuning kSingingTuning{-3.6f, 1.0f, 0.8f, -5.0f, 1.3f, 1.0f, 0.8f, 1.6f, 1.5f, 0.5f};
constexpr DetectorTuning kCustomTuning{-3.3f, 1.0f, 0.9f, -4.5f, 1.4f, 1.0f, 0.8f, 1.8f, 1.0f, 0.6f};

inline float princarg(float a) {
    return a - static_cast<float>(kTwoPi) * std::round(a / static_cast<float>(kTwoPi));
}

}  // namespace

FeedbackDetector::~FeedbackDetector() {
    if (setup_) vDSP_DFT_DestroySetup(setup_);
}

bool FeedbackDetector::prepare(double fs) {
    fs_ = fs;
    // 1024 points at 44.1/48 kHz; doubled above 50 kHz to keep ~47 Hz bins.
    n_ = fs > 50000.0 ? 2048 : 1024;
    half_ = n_ / 2;
    mask_ = n_ - 1;
    binHz_ = static_cast<float>(fs / n_);
    // Hop = host buffer, floored at 2.67 ms so feature time constants and CPU
    // cost do not depend on very small buffers.
    hopMin_ = std::max(1, static_cast<int>(std::lround(128.0 * fs / 48000.0)));
    kMin_ = std::max(2, static_cast<int>(std::ceil(80.0 / binHz_)));
    kMax_ = std::min(half_ - 2, static_cast<int>(std::floor(fs * 0.45 / binHz_)));
    kBody_ = std::min(kMax_, static_cast<int>(std::floor(8000.0 / binHz_)));

    if (setup_) vDSP_DFT_DestroySetup(setup_);
    setup_ = vDSP_DFT_zrop_CreateSetup(nullptr, static_cast<vDSP_Length>(n_), vDSP_DFT_FORWARD);
    if (!setup_) return false;

    ring_.assign(n_, 0.0f);
    window_.resize(n_);
    for (int i = 0; i < n_; ++i)
        window_[i] = static_cast<float>(0.5 - 0.5 * std::cos(kTwoPi * i / n_));
    frame_.assign(n_, 0.0f);
    inRe_.assign(half_, 0.0f);
    inIm_.assign(half_, 0.0f);
    re_.assign(half_, 0.0f);
    im_.assign(half_, 0.0f);
    prevRe_.assign(half_, 0.0f);
    prevIm_.assign(half_, 0.0f);
    power_.assign(half_, 0.0f);
    db_.assign(half_, -120.0f);

    // Calibrate so a full-scale sine reads 0 dBFS at its peak bin.
    {
        const int kc = 64;
        for (int i = 0; i < n_; ++i)
            frame_[i] = static_cast<float>(std::cos(kTwoPi * kc * i / n_)) * window_[i];
        DSPSplitComplex in{inRe_.data(), inIm_.data()};
        vDSP_ctoz(reinterpret_cast<const DSPComplex*>(frame_.data()), 2, &in, 1, half_);
        vDSP_DFT_Execute(setup_, inRe_.data(), inIm_.data(), re_.data(), im_.data());
        const float p = re_[kc] * re_[kc] + im_[kc] * im_[kc];
        magScale_ = p > 0 ? 1.0f / p : 1.0f;
    }

    // Log-spaced display bands.
    bandLo_.resize(RO_SPECTRUM_BINS);
    bandHi_.resize(RO_SPECTRUM_BINS);
    bandCenterBin_.resize(RO_SPECTRUM_BINS);
    for (int b = 0; b < RO_SPECTRUM_BINS; ++b) {
        const double f0 = 100.0 * std::pow(200.0, static_cast<double>(b) / RO_SPECTRUM_BINS);
        const double f1 = 100.0 * std::pow(200.0, static_cast<double>(b + 1) / RO_SPECTRUM_BINS);
        const double fc = std::sqrt(f0 * f1);
        bandLo_[b] = clampv(static_cast<int>(std::ceil(f0 / binHz_)), 1, half_ - 1);
        bandHi_[b] = clampv(static_cast<int>(std::floor(f1 / binHz_)), 1, half_ - 1);
        bandCenterBin_[b] = clampv(static_cast<float>(fc / binHz_), 1.0f, static_cast<float>(half_ - 2));
    }

    reset();
    return true;
}

void FeedbackDetector::reset() {
    std::fill(ring_.begin(), ring_.end(), 0.0f);
    std::fill(db_.begin(), db_.end(), -120.0f);
    std::fill(power_.begin(), power_.end(), 0.0f);
    writePos_ = 0;
    sinceLast_ = 0;
    filled_ = 0;
    samples_ = 0;
    frames_ = 0;
    havePrev_ = false;
    numPeaks_ = 0;
    meanDb_ = -120;
    for (auto& t : tracks_) t.alive = false;
    side_ = SideVector{};
}

void FeedbackDetector::setPreset(int preset) {
    switch (preset) {
        case RO_PRESET_SINGING: tune_ = kSingingTuning; break;
        case RO_PRESET_CUSTOM: tune_ = kCustomTuning; break;
        default: tune_ = kSpeechTuning; break;
    }
}

bool FeedbackDetector::process(const float* x, int n) {
    if (n_ == 0) return false;
    for (int i = 0; i < n; ++i) {
        ring_[writePos_] = x[i];
        writePos_ = (writePos_ + 1) & mask_;
    }
    samples_ += static_cast<uint64_t>(n);
    filled_ = std::min(n_, filled_ + n);
    sinceLast_ += n;
    if (sinceLast_ < hopMin_ || filled_ < n_) return false;
    const int hop = sinceLast_;
    sinceLast_ = 0;
    analyse(hop);
    return true;
}

void FeedbackDetector::analyse(int hop) {
    // Window the most recent n_ samples (oldest first).
    const int first = n_ - writePos_;
    vDSP_vmul(ring_.data() + writePos_, 1, window_.data(), 1, frame_.data(), 1, static_cast<vDSP_Length>(first));
    if (writePos_ > 0)
        vDSP_vmul(ring_.data(), 1, window_.data() + first, 1, frame_.data() + first, 1,
                  static_cast<vDSP_Length>(writePos_));

    std::swap(re_, prevRe_);
    std::swap(im_, prevIm_);
    DSPSplitComplex in{inRe_.data(), inIm_.data()};
    vDSP_ctoz(reinterpret_cast<const DSPComplex*>(frame_.data()), 2, &in, 1, static_cast<vDSP_Length>(half_));
    vDSP_DFT_Execute(setup_, inRe_.data(), inIm_.data(), re_.data(), im_.data());

    DSPSplitComplex out{re_.data(), im_.data()};
    vDSP_zvmags(&out, 1, power_.data(), 1, static_cast<vDSP_Length>(half_));
    power_[0] = 0.0f;  // DC / Nyquist packing, unused
    const float eps = 1e-14f;
    vDSP_vsmsa(power_.data(), 1, &magScale_, &eps, power_.data(), 1, static_cast<vDSP_Length>(half_));
    const float ref = 1.0f;
    vDSP_vdbcon(power_.data(), 1, &ref, db_.data(), 1, static_cast<vDSP_Length>(half_), 0);

    float mean = 0.0f;
    vDSP_meanv(power_.data() + kMin_, 1, &mean, static_cast<vDSP_Length>(kMax_ - kMin_ + 1));
    meanDb_ = powToDb(mean);
    vDSP_meanv(db_.data() + kMin_, 1, &bodyDb_, static_cast<vDSP_Length>(kBody_ - kMin_ + 1));

    findPeaks();
    updateTracks(hop);
    havePrev_ = true;
    ++frames_;
}

void FeedbackDetector::findPeaks() {
    Peak found[64];
    int nf = 0;
    const float* d = db_.data();
    for (int k = kMin_; k <= kMax_; ++k) {
        const float v = d[k];
        if (v <= kPartialFloorDb || v <= d[k - 1] || v < d[k + 1]) continue;
        const float a = d[k - 1], g = d[k + 1];
        const float den = a - 2.0f * v + g;
        float p = den < -1e-9f ? 0.5f * (a - g) / den : 0.0f;
        p = clampv(p, -0.5f, 0.5f);
        Peak pk{static_cast<float>(k) + p, v - 0.25f * (a - g) * p, k};
        if (nf < 64) {
            found[nf++] = pk;
        } else {
            int weakest = 0;
            for (int i = 1; i < 64; ++i)
                if (found[i].level < found[weakest].level) weakest = i;
            if (pk.level > found[weakest].level) found[weakest] = pk;
        }
    }
    const int keep = std::min(nf, kMaxPeaks);
    std::partial_sort(found, found + keep, found + nf,
                      [](const Peak& x, const Peak& y) { return x.level > y.level; });
    for (int i = 0; i < keep; ++i) peaks_[i] = found[i];
    numPeaks_ = keep;
}

// Phase-vocoder refinement: the phase advance at the peak bin between two
// frames hop samples apart pins the frequency far more precisely than
// parabolic interpolation. The 2*pi ambiguity is resolved with the parabolic
// estimate.
float FeedbackDetector::refineFrequency(const Peak& p, int hop) const {
    const float parabolic = p.bin;
    if (!havePrev_ || hop <= 0) return parabolic * binHz_;
    const int k = p.k;
    const float pr = prevRe_[k], pi = prevIm_[k];
    if (pr * pr + pi * pi <= 0.0f) return parabolic * binHz_;
    const float phNow = std::atan2(im_[k], re_[k]);
    const float phPrev = std::atan2(pi, pr);
    const float expected = static_cast<float>(kTwoPi) * k * hop / n_;
    const float dev = princarg(phNow - phPrev - expected);
    const float span = static_cast<float>(n_) / hop;  // bins per 2*pi of deviation
    float est = k + dev * span / static_cast<float>(kTwoPi);
    est += span * std::round((parabolic - est) / span);
    if (std::fabs(est - parabolic) > 0.6f) est = parabolic;
    return est * binHz_;
}

void FeedbackDetector::updateTracks(int hop) {
    const double t = now();
    int nTrack = 0;  // peaks are sorted: the loudest ones above the floor are tracked
    while (nTrack < std::min(numPeaks_, kTrackPeaks) && peaks_[nTrack].level > kFloorDb) ++nTrack;
    bool used[kTrackPeaks] = {};

    // Match live tracks (loudest first) to the nearest unused peak within 0.25 bin.
    int order[kMaxTracks];
    int nOrder = 0;
    for (int i = 0; i < kMaxTracks; ++i)
        if (tracks_[i].alive) order[nOrder++] = i;
    std::sort(order, order + nOrder, [this](int a, int b) { return tracks_[a].level > tracks_[b].level; });

    for (int oi = 0; oi < nOrder; ++oi) {
        Track& tr = tracks_[order[oi]];
        int best = -1;
        float bestD = 0.25f;
        for (int p = 0; p < nTrack; ++p) {
            if (used[p]) continue;
            const float dd = std::fabs(peaks_[p].bin - tr.bin);
            if (dd <= bestD) { bestD = dd; best = p; }
        }
        if (best < 0) {
            if (++tr.misses > 1) tr.alive = false;
            continue;
        }
        used[best] = true;
        const Peak& pk = peaks_[best];
        tr.bin = pk.bin;
        tr.freq = refineFrequency(pk, hop);
        tr.level = pk.level;
        tr.maxLevel = std::max(tr.maxLevel, pk.level);
        tr.misses = 0;
        ++tr.ageFrames;
        tr.hT[tr.hHead] = static_cast<float>(t - tr.start);
        tr.hF[tr.hHead] = tr.freq;
        tr.hL[tr.hHead] = tr.level;
        tr.hO[tr.hHead] = bodyDb_;
        tr.hHead = (tr.hHead + 1) % kHistory;
        tr.hCount = std::min(tr.hCount + 1, kHistory);
    }

    // Unmatched peaks start new tracks.
    for (int p = 0; p < nTrack; ++p) {
        if (used[p]) continue;
        int slot = -1;
        for (int i = 0; i < kMaxTracks; ++i)
            if (!tracks_[i].alive) { slot = i; break; }
        if (slot < 0) {
            // Replace the weakest young track if this peak is louder.
            float weakest = peaks_[p].level;
            for (int i = 0; i < kMaxTracks; ++i)
                if (tracks_[i].ageFrames < kMinTrackFrames && tracks_[i].level < weakest) {
                    weakest = tracks_[i].level;
                    slot = i;
                }
            if (slot < 0) continue;
        }
        Track& tr = tracks_[slot];
        tr = Track{};
        tr.alive = true;
        tr.id = nextTrackId_++;
        tr.bin = peaks_[p].bin;
        tr.freq = refineFrequency(peaks_[p], hop);
        tr.level = tr.maxLevel = peaks_[p].level;
        tr.ageFrames = 1;
        tr.start = t;
        tr.hT[0] = 0.0f;
        tr.hF[0] = tr.freq;
        tr.hL[0] = tr.level;
        tr.hO[0] = bodyDb_;
        tr.hHead = 1;
        tr.hCount = 1;
    }

    // Score and build the side vector.
    side_.count = 0;
    for (auto& tr : tracks_) {
        if (!tr.alive) continue;
        if (tr.ageFrames < kMinTrackFrames || tr.misses > 0) {
            tr.conf = 0.0f;
            continue;
        }
        scoreTrack(tr);
        Candidate c{tr.freq, tr.conf, tr.level, tr.growth, tr.id};
        if (side_.count < kSideVectorSize) {
            side_.c[side_.count++] = c;
        } else {
            int weakest = 0;
            for (int i = 1; i < kSideVectorSize; ++i)
                if (side_.c[i].conf < side_.c[weakest].conf) weakest = i;
            if (c.conf > side_.c[weakest].conf) side_.c[weakest] = c;
        }
    }
    std::sort(side_.c, side_.c + side_.count, [](const Candidate& a, const Candidate& b) { return a.conf > b.conf; });
}

void FeedbackDetector::scoreTrack(Track& tr) {
    const float tNow = static_cast<float>(now() - tr.start);

    // Walk history newest -> oldest.
    float sT = 0, sL = 0, sTT = 0, sTL = 0, sO = 0, sTO = 0;
    int nG = 0, ups = 0, diffs = 0;
    float sF = 0, sFF = 0;
    int nF = 0;
    float jit[kHistory];
    int nJ = 0;
    float prevL = 0, prevF = 0;
    float span = 0;
    for (int i = 0; i < tr.hCount; ++i) {
        const int idx = (tr.hHead - 1 - i + kHistory) % kHistory;
        const float age = tNow - tr.hT[idx];
        if (age <= 0.060f) {
            const float x = tr.hT[idx], y = tr.hL[idx];
            sT += x; sL += y; sTT += x * x; sTL += x * y;
            sO += tr.hO[idx]; sTO += x * tr.hO[idx];
            ++nG;
            if (i > 0) { ++diffs; if (prevL > y) ++ups; }
        }
        if (age <= 0.080f && i > 0) jit[nJ++] = std::fabs(prevF - tr.hF[idx]);
        if (age <= 0.200f) {
            const float f = tr.hF[idx] - tr.freq;
            sF += f; sFF += f * f;
            ++nF;
            span = age;
        }
        prevL = tr.hL[idx];
        prevF = tr.hF[idx];
    }
    float slope = 0.0f, slopeBody = 0.0f;  // dB/s
    if (nG >= 3) {
        const float den = nG * sTT - sT * sT;
        if (den > 1e-12f) {
            slope = (nG * sTL - sT * sL) / den;
            slopeBody = (nG * sTO - sT * sO) / den;
        }
    }
    tr.growth = slope * 0.1f;  // dB per 100 ms
    // Growth relative to the broadband spectrum: a voice onset lifts the whole
    // spectral envelope, a ring grows on its own.
    // (1.5 dB/100 ms deadband: the log-mean of noise-floor bins wanders.)
    const float relGrowth = tr.growth - clampv(slopeBody * 0.1f - 1.5f, 0.0f, std::max(0.0f, tr.growth));
    const float mono = diffs > 0 ? static_cast<float>(ups) / diffs : 0.5f;

    // Frequency stability, two views: frame-to-frame jitter (median |df| over
    // 80 ms; voice has glottal jitter, a ring has none) and spread over 200 ms
    // (vibrato, glides). The spread is looser because placing a notch shifts
    // the ring frequency a few Hz.
    float jitter = 0.0f;
    if (nJ > 0) {
        std::nth_element(jit, jit + nJ / 2, jit + nJ);
        jitter = jit[nJ / 2];
    }
    float sigma = 0.0f;
    if (nF >= 2) {
        const float m = sF / nF;
        sigma = std::sqrt(std::max(0.0f, sFF / nF - m * m));
    }
    const float papr = tr.level - meanDb_;
    // Dominance: how far the peak stands above every other peak (outside its
    // own main lobe). Voice partials come in groups of similar level.
    float nextBest = -120.0f;
    for (int p = 0; p < numPeaks_; ++p)
        if (std::fabs(peaks_[p].bin * binHz_ - tr.freq) > 2.5f * binHz_) nextBest = std::max(nextBest, peaks_[p].level);
    const float dominance = tr.level - std::max(nextBest, kPartialFloorDb);
    // A tone with no jitter and no drift for 150 ms is not a voice, even if it
    // has partials (a saturated howl grows odd harmonics through clipping).
    const float ultra = clampv((0.3f - jitter) / 0.2f, 0.0f, 1.0f) * clampv((1.0f - sigma) / 0.5f, 0.0f, 1.0f) *
                        clampv(span / 0.15f, 0.0f, 1.0f);
    const float harm = std::max(harmonicScore(tr.freq, tr.level), combScore(tr.freq, tr.level)) *
                       (1.0f - tune_.ultraHarmDiscount * ultra);

    const float xPapr = clampv((papr - 20.0f) / 7.0f, -1.5f, 1.5f);
    const float xDom = clampv((dominance - 12.0f) / 8.0f, -1.0f, 1.5f);
    const float xStab = std::min(clampv((0.6f - jitter) / 0.3f, -1.5f, 1.0f), clampv((3.0f - sigma) / 1.5f, -1.5f, 1.0f));
    const float xGrowth = clampv(relGrowth / 2.0f, -1.0f, 2.0f);
    const float xMono = 2.0f * mono - 1.0f;
    const float xPersist = clampv(tNow / tune_.persistS, 0.0f, 1.0f) * clampv(xStab, 0.0f, 1.0f);

    const float z = tune_.bias + tune_.wPapr * xPapr + tune_.wDom * xDom + tune_.wHarm * harm + tune_.wStab * xStab +
                    tune_.wGrowth * xGrowth + tune_.wMono * xMono + tune_.wPersist * xPersist;
    tr.conf = 1.0f / (1.0f + std::exp(-z));
    // In its first 22 ms a track is only credible as a ring if it is clearly
    // growing on its own; steady young tones are mostly vowel onsets.
    if (tNow < 0.022f && relGrowth < 4.0f) tr.conf = std::min(tr.conf, 0.49f);
}

// Partials at 2f, 3f (and f/2, f/3, in case f is itself an upper harmonic)
// within ~12-24 dB of the candidate mean a harmonic series, i.e. voice or music.
float FeedbackDetector::harmonicScore(float f, float level) const {
    static constexpr float kRatios[4] = {2.0f, 3.0f, 0.5f, 1.0f / 3.0f};
    float score = 0.0f;
    for (float r : kRatios) {
        const float ft = f * r;
        if (ft < 70.0f || ft > fs_ * 0.45) continue;
        const float tol = std::max(0.35f * binHz_, 0.006f * ft);
        for (int p = 0; p < numPeaks_; ++p) {
            const float pf = peaks_[p].bin * binHz_;
            if (std::fabs(pf - ft) > tol) continue;
            score = std::max(score, clampv((peaks_[p].level - (level - 24.0f)) / 12.0f, 0.0f, 1.0f));
        }
    }
    return score;
}

// Is f a member of a harmonic comb (some f0 in 70..500 Hz with at least three
// other partials, including an adjacent one of similar level)? Catches upper
// voice partials whose 2f/3f fall outside the analysed peaks.
float FeedbackDetector::combScore(float f, float level) const {
    float best = 0.0f;
    for (int n = 1; n <= 8; ++n) {
        const float f0 = f / n;
        if (f0 < 70.0f) break;
        if (f0 > 500.0f) continue;
        const float tol = std::max(0.45f * binHz_, 0.03f * f0);
        int members = 0;
        float neighbour = -200.0f;
        for (int q = 0; q < numPeaks_; ++q) {
            const float pf = peaks_[q].bin * binHz_;
            if (std::fabs(pf - f) < 0.5f * f0) continue;  // the candidate itself
            const float h = pf / f0;
            const float m = std::round(h);
            if (m < 1.0f || std::fabs(pf - m * f0) > tol) continue;
            if (std::fabs(m - n) > 3.0f) continue;
            ++members;
            if (std::fabs(m - n) == 1.0f) neighbour = std::max(neighbour, peaks_[q].level);
        }
        if (members >= 3) best = std::max(best, clampv((neighbour - (level - 14.0f)) / 6.0f, 0.0f, 1.0f));
    }
    return best;
}

float FeedbackDetector::levelAtHz(float f) const {
    if (n_ == 0) return -120.0f;
    const int k = static_cast<int>(std::lround(f / binHz_));
    float m = -120.0f;
    for (int j = k - 1; j <= k + 1; ++j)
        if (j >= 1 && j < half_) m = std::max(m, db_[j]);
    return m;
}

float FeedbackDetector::ringLevelNear(float f, float tolHz, float minConf) const {
    float lvl = -120.0f;
    for (const auto& tr : tracks_)
        if (tr.alive && tr.conf >= minConf && std::fabs(tr.freq - f) <= tolHz) lvl = std::max(lvl, tr.level);
    return lvl;
}

void FeedbackDetector::logSpectrum(float* out) const {
    for (int b = 0; b < RO_SPECTRUM_BINS; ++b) {
        float v;
        if (n_ == 0) {
            v = -120.0f;
        } else if (bandHi_[b] >= bandLo_[b]) {
            float m = -120.0f;
            for (int k = bandLo_[b]; k <= bandHi_[b]; ++k) m = std::max(m, db_[k]);
            v = m;
        } else {
            const float cb = bandCenterBin_[b];
            const int k0 = static_cast<int>(cb);
            const float fr = cb - k0;
            v = db_[k0] * (1.0f - fr) + db_[k0 + 1] * fr;
        }
        out[b] = clampv(v, -120.0f, 0.0f);
    }
}

// Harmonic sieve over the frame's peaks: find the best-supported fundamental,
// remove its partials, and see whether a second, unrelated series of similar
// strength remains.
bool FeedbackDetector::multiTalkerFrame() const {
    if (numPeaks_ < 8) return false;
    auto isMember = [this](float pf, float f0, float tolBins) {
        const float h = pf / f0;
        const float hr = std::round(h);
        return hr >= 1.0f && hr <= 16.0f && std::fabs(pf - hr * f0) < std::max(tolBins * binHz_, 0.02f * pf);
    };
    bool taken[kMaxPeaks] = {};
    float f0s[2] = {0, 0};
    float energy[2] = {-120, -120};
    for (int series = 0; series < 2; ++series) {
        float bestScore = 0.0f, bestF0 = 0.0f;
        const int minHits = 3;
        for (int p = 0; p < numPeaks_; ++p) {
            if (taken[p] || peaks_[p].level < kFloorDb) continue;
            for (int div = 1; div <= 3; ++div) {
                const float f0 = peaks_[p].bin * binHz_ / div;
                if (f0 < 80.0f || f0 > 600.0f) continue;
                if (series == 1) {
                    // Reject f0s in a simple ratio (p/q, p,q <= 3) to the first
                    // series: those are sub/super-harmonic aliases, not a new voice.
                    bool related = false;
                    for (int a = 1; a <= 3 && !related; ++a)
                        for (int b = 1; b <= 3 && !related; ++b)
                            related = std::fabs(f0 * b - f0s[0] * a) < 0.02f * f0s[0] * a;
                    if (related) continue;
                }
                int hits = 0;
                float sc = 0.0f;
                for (int q = 0; q < numPeaks_; ++q) {
                    if (taken[q] || peaks_[q].level < kFloorDb) continue;
                    if (isMember(peaks_[q].bin * binHz_, f0, 0.5f)) {
                        ++hits;
                        sc += peaks_[q].level + 80.0f;
                    }
                }
                if (hits >= minHits && sc > bestScore) { bestScore = sc; bestF0 = f0; }
            }
        }
        if (bestF0 <= 0.0f) return false;
        f0s[series] = bestF0;
        for (int q = 0; q < numPeaks_; ++q) {
            if (taken[q]) continue;
            // Generous removal so smeared partials of series 1 cannot seed series 2.
            if (isMember(peaks_[q].bin * binHz_, bestF0, series == 0 ? 0.6f : 0.5f)) {
                taken[q] = true;
                energy[series] = std::max(energy[series], peaks_[q].level);
            }
        }
    }
    return energy[1] > energy[0] - 15.0f;
}

}  // namespace ro
