#include "NotchBank.hpp"

namespace ro {

namespace {
constexpr float kNotchThreshold = 0.7f;
constexpr float kDeepenThreshold = 0.9f;
// A candidate sitting on an existing notch only needs this much confidence to
// count as "still ringing" (the notch is strong prior evidence).
constexpr float kNotchedThreshold = 0.5f;
constexpr float kReleaseDropDb = 12.0f;
constexpr double kQuietBeforeRelease = 2.0;
constexpr double kDrainS = 0.1;          // keep filtering briefly at 0 dB so state decays
constexpr double kReappearWindow = 0.5;
constexpr int kReappearTrips = 3;
constexpr int kMaxActiveBeforeWarning = 6;
constexpr double kWarningHoldS = 10.0;
constexpr double kMemoryS = 10.0;

inline float matchTolerance(float f) { return std::max(1.5f, f / 200.0f); }
}  // namespace

void NotchBank::prepare(double fs) {
    fs_ = fs;
    now_ = 0;
    for (int i = 0; i < kSlots; ++i) {
        Slot& s = slots_[i];
        const bool keep = i >= kAuto && (s.phase == Phase::Hold || s.phase == Phase::Releasing);
        if (!keep) {
            s = Slot{};
            continue;
        }
        s.phase = Phase::Hold;
        s.fixed = true;
        s.freq = clampv(s.freq, 20.0f, static_cast<float>(fs * 0.45));
        s.created = 0;
        s.filt.reset();
        refreshCoeffs(s, true);
    }
    for (auto& m : memory_) m = Memory{};
    reappear_ = 0;
    lastRemoval_ = -1e9;
    tripUntil_ = -1;
    warning_ = false;
    lastRingTime_ = -1e9;
    lastRingHz_ = 0.0f;
}

void NotchBank::clearAuto() {
    for (int i = 0; i < kAuto; ++i) {
        Slot& s = slots_[i];
        if (s.phase == Phase::Hold || s.phase == Phase::Releasing) {
            s.depth = 0.0f;
            s.phase = Phase::Draining;
            s.drainUntil = now_ + kDrainS;
            s.killed = true;
        }
    }
}

void NotchBank::setSettings(const NotchSettings& s) { set_ = s; }

int NotchBank::findNear(float f, float tolHz) const {
    int best = -1;
    float bestD = tolHz;
    for (int i = 0; i < kSlots; ++i) {
        const Slot& s = slots_[i];
        if (s.phase == Phase::Off || s.killed) continue;
        if (s.fixed && !set_.ringOutMode) continue;  // outside ring-out, fixed notches are left alone
        const float d = std::fabs(s.freq - f);
        if (d <= bestD) { bestD = d; best = i; }
    }
    return best;
}

int NotchBank::freeSlot(bool fixed) const {
    if (fixed) {
        for (int i = kAuto; i < kSlots; ++i)
            if (slots_[i].phase == Phase::Off) return i;
        return -1;
    }
    if (activeAuto() >= set_.maxAuto) return -1;
    for (int i = 0; i < kAuto; ++i)
        if (slots_[i].phase == Phase::Off) return i;
    return -1;
}

void NotchBank::refreshCoeffs(Slot& s, bool snap) {
    if (!snap && std::fabs(s.depth - s.appliedDepth) < 0.02f && s.freq == s.appliedFreq) return;
    const BiquadCoeffs c = designPeaking(fs_, s.freq, kQ, s.depth);
    if (snap) s.filt.snap(c);
    else s.filt.setTarget(c, 64);
    s.appliedDepth = s.depth;
    s.appliedFreq = s.freq;
}

void NotchBank::place(int idx, float freq, float depth, bool fixed, double now) {
    Slot& s = slots_[idx];
    s = Slot{};
    s.phase = Phase::Hold;
    s.fixed = fixed;
    s.freq = clampv(freq, 20.0f, static_cast<float>(fs_ * 0.45));
    s.created = now;
    s.lastDeepen = now;
    // Start from an identity filter at the same centre and glide in over 64 samples.
    s.depth = 0.0f;
    refreshCoeffs(s, true);
    s.depth = depth;
    refreshCoeffs(s, false);
}

void NotchBank::noteRing(float f, double now) {
    lastRingTime_ = now;
    lastRingHz_ = f;
}

void NotchBank::deepen(Slot& s, float level, double now, float conf, const EventSink& ev) {
    s.depth = std::max(kMaxDepth, s.depth - kDeepenStep);
    s.lastDeepen = now;
    s.levelAtDeepen = level;
    ev.emit(RO_EVENT_NOTCH_DEEPENED, s.freq, conf, s.depth, 0.0f);
    noteRing(s.freq, now);
}

bool NotchBank::pinToFixed(int autoSlot, double now, const EventSink& ev) {
    const int dst = freeSlot(true);
    if (dst < 0) return false;
    Slot& a = slots_[autoSlot];
    if (a.phase == Phase::Releasing) {
        a.depth = a.holdDepth;
        a.phase = Phase::Hold;
    }
    if (a.phase != Phase::Hold) return false;
    slots_[dst] = a;  // filter state moves with it: no transient
    slots_[dst].fixed = true;
    a = Slot{};
    ev.emit(RO_EVENT_NOTCH_PINNED, slots_[dst].freq, 1.0f, slots_[dst].depth, static_cast<float>(now - slots_[dst].created));
    return true;
}

void NotchBank::update(const FeedbackDetector& det, bool newFrame, const EventSink& ev) {
    now_ = det.now();
    const double now = now_;

    if (newFrame) {
        const SideVector& sv = det.side();
        for (int i = 0; i < sv.count; ++i) {
            const Candidate& c = sv.c[i];
            if (c.conf < kNotchedThreshold) break;  // sorted by confidence
            const int idx = findNear(c.freq, matchTolerance(c.freq));
            if (idx < 0 && c.conf < kNotchThreshold) continue;
            if (idx >= 0) {
                Slot& s = slots_[idx];
                s.maxLevel = std::max(s.maxLevel, c.levelDb);
                s.quietSince = -1;
                if ((s.phase == Phase::Releasing || s.phase == Phase::Draining) && c.conf >= kNotchThreshold) {
                    // The ring came back while the notch was letting go.
                    s.depth = std::min(s.holdDepth, kInitialDepth);
                    s.phase = Phase::Hold;
                    s.lastDeepen = now;
                    s.levelAtDeepen = c.levelDb;
                    ++reappear_;
                    ev.emit(RO_EVENT_RING_DETECTED, s.freq, c.conf, s.depth, 0.0f);
                    noteRing(s.freq, now);
                    continue;
                }
                if (!s.fixed && now - s.created < 0.3 && std::fabs(c.freq - s.freq) > 0.2f)
                    s.freq += 0.5f * (c.freq - s.freq);  // refine a young notch onto the ring
                const bool canDeepen = s.depth > kMaxDepth && (!s.fixed || set_.ringOutMode);
                if (canDeepen) {
                    const double interval = c.growth > 10.0f ? 0.02 : 0.04;
                    const bool growing = c.conf >= kDeepenThreshold && now - s.lastDeepen >= interval && c.growth > -0.5f;
                    const bool stuck = s.phase == Phase::Hold && c.conf >= 0.6f && now - s.lastDeepen >= 0.25 &&
                                       c.levelDb >= s.levelAtDeepen - 3.0f;
                    if (growing || stuck) deepen(s, c.levelDb, now, c.conf, ev);
                }
                if (set_.ringOutMode && !s.fixed && (c.conf >= kDeepenThreshold || s.depth <= kInitialDepth - kDeepenStep))
                    pinToFixed(idx, now, ev);
                continue;
            }

            // New ring.
            int slot = freeSlot(false);
            if (slot < 0) {
                // Recycle the auto notch that is closest to being gone.
                float shallowest = 0.0f;
                for (int k = 0; k < kAuto; ++k) {
                    const Slot& s = slots_[k];
                    if ((s.phase == Phase::Releasing || s.phase == Phase::Draining) &&
                        (slot < 0 || s.depth > shallowest)) {
                        slot = k;
                        shallowest = s.depth;
                    }
                }
            }
            if (slot < 0) continue;
            float depth = kInitialDepth;
            for (const Memory& m : memory_)
                if (now - m.time < kMemoryS && std::fabs(m.freq - c.freq) <= 2.0f * matchTolerance(c.freq))
                    depth = std::min(depth, m.depth);
            place(slot, c.freq, depth, false, now);
            slots_[slot].maxLevel = c.levelDb;
            slots_[slot].levelAtDeepen = c.levelDb;
            if (now - lastRemoval_ <= kReappearWindow) ++reappear_;
            else reappear_ = 0;
            ev.emit(RO_EVENT_RING_DETECTED, slots_[slot].freq, c.conf, depth, 0.0f);
            noteRing(slots_[slot].freq, now);
        }

        // Release tracking: a notch lets go once its ring has been 12 dB below
        // its maximum for 2 s. Only feedback-like tracks count as "the ring".
        for (int i = 0; i < kAuto; ++i) {
            Slot& s = slots_[i];
            if (s.phase != Phase::Hold) continue;
            const float lvl = det.ringLevelNear(s.freq, matchTolerance(s.freq), 0.5f);
            if (lvl > -120.0f) s.maxLevel = std::max(s.maxLevel, lvl);
            if (lvl < s.maxLevel - kReleaseDropDb) {
                if (s.quietSince < 0) s.quietSince = now;
                else if (now - s.quietSince >= kQuietBeforeRelease && !warning_) {
                    s.phase = Phase::Releasing;
                    s.releaseStart = now;
                    s.holdDepth = s.depth;
                }
            } else {
                s.quietSince = -1;
            }
        }

        // Respect a lowered max-auto-notches setting: let the oldest extras go.
        int excess = activeAuto() - set_.maxAuto;
        while (excess-- > 0) {
            int oldest = -1;
            for (int i = 0; i < kAuto; ++i)
                if (slots_[i].phase == Phase::Hold && (oldest < 0 || slots_[i].created < slots_[oldest].created))
                    oldest = i;
            if (oldest < 0) break;
            slots_[oldest].phase = Phase::Releasing;
            slots_[oldest].releaseStart = now;
            slots_[oldest].holdDepth = slots_[oldest].depth;
            slots_[oldest].killed = true;  // forced: not revived by the guard or detection
        }
    }

    // Ramps. While the oscillation guard is tripped the loop is known to be
    // above its limit, so notches hold instead of letting go.
    for (int i = 0; i < kSlots; ++i) {
        Slot& s = slots_[i];
        if (s.phase == Phase::Releasing && warning_ && !s.killed) {
            s.phase = Phase::Hold;
            s.depth = s.holdDepth;
            s.quietSince = -1;
        }
        if (s.phase == Phase::Releasing) {
            const double frac = (now - s.releaseStart) / std::max(0.1f, set_.holdS);
            if (frac >= 1.0) {
                s.depth = 0.0f;
                s.phase = Phase::Draining;
                s.drainUntil = now + kDrainS;
                lastRemoval_ = now;
                memory_[memoryNext_] = Memory{s.freq, s.holdDepth, now};
                memoryNext_ = (memoryNext_ + 1) % kMemory;
                ev.emit(RO_EVENT_NOTCH_RELEASED, s.freq, 0.0f, s.holdDepth, static_cast<float>(now - s.created));
            } else {
                s.depth = static_cast<float>(s.holdDepth * (1.0 - frac));
            }
        } else if (s.phase == Phase::Draining && now >= s.drainUntil) {
            s = Slot{};
            continue;
        }
        if (s.phase != Phase::Off) refreshCoeffs(s, false);
    }

    // Oscillation guard.
    if (reappear_ >= kReappearTrips) {
        tripUntil_ = now + kWarningHoldS;
        reappear_ = 0;
    }
    const bool warn = activeAuto() > kMaxActiveBeforeWarning || now < tripUntil_;
    if (warn && !warning_) ev.emit(RO_EVENT_LOOP_GAIN_WARNING, lastRingHz_, 1.0f, 0.0f, 0.0f);
    warning_ = warn;
}

void NotchBank::process(float* x, int n) {
    bool any = false;
    for (const Slot& s : slots_)
        if (s.phase != Phase::Off) { any = true; break; }
    if (!any) return;

    double buf[RO_MAX_FRAMES];
    for (int i = 0; i < n; ++i) buf[i] = x[i];
    for (Slot& s : slots_) {
        if (s.phase == Phase::Off) continue;
        SmoothBiquad& f = s.filt;
        for (int i = 0; i < n; ++i) buf[i] = f.tick(buf[i]);
        if (!f.stateFinite()) f.reset();
    }
    for (int i = 0; i < n; ++i) x[i] = static_cast<float>(buf[i]);
}

void NotchBank::pin(int slot, const EventSink& ev) {
    if (slot < 0 || slot >= kAuto) return;
    pinToFixed(slot, now_, ev);
}

void NotchBank::release(int slot) {
    if (slot < 0 || slot >= kSlots) return;
    Slot& s = slots_[slot];
    if (s.phase != Phase::Hold && s.phase != Phase::Releasing) return;
    s.depth = 0.0f;
    s.phase = Phase::Draining;
    s.drainUntil = now_ + kDrainS;
    s.killed = true;
}

bool NotchBank::addFixed(float freq, float depthDb) {
    if (!isFiniteF(freq) || !isFiniteF(depthDb)) return false;
    const int idx = freeSlot(true);
    if (idx < 0) return false;
    place(idx, freq, clampv(depthDb, kFixedMinDepth, 0.0f), true, now_);
    return true;
}

void NotchBank::move(int slot, float freq) {
    if (slot < 0 || slot >= kSlots || !isFiniteF(freq)) return;
    Slot& s = slots_[slot];
    if (s.phase != Phase::Hold && s.phase != Phase::Releasing) return;
    s.freq = clampv(freq, 20.0f, static_cast<float>(fs_ * 0.45));
}

bool NotchBank::hasNotchNear(float f) const {
    for (const Slot& s : slots_)
        if ((s.phase == Phase::Hold || s.phase == Phase::Releasing) && std::fabs(s.freq - f) <= std::max(2.0f, f / 100.0f))
            return true;
    return false;
}

int NotchBank::activeAuto() const {
    int n = 0;
    for (int i = 0; i < kAuto; ++i)
        if (slots_[i].phase == Phase::Hold || slots_[i].phase == Phase::Releasing) ++n;
    return n;
}

int NotchBank::activeFixed() const {
    int n = 0;
    for (int i = kAuto; i < kSlots; ++i)
        if (slots_[i].phase == Phase::Hold || slots_[i].phase == Phase::Releasing) ++n;
    return n;
}

void NotchBank::fillInfo(ro_notch_info* out, double now) const {
    for (int i = 0; i < kSlots; ++i) {
        const Slot& s = slots_[i];
        const bool active = s.phase == Phase::Hold || s.phase == Phase::Releasing;
        out[i].frequency_hz = active ? s.freq : 0.0f;
        out[i].depth_db = active ? std::min(0.0f, s.depth) : 0.0f;
        out[i].age_s = active ? static_cast<float>(std::max(0.0, now - s.created)) : 0.0f;
        out[i].fixed = i >= kAuto;
        out[i].active = active;
    }
}

}  // namespace ro
