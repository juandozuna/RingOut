#include "Channel.hpp"

namespace ro {

namespace {
constexpr float kInputLimit = 32.0f;          // +30 dBFS: anything beyond is not audio
constexpr float kLimiterCeiling = 0.96605f;   // -0.3 dBFS
constexpr float kClipLevel = 0.94406f;        // -0.5 dBFS
constexpr double kRingStateHoldS = 2.0;
constexpr double kPeakHoldS = 2.0;
constexpr float kPeakHoldFallDbPerS = 20.0f;
constexpr double kIsolatorFadeS = 0.05;       // cross-fade on mode change (>= the TCN receptive field)

// Isolator mode when RO_PARAM_ISOLATOR was never set. It only applies with
// trained weights: the placeholder (random-init) export defaults to the DSP
// stand-in. Neural modes also fall back to DSP whenever the model cannot run
// (sample rate != 48 kHz).
constexpr ro_isolator kDefaultIsolator = RO_ISOLATOR_NEURAL;
}  // namespace

Channel::Channel() : neural_(std::make_unique<NeuralIsolator>()), dsp_(makeIsolator()) {}

bool Channel::prepare(double fs, int maxFrames, int index) {
    fs_ = fs;
    index_ = index;
    maxFrames_ = maxFrames;
    dryRaw_.assign(maxFrames, 0.0f);
    dry_.assign(maxFrames, 0.0f);
    cond_.assign(maxFrames, 0.0f);
    wet_.assign(maxFrames, 0.0f);
    stage_.assign(maxFrames, 0.0f);

    if (!det_.prepare(fs)) return false;
    notches_.prepare(fs);
    if (!dsp_ || !dsp_->prepare(fs, maxFrames)) return false;
    neural_->prepare(fs, maxFrames);  // false = model not valid here; usable() gates it

    dcR_ = 1.0 - kTwoPi * 5.0 / fs;  // ~5 Hz DC blocker
    dcX1_ = dcY1_ = 0;
    hpf_.c = designHighpass(fs, 80.0, 0.70710678);
    hpf_.reset();

    trim_.setLength(64);
    strength_.setLength(64);
    hpfMix_.setLength(64);
    const int isoFade = std::max(1, static_cast<int>(std::lround(kIsolatorFadeS * fs)));
    neuralMix_.setLength(isoFade);
    dspMix_.setLength(isoFade);
    mute_.setLength(std::max(1, static_cast<int>(std::lround(0.005 * fs))));
    applyParams(true);

    cDW_ = cDD_ = cWW_ = 1e-9;
    rho_ = 1.0f;
    sCached_ = -1.0f;
    limGain_ = 1.0f;
    limRel_ = static_cast<float>(1.0 - std::exp(-1.0 / (0.08 * fs)));
    powCoef_ = 0.0f;
    frames_ = 0;
    resetMeters();
    inPeakAcc_ = outPeakAcc_ = 0;
    inPow_ = outPow_ = 0;
    grDry_ = grOut_ = 0;
    multiTalker_ = 0;
    multiTalkerOn_ = false;
    isoActivity_ = 0;
    publishInterval_ = std::max(1, static_cast<int>(0.005 * fs));
    sincePublish_ = publishInterval_;
    prepared_ = true;
    return true;
}

void Channel::applyParams(bool snap) {
    const float trimGain = dbToAmp(p_.trimDb);
    const float trim = p_.trimDb == 0.0f ? 1.0f : trimGain;
    const float s = p_.bypass ? 0.0f : p_.strength;
    const float m = p_.mute ? 0.0f : 1.0f;
    const float h = p_.highpass ? 1.0f : 0.0f;
    if (snap) {
        trim_.snap(trim);
        strength_.snap(s);
        mute_.snap(m);
        hpfMix_.snap(h);
    } else {
        trim_.set(trim);
        strength_.set(s);
        mute_.set(m);
        hpfMix_.set(h);
    }
    // Isolator stages. A stage that was fully off restarts from a clean state.
    const ro_isolator iso = activeIsolator();
    const float nOn = iso != RO_ISOLATOR_DSP ? 1.0f : 0.0f;
    const float dOn = iso != RO_ISOLATOR_NEURAL ? 1.0f : 0.0f;
    if (snap) {
        neuralMix_.snap(nOn);
        dspMix_.snap(dOn);
    } else {
        if (nOn == 1.0f && neuralMix_.target == 0.0f && neuralMix_.settled()) neural_->reset();
        if (dOn == 1.0f && dspMix_.target == 0.0f && dspMix_.settled()) dsp_->reset();
        neuralMix_.set(nOn);
        dspMix_.set(dOn);
    }
    det_.setPreset(p_.preset);
    neural_->setPreset(p_.preset);
    dsp_->setPreset(p_.preset);
    notches_.setSettings(NotchSettings{p_.holdS, p_.maxAuto, p_.ringOut});
}

void Channel::setParam(ro_param p, float v) {
    if (!isFiniteF(v)) return;
    switch (p) {
        case RO_PARAM_STRENGTH: p_.strength = clampv(v, 0.0f, 1.0f); break;
        case RO_PARAM_BYPASS: p_.bypass = v >= 0.5f; break;
        case RO_PARAM_MUTE: p_.mute = v >= 0.5f; break;
        case RO_PARAM_HIGHPASS: p_.highpass = v >= 0.5f; break;
        case RO_PARAM_LIMITER: p_.limiter = v >= 0.5f; break;
        case RO_PARAM_NOTCH_HOLD_S: p_.holdS = clampv(v, 2.0f, 10.0f); break;
        case RO_PARAM_MAX_AUTO_NOTCHES: p_.maxAuto = clampv(static_cast<int>(std::lround(v)), 4, 8); break;
        case RO_PARAM_PRESET: p_.preset = clampv(static_cast<int>(std::lround(v)), 0, 2); break;
        case RO_PARAM_RING_OUT_MODE: p_.ringOut = v >= 0.5f; break;
        case RO_PARAM_INPUT_TRIM_DB: p_.trimDb = clampv(v, -24.0f, 24.0f); break;
        case RO_PARAM_ISOLATOR: p_.isolator = clampv(static_cast<int>(std::lround(v)), 0, 2); break;
        default: return;
    }
    applyParams(!prepared_);
}

void Channel::command(ro_command c, float a, float b, EventQueue* q) {
    EventSink ev{q, index_, frames_};
    const int slot = isFiniteF(a) ? static_cast<int>(std::lround(a)) : -1;
    switch (c) {
        case RO_CMD_CLEAR_AUTO_NOTCHES: notches_.clearAuto(); break;
        case RO_CMD_PIN_NOTCH: notches_.pin(slot, ev); break;
        case RO_CMD_RELEASE_NOTCH: notches_.release(slot); break;
        case RO_CMD_ADD_FIXED_NOTCH: notches_.addFixed(a, b); break;
        case RO_CMD_MOVE_NOTCH: notches_.move(slot, b); break;
        case RO_CMD_RESET_METERS: resetMeters(); break;
        default: break;
    }
}

ro_isolator Channel::activeIsolator() const {
    const int mode = p_.isolator >= 0                       ? p_.isolator
                     : NeuralIsolator::placeholderWeights() ? RO_ISOLATOR_DSP
                                                            : kDefaultIsolator;
    if (mode != RO_ISOLATOR_DSP && !neural_->usable()) return RO_ISOLATOR_DSP;
    return static_cast<ro_isolator>(mode);
}

float Channel::runStage(Isolator& iso, LinearRamp& mix, int n, const IsolatorSide& side) {
    if (mix.settled() && mix.cur == 0.0f) return 0.0f;
    if (mix.settled() && mix.cur == 1.0f) {
        iso.process(wet_.data(), n, side);
        return iso.activity();
    }
    std::memcpy(stage_.data(), wet_.data(), sizeof(float) * n);
    iso.process(stage_.data(), n, side);
    for (int i = 0; i < n; ++i) {
        const float m = mix.next();
        wet_[i] += m * (stage_[i] - wet_[i]);
    }
    return iso.activity() * mix.cur;
}

void Channel::resetMeters() {
    inClip_ = outClip_ = false;
    inHold_ = outHold_ = -120.0f;
    inHoldT_ = outHoldT_ = det_.now();
}

void Channel::meterBlock(const float* x, int n, float& peakAcc, float& powEwma, bool& clip) {
    float mx = 0.0f, ms = 0.0f;
    vDSP_maxmgv(x, 1, &mx, static_cast<vDSP_Length>(n));
    vDSP_measqv(x, 1, &ms, static_cast<vDSP_Length>(n));
    if (!isFiniteF(mx)) mx = kInputLimit;
    if (!isFiniteF(ms)) ms = kInputLimit * kInputLimit;
    peakAcc = std::max(peakAcc, mx);
    // 300 ms RMS integration.
    const float a = static_cast<float>(std::exp(-n / (0.3 * fs_)));
    powEwma = a * powEwma + (1.0f - a) * ms;
    if (mx >= kClipLevel) clip = true;
}

void Channel::process(const float* in, float* out, int n, EventQueue* q) {
    // 1. Input trim. dryRaw keeps the exact bits for the bypass / strength 0 path.
    for (int i = 0; i < n; ++i) {
        const float t = trim_.next();
        const float v = in[i];
        dryRaw_[i] = t == 1.0f ? v : v * t;
        dry_[i] = sanitize(dryRaw_[i], kInputLimit);
    }
    meterBlock(dry_.data(), n, inPeakAcc_, inPow_, inClip_);

    // 2. Input conditioning: DC block, 80 Hz high-pass (cross-faded when toggled).
    for (int i = 0; i < n; ++i) {
        const double x = dry_[i];
        const double y = x - dcX1_ + dcR_ * dcY1_;
        dcX1_ = x;
        dcY1_ = y;
        const double h = hpf_.tick(y);
        const float m = hpfMix_.next();
        cond_[i] = static_cast<float>(m == 1.0f ? h : (m == 0.0f ? y : m * h + (1.0f - m) * y));
    }
    if (!isFiniteD(dcY1_) || !hpf_.stateFinite()) {
        dcX1_ = dcY1_ = 0;
        hpf_.reset();
    }

    // 3. Detector (analysis copy only).
    const bool newFrame = det_.process(cond_.data(), n);

    // 4. Notch bank.
    EventSink ev{q, index_, frames_};
    notches_.update(det_, newFrame, ev);
    std::memcpy(wet_.data(), cond_.data(), sizeof(float) * n);
    notches_.process(wet_.data(), n);

    // 5. Isolator chain (neural, then DSP), conditioned on the detector's side vector.
    const IsolatorSide side{&det_.side(), &notches_, newFrame};
    const float act = std::max(runStage(*neural_, neuralMix_, n, side), runStage(*dsp_, dspMix_, n, side));
    isoActivity_ = std::max(act, isoActivity_ * 0.995f);

    // 6. Strength mix (equal power for the measured dry/wet correlation, so the
    //    level is flat for both coherent and decorrelated wet), limiter, mute.
    double sdw = 0, sdd = 0, sww = 0;
    for (int i = 0; i < n; ++i) {
        const double d = dry_[i], w = wet_[i];
        sdw += d * w; sdd += d * d; sww += w * w;
    }
    const bool ringActive = notches_.loopGainWarning() || det_.now() - notches_.lastRingTime() < kRingStateHoldS;
    {
        const double a = std::exp(-n / (0.3 * fs_));
        if (sdd > 1e-12 * n && !ringActive) {
            cDW_ = a * cDW_ + (1 - a) * sdw;
            cDD_ = a * cDD_ + (1 - a) * sdd;
            cWW_ = a * cWW_ + (1 - a) * sww;
            const double r = cDW_ / std::sqrt(cDD_ * cWW_ + 1e-30);
            rho_ = static_cast<float>(clampv(r, 0.0, 1.0));
            sCached_ = -1.0f;
        }
    }

    double eDry = 0, eOut = 0;
    for (int i = 0; i < n; ++i) {
        const float s = strength_.next();
        const float m = mute_.next();
        float y;
        if (s == 0.0f) {
            y = dryRaw_[i];
        } else {
            if (s != sCached_) {
                const float u = 1.0f - s;
                kCached_ = 1.0f / std::sqrt(u * u + s * s + 2.0f * s * u * rho_);
                sCached_ = s;
            }
            const float k = kCached_;
            y = (1.0f - s) * k * dry_[i] + s * k * wet_[i];
            if (p_.limiter) {
                const float ay = std::fabs(y);
                const float target = ay > kLimiterCeiling ? kLimiterCeiling / ay : 1.0f;
                limGain_ += (1.0f - limGain_) * limRel_;
                if (target < limGain_) limGain_ = target;
                y *= limGain_;
                y = clampv(y, -kLimiterCeiling, kLimiterCeiling);
            }
        }
        if (m != 1.0f) y = m == 0.0f ? 0.0f : y * m;
        out[i] = y;
        const double dd = dry_[i];
        const double yy = isFiniteF(y) ? y : 0.0;
        eDry += dd * dd;
        eOut += yy * yy;
    }
    {
        const double a = std::exp(-n / (0.3 * fs_));
        grDry_ = a * grDry_ + (1 - a) * eDry;
        grOut_ = a * grOut_ + (1 - a) * eOut;
    }
    meterBlock(out, n, outPeakAcc_, outPow_, outClip_);

    frames_ += static_cast<uint64_t>(n);
    sincePublish_ += n;
}

void Channel::fillSnapshot(ro_channel_snapshot& s) {
    const double now = det_.now();
    sincePublish_ = 0;

    auto holdUpdate = [&](float peakDb, float& hold, double& holdT) {
        if (peakDb >= hold) {
            hold = peakDb;
            holdT = now;
        } else if (now - holdT > kPeakHoldS) {
            const float fallen = hold - kPeakHoldFallDbPerS * static_cast<float>(now - holdT - kPeakHoldS);
            hold = std::max(peakDb, fallen);
            if (hold == peakDb) holdT = now;
        }
    };

    s.input_peak_db = ampToDb(inPeakAcc_);
    s.output_peak_db = ampToDb(outPeakAcc_);
    inPeakAcc_ = outPeakAcc_ = 0.0f;
    holdUpdate(s.input_peak_db, inHold_, inHoldT_);
    holdUpdate(s.output_peak_db, outHold_, outHoldT_);
    s.input_peak_hold_db = inHold_;
    s.output_peak_hold_db = outHold_;
    s.input_rms_db = powToDb(inPow_);
    s.output_rms_db = powToDb(outPow_);
    s.input_clip = inClip_;
    s.output_clip = outClip_;

    s.active_auto_notches = notches_.activeAuto();
    s.active_fixed_notches = notches_.activeFixed();
    notches_.fillInfo(s.notches, now);
    det_.logSpectrum(s.spectrum_db);

    const double ringT = notches_.lastRingTime();
    const bool everRang = ringT > -1e8;
    s.last_ring_hz = everRang ? notches_.lastRingHz() : 0.0f;
    s.last_ring_age_s = everRang ? static_cast<float>(now - ringT) : 1.0e6f;
    s.isolator_activity = clampv(isoActivity_, 0.0f, 1.0f);
    s.gain_reduction_db = grDry_ > 1e-12 ? std::min(0.0f, powToDb(static_cast<float>(grOut_ / grDry_))) : 0.0f;
    if (!isFiniteF(s.gain_reduction_db)) s.gain_reduction_db = 0.0f;
    s.loop_gain_warning = notches_.loopGainWarning();

    // Multi-talker: fraction of recent voiced frames with two harmonic series.
    {
        const float a = static_cast<float>(std::exp(-0.005 / 1.0));
        const bool multi = det_.multiTalkerFrame();
        if (inPow_ > 1e-7f) multiTalker_ = a * multiTalker_ + (1.0f - a) * (multi ? 1.0f : 0.0f);
        if (multiTalker_ > 0.2f) multiTalkerOn_ = true;
        else if (multiTalker_ < 0.1f) multiTalkerOn_ = false;
    }
    s.multi_talker = multiTalkerOn_;
    s.frames_processed = frames_;
    s.isolator = activeIsolator();

    if (p_.bypass || p_.mute) s.state = RO_STATE_BYPASS;
    else if (s.loop_gain_warning || (everRang && now - ringT < kRingStateHoldS)) s.state = RO_STATE_RING;
    else if (s.active_auto_notches > 0 || s.isolator_activity > 0.5f) s.state = RO_STATE_WORKING;
    else s.state = RO_STATE_SAFE;
}

}  // namespace ro
