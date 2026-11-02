// C API entry points.
#include "Engine.hpp"

#include <mach/mach_time.h>

#include <new>

using ro::ControlMsg;

namespace {

ro_channel_snapshot defaultSnapshot() {
    ro_channel_snapshot s{};
    s.input_peak_db = s.input_rms_db = s.input_peak_hold_db = -120.0f;
    s.output_peak_db = s.output_rms_db = s.output_peak_hold_db = -120.0f;
    s.state = RO_STATE_SAFE;
    for (float& v : s.spectrum_db) v = -120.0f;
    s.last_ring_age_s = 1.0e6f;
    for (int i = 0; i < RO_MAX_NOTCHES; ++i) s.notches[i].fixed = i >= RO_MAX_AUTO_NOTCHES;
    return s;
}

}  // namespace

void ro_engine::drainControl() {
    ControlMsg m;
    while (control.pop(m)) {
        const int lo = m.channel < 0 ? 0 : m.channel;
        const int hi = m.channel < 0 ? RO_MAX_CHANNELS - 1 : m.channel;
        for (int c = lo; c <= hi && c < RO_MAX_CHANNELS; ++c) {
            if (m.isCommand) channel[c].command(static_cast<ro_command>(m.id), m.a, m.b, &events);
            else channel[c].setParam(static_cast<ro_param>(m.id), m.a);
        }
    }
}

void ro_engine::publish(int c) {
    channel[c].fillSnapshot(snapshot[c].writeBuffer());
    snapshot[c].publish();
}

extern "C" {

ro_engine* ro_engine_create(void) {
    auto* e = new (std::nothrow) ro_engine();
    if (!e) return nullptr;
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    e->secondsPerTick = tb.denom ? 1e-9 * tb.numer / tb.denom : 1e-9;
    const ro_channel_snapshot s = defaultSnapshot();
    for (auto& b : e->snapshot) b.fill(s);
    return e;
}

void ro_engine_destroy(ro_engine* e) { delete e; }

bool ro_engine_prepare(ro_engine* e, double sample_rate, int max_frames, int channels) {
    if (!e) return false;
    if (!(sample_rate >= 8000.0 && sample_rate <= 384000.0)) return false;
    if (max_frames < 1 || max_frames > RO_MAX_FRAMES) return false;
    if (channels < 1 || channels > RO_MAX_CHANNELS) return false;
    e->prepared.store(false);
    e->drainControl();  // parameters set before prepare take effect now
    for (int c = 0; c < RO_MAX_CHANNELS; ++c)
        if (!e->channel[c].prepare(sample_rate, max_frames, c)) return false;
    e->sampleRate = sample_rate;
    e->maxFrames = max_frames;
    e->channels.store(channels);
    e->load.store(0.0f, std::memory_order_relaxed);
    for (int c = 0; c < channels; ++c) e->publish(c);
    e->prepared.store(true);
    return true;
}

void ro_engine_process(ro_engine* e, const float* const* in, float* const* out, int frames) {
    if (!e || !e->prepared || !in || !out || frames <= 0) return;
    const uint64_t t0 = mach_absolute_time();
    e->drainControl();
    int done = 0;
    while (done < frames) {
        const int n = std::min(frames - done, e->maxFrames);
        const int nch = e->channels.load(std::memory_order_relaxed);
        for (int c = 0; c < nch; ++c) {
            if (!in[c] || !out[c]) continue;
            e->channel[c].process(in[c] + done, out[c] + done, n, &e->events);
            if (e->channel[c].publishDue()) e->publish(c);
        }
        done += n;
    }
    const uint64_t t1 = mach_absolute_time();
    const double period = frames / e->sampleRate;
    e->load.store(static_cast<float>((t1 - t0) * e->secondsPerTick / period), std::memory_order_relaxed);
}

void ro_engine_set_param(ro_engine* e, int channel, ro_param p, float value) {
    if (!e || channel < -1 || channel >= RO_MAX_CHANNELS) return;
    ControlMsg m;
    m.isCommand = 0;
    m.channel = static_cast<int8_t>(channel);
    m.id = static_cast<int16_t>(p);
    m.a = value;
    e->control.push(m);
}

void ro_engine_command(ro_engine* e, int channel, ro_command cmd, float a, float b) {
    if (!e || channel < -1 || channel >= RO_MAX_CHANNELS) return;
    ControlMsg m;
    m.isCommand = 1;
    m.channel = static_cast<int8_t>(channel);
    m.id = static_cast<int16_t>(cmd);
    m.a = a;
    m.b = b;
    e->control.push(m);
}

bool ro_engine_read_snapshot(ro_engine* e, int channel, ro_channel_snapshot* out) {
    if (!e || !out) return false;
    const int limit = e->prepared.load() ? e->channels.load() : RO_MAX_CHANNELS;
    if (channel < 0 || channel >= limit) return false;
    *out = e->snapshot[channel].read();
    return true;
}

float ro_engine_dsp_load(ro_engine* e) { return e ? e->load.load(std::memory_order_relaxed) : 0.0f; }

bool ro_engine_pop_event(ro_engine* e, ro_event* out) {
    if (!e || !out) return false;
    return e->events.pop(*out);
}

}  // extern "C"
