// Simulated acoustic feedback loop (ro_sim_*).
//
// Per channel: talker + room noise -> soft-clipping ADC (mic) -> [engine] ->
// console gain -> PA EQ -> delay D -> room (direct path + resonant modes) ->
// back into the mic. Loop gain 0 dB is calibrated to the bypass stability
// limit: the largest |L(w)| at a frequency where the open-loop phase is 0.

#include <complex>
#include <vector>

#include "Engine.hpp"
#include "Talker.hpp"

namespace {

using cd = std::complex<double>;
constexpr int kModes = 4;
constexpr int kSubBlock = 32;

cd response(const ro::BiquadCoeffs& c, double w) {
    const cd z1 = std::polar(1.0, -w), z2 = std::polar(1.0, -2.0 * w);
    return (c.b0 + c.b1 * z1 + c.b2 * z2) / (1.0 + c.a1 * z1 + c.a2 * z2);
}

// Soft-clipping converter: linear to 0.5, then a tanh knee to a 1.0 ceiling.
inline float adcClip(float x) {
    const float a = std::fabs(x);
    if (a <= 0.5f) return x;
    const float y = 0.5f + 0.5f * std::tanh((std::min(a, 1e6f) - 0.5f) * 2.0f);
    return x < 0 ? -y : y;
}

struct SimChannel {
    ro::Talker talker;
    ro::Rng noiseRng{1};
    float noiseLp = 0.0f, noiseGain = 0.0f;
    std::atomic<float> loopDb{-6.0f};
    std::atomic<int> source{RO_SIM_SPEECH};
    int activeSource = RO_SIM_SPEECH;
    double calibration = 1.0;  // linear gain that puts the loop at the stability limit
    float gain = 0.0f;         // smoothed linear loop gain
    ro::Biquad eq[3];
    ro::Biquad modes[kModes];
    double modeGain[kModes]{};
    double direct = 0.12;
    std::vector<float> delay;
    int delaySamples = 0, writePos = 0;
    std::vector<float> mic, mon;

    void build(double fs, uint32_t seed);
    double calibrate(double fs) const;
    float room(float x) {
        double y = direct * x;
        for (int m = 0; m < kModes; ++m) y += modeGain[m] * modes[m].tick(x);
        return static_cast<float>(y);
    }
    float pa(float x) {
        double y = x;
        for (auto& b : eq) y = b.tick(y);
        return static_cast<float>(y);
    }
    void sanitizeState() {
        bool ok = true;
        for (auto& b : eq) ok &= b.stateFinite();
        for (auto& b : modes) ok &= b.stateFinite();
        if (ok) return;
        for (auto& b : eq) b.reset();
        for (auto& b : modes) b.reset();
        std::fill(delay.begin(), delay.end(), 0.0f);
    }
};

void SimChannel::build(double fs, uint32_t seed) {
    ro::Rng r(seed * 2246822519u + 3266489917u);
    talker.init(fs, seed);
    noiseRng.reseed(seed ^ 0xA5A5A5A5u);
    // Low room noise, ~-70 dBFS RMS, gently low-passed.
    noiseGain = static_cast<float>(std::pow(10.0, -70.0 / 20.0) / (std::sqrt(1.0 / 3.0) * std::sqrt(0.1 / 1.9)));

    eq[0].c = ro::designHighpass(fs, 90.0, 0.7071);
    eq[1].c = ro::designLowpass(fs, 9000.0, 0.7071);
    eq[2].c = ro::designPeaking(fs, r.range(1500.0f, 3500.0f), 1.2, r.range(3.0f, 6.0f));

    const float gains[kModes] = {1.0f, r.range(0.6f, 0.8f), r.range(0.45f, 0.65f), r.range(0.35f, 0.5f)};
    for (int m = 0; m < kModes; ++m) {
        const double f = 300.0 * std::pow(3500.0 / 300.0, r.uniform());
        modes[m].c = ro::designBandpass(fs, f, r.range(50.0f, 110.0f));
        modeGain[m] = gains[m];
    }
    direct = 0.12;

    const double delayS = r.range(0.003f, 0.012f);  // within the 2..25 ms spec
    delaySamples = std::max(kSubBlock + 1, static_cast<int>(std::lround(delayS * fs)));
    delay.assign(static_cast<size_t>(delaySamples + 2 * kSubBlock + 8), 0.0f);
    writePos = 0;
    mic.assign(kSubBlock, 0.0f);
    mon.assign(kSubBlock, 0.0f);

    const double peak = calibrate(fs);
    calibration = peak > 1e-9 ? 1.0 / peak : 1.0;
    gain = static_cast<float>(calibration * std::pow(10.0, loopDb.load() / 20.0));
}

// Largest open-loop magnitude at a 0-phase crossing (Nyquist: the bypass loop
// oscillates as soon as that magnitude exceeds 1).
double SimChannel::calibrate(double fs) const {
    const int kGrid = 1 << 18;
    const double f0 = 40.0, f1 = fs * 0.45;
    double best = 0.0;
    cd prev{};
    double prevMag = 0;
    for (int i = 0; i <= kGrid; ++i) {
        const double f = f0 + (f1 - f0) * i / kGrid;
        const double w = ro::kTwoPi * f / fs;
        cd roomR = direct;
        for (int m = 0; m < kModes; ++m) roomR += modeGain[m] * response(modes[m].c, w);
        cd l = roomR * std::polar(1.0, -w * delaySamples);
        for (const auto& b : eq) l *= response(b.c, w);
        const double mag = std::abs(l);
        if (i > 0 && ((prev.imag() <= 0) != (l.imag() <= 0)) && (prev.real() + l.real()) > 0) {
            const double t = prev.imag() / (prev.imag() - l.imag());
            best = std::max(best, prevMag + (mag - prevMag) * t);
        }
        prev = l;
        prevMag = mag;
    }
    return best;
}

}  // namespace

struct ro_sim {
    double fs = 48000;
    int channels = 1;
    SimChannel ch[RO_MAX_CHANNELS];
    float gainCoef = 0.0f;
};

extern "C" {

ro_sim* ro_sim_create(double sample_rate, int channels, uint32_t seed) {
    if (!(sample_rate >= 8000.0 && sample_rate <= 384000.0) || channels < 1 || channels > RO_MAX_CHANNELS)
        return nullptr;
    auto* s = new (std::nothrow) ro_sim();
    if (!s) return nullptr;
    s->fs = sample_rate;
    s->channels = channels;
    s->gainCoef = static_cast<float>(1.0 - std::exp(-1.0 / (0.02 * sample_rate)));
    for (int c = 0; c < channels; ++c) s->ch[c].build(sample_rate, seed * 31u + static_cast<uint32_t>(c) * 7u + 1u);
    return s;
}

void ro_sim_destroy(ro_sim* s) { delete s; }

void ro_sim_set_loop_gain_db(ro_sim* s, int channel, float db) {
    if (!s || !ro::isFiniteF(db)) return;
    db = ro::clampv(db, -60.0f, 24.0f);
    for (int c = 0; c < s->channels; ++c)
        if (channel < 0 || channel == c) s->ch[c].loopDb.store(db, std::memory_order_relaxed);
}

void ro_sim_set_source(ro_sim* s, int channel, ro_sim_source src) {
    if (!s || src < RO_SIM_SPEECH || src > RO_SIM_SILENCE) return;
    for (int c = 0; c < s->channels; ++c)
        if (channel < 0 || channel == c) s->ch[c].source.store(src, std::memory_order_relaxed);
}

void ro_sim_render(ro_sim* s, ro_engine* e, float* const* monitor, int frames) {
    if (!s || frames <= 0) return;
    const bool useEngine = e && e->prepared.load(std::memory_order_relaxed);
    const int engineChannels = useEngine ? e->channels.load(std::memory_order_relaxed) : 0;
    int block = kSubBlock;
    if (useEngine) block = std::min(block, e->maxFrames);

    float zeros[kSubBlock] = {};
    float scratch[kSubBlock];
    int done = 0;
    while (done < frames) {
        const int n = std::min(block, frames - done);

        // 1. Mic = talker + noise + acoustic feedback (delayed PA output through the room).
        for (int c = 0; c < s->channels; ++c) {
            SimChannel& ch = s->ch[c];
            const int src = ch.source.load(std::memory_order_relaxed);
            if (src != ch.activeSource) {
                ch.talker.setSource(src);
                ch.activeSource = src;
            }
            const int len = static_cast<int>(ch.delay.size());
            for (int i = 0; i < n; ++i) {
                int rp = ch.writePos + i - ch.delaySamples;
                if (rp < 0) rp += len;
                const float fb = ch.room(ch.delay[rp]);
                const float white = ch.noiseRng.bipolar();
                ch.noiseLp += (white - ch.noiseLp) * 0.1f;
                const float noise = ch.noiseLp * ch.noiseGain;
                ch.mic[i] = adcClip(ch.talker.next() + noise + fb);
            }
        }

        // 2. Engine (or a straight wire when bypassed / not prepared).
        const float* in[RO_MAX_CHANNELS];
        float* out[RO_MAX_CHANNELS];
        for (int c = 0; c < RO_MAX_CHANNELS; ++c) {
            in[c] = c < s->channels ? s->ch[c].mic.data() : zeros;
            out[c] = c < s->channels ? s->ch[c].mon.data() : scratch;
        }
        if (useEngine) ro_engine_process(e, in, out, n);
        for (int c = engineChannels; c < s->channels; ++c)
            std::memcpy(s->ch[c].mon.data(), s->ch[c].mic.data(), sizeof(float) * n);

        // 3. Console gain + PA EQ into the loop delay line; monitor out.
        for (int c = 0; c < s->channels; ++c) {
            SimChannel& ch = s->ch[c];
            const float target = static_cast<float>(ch.calibration * std::pow(10.0, ch.loopDb.load(std::memory_order_relaxed) / 20.0));
            const int len = static_cast<int>(ch.delay.size());
            for (int i = 0; i < n; ++i) {
                ch.gain += (target - ch.gain) * s->gainCoef;
                const float m = ro::isFiniteF(ch.mon[i]) ? ch.mon[i] : 0.0f;
                int wp = ch.writePos + i;
                if (wp >= len) wp -= len;
                ch.delay[wp] = ch.pa(m * ch.gain);
                if (monitor && monitor[c]) monitor[c][done + i] = m;
            }
            ch.writePos += n;
            if (ch.writePos >= len) ch.writePos -= len;
            ch.sanitizeState();
        }
        done += n;
    }
}

}  // extern "C"
