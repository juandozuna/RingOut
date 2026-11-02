#include "RenderGlue.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define IO_MAX_CH 2
#define CLICKS 5

struct ro_io {
    AudioComponentInstance unit;
    ro_engine *engine;
    ro_sim *sim;
    ro_io_mode mode;
    int io_channels;
    int engine_channels;
    double sample_rate;

    float *in_buf[IO_MAX_CH];
    AudioBufferList *in_list;

    _Atomic bool monitor_audible;
    _Atomic bool muted;
    float out_gain;          // audio thread only
    float fade_step;

    _Atomic uint64_t callbacks;
    _Atomic uint32_t last_frames;
    _Atomic uint32_t render_errors;
    _Atomic bool running;

    // Latency measurement (audio thread owns the state machine).
    _Atomic int lat_request;  // set by control thread
    _Atomic int lat_state;    // 0 idle/failed, 1 running, 2 done
    _Atomic float lat_result;
    uint64_t lat_frame;
    uint64_t click_at[CLICKS];
    int64_t found[CLICKS];
    int clicks_sent;
};

static OSStatus render_cb(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *io_data) {
    ro_io *io = (ro_io *)ref;
    atomic_fetch_add_explicit(&io->callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&io->last_frames, frames, memory_order_relaxed);

    int out_ch = (int)io_data->mNumberBuffers;
    if (frames > RO_MAX_FRAMES) {
        atomic_fetch_add_explicit(&io->render_errors, 1, memory_order_relaxed);
        for (int c = 0; c < out_ch; c++) memset(io_data->mBuffers[c].mData, 0, frames * sizeof(float));
        return noErr;
    }

    float *outs[IO_MAX_CH] = {0};
    for (int c = 0; c < out_ch && c < IO_MAX_CH; c++) outs[c] = (float *)io_data->mBuffers[c].mData;

    if (io->mode == RO_IO_SIMULATED) {
        ro_sim_render(io->sim, io->engine, outs, (int)frames);
        if (io->engine_channels == 1 && out_ch > 1) memcpy(outs[1], outs[0], frames * sizeof(float));
        if (!atomic_load_explicit(&io->monitor_audible, memory_order_relaxed)) {
            for (int c = 0; c < out_ch; c++) memset(outs[c], 0, frames * sizeof(float));
        }
    } else {
        io->in_list->mNumberBuffers = (UInt32)io->io_channels;
        for (int c = 0; c < io->io_channels; c++) {
            io->in_list->mBuffers[c].mNumberChannels = 1;
            io->in_list->mBuffers[c].mDataByteSize = frames * sizeof(float);
            io->in_list->mBuffers[c].mData = io->in_buf[c];
        }
        OSStatus st = AudioUnitRender(io->unit, flags, ts, 1, frames, io->in_list);
        if (st != noErr) {
            atomic_fetch_add_explicit(&io->render_errors, 1, memory_order_relaxed);
            for (int c = 0; c < out_ch; c++) memset(outs[c], 0, frames * sizeof(float));
            return noErr;
        }

        const float *ins[IO_MAX_CH] = {io->in_buf[0], io->in_buf[1]};
        ro_engine_process(io->engine, ins, outs, (int)frames);
        for (int c = io->engine_channels; c < out_ch; c++) memset(outs[c], 0, frames * sizeof(float));

        // Loopback measurement on channel 2.
        if (atomic_exchange_explicit(&io->lat_request, 0, memory_order_acquire)) {
            io->lat_frame = 0;
            io->clicks_sent = 0;
            for (int i = 0; i < CLICKS; i++) { io->found[i] = -1; io->click_at[i] = 0; }
            atomic_store_explicit(&io->lat_state, 1, memory_order_release);
        }
        if (atomic_load_explicit(&io->lat_state, memory_order_relaxed) == 1 && io->io_channels >= 2 && out_ch >= 2) {
            uint64_t spacing = (uint64_t)(io->sample_rate * 0.5);
            memset(outs[1], 0, frames * sizeof(float));
            for (UInt32 i = 0; i < frames; i++) {
                uint64_t f = io->lat_frame + i;
                if (io->clicks_sent < CLICKS && f == spacing * (uint64_t)(io->clicks_sent + 1)) {
                    outs[1][i] = 0.9f;
                    io->click_at[io->clicks_sent++] = f;
                }
                float v = fabsf(io->in_buf[1][i]);
                for (int k = 0; k < io->clicks_sent; k++) {
                    if (io->found[k] < 0 && f > io->click_at[k] && f - io->click_at[k] < spacing / 2 && v > 0.25f) {
                        io->found[k] = (int64_t)(f - io->click_at[k]);
                        break;
                    }
                }
            }
            io->lat_frame += frames;
            if (io->lat_frame > spacing * (CLICKS + 2)) {
                int64_t v[CLICKS]; int n = 0;
                for (int k = 0; k < CLICKS; k++) if (io->found[k] > 0) v[n++] = io->found[k];
                if (n >= 3) {
                    for (int a = 0; a < n; a++) for (int b = a + 1; b < n; b++) if (v[b] < v[a]) { int64_t t = v[a]; v[a] = v[b]; v[b] = t; }
                    atomic_store_explicit(&io->lat_result, (float)v[n / 2], memory_order_relaxed);
                    atomic_store_explicit(&io->lat_state, 2, memory_order_release);
                } else {
                    atomic_store_explicit(&io->lat_state, 0, memory_order_release);
                }
            }
        }
    }

    // Route-loss mute with a 200 ms fade-in.
    bool muted = atomic_load_explicit(&io->muted, memory_order_relaxed);
    float target = muted ? 0.0f : 1.0f;
    if (muted) io->out_gain = 0.0f;
    if (io->out_gain != target || io->out_gain < 1.0f) {
        for (UInt32 i = 0; i < frames; i++) {
            if (io->out_gain < target) { io->out_gain += io->fade_step; if (io->out_gain > target) io->out_gain = target; }
            for (int c = 0; c < out_ch; c++) outs[c][i] *= io->out_gain;
        }
    }
    return noErr;
}

ro_io *ro_io_create(void) {
    ro_io *io = calloc(1, sizeof(ro_io));
    for (int c = 0; c < IO_MAX_CH; c++) io->in_buf[c] = calloc(RO_MAX_FRAMES, sizeof(float));
    io->in_list = calloc(1, sizeof(AudioBufferList) + IO_MAX_CH * sizeof(AudioBuffer));
    io->out_gain = 1.0f;
    return io;
}

void ro_io_destroy(ro_io *io) {
    if (!io) return;
    ro_io_stop(io);
    for (int c = 0; c < IO_MAX_CH; c++) free(io->in_buf[c]);
    free(io->in_list);
    free(io);
}

static AudioStreamBasicDescription float_format(double sr, int ch) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = sr;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBytesPerPacket = sizeof(float);
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(float);
    f.mChannelsPerFrame = (UInt32)ch;
    f.mBitsPerChannel = 32;
    return f;
}

OSStatus ro_io_start(ro_io *io, ro_engine *engine, ro_sim *sim, ro_io_mode mode,
                     int io_channels, int engine_channels, double sample_rate, bool monitor_audible) {
    ro_io_stop(io);
    if (io_channels < 1) io_channels = 1;
    if (io_channels > IO_MAX_CH) io_channels = IO_MAX_CH;
    if (engine_channels > io_channels) engine_channels = io_channels;
    io->engine = engine;
    io->sim = sim;
    io->mode = mode;
    io->io_channels = io_channels;
    io->engine_channels = engine_channels;
    io->sample_rate = sample_rate;
    io->fade_step = (float)(1.0 / (0.2 * sample_rate));
    atomic_store(&io->monitor_audible, monitor_audible);
    atomic_store(&io->lat_state, 0);

    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp) return -1;
    OSStatus st = AudioComponentInstanceNew(comp, &io->unit);
    if (st) return st;

    UInt32 enable_in = (mode == RO_IO_HARDWARE) ? 1 : 0;
    st = AudioUnitSetProperty(io->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable_in, sizeof(enable_in));
    if (st) goto fail;

    AudioStreamBasicDescription out_fmt = float_format(sample_rate, io_channels);
    st = AudioUnitSetProperty(io->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &out_fmt, sizeof(out_fmt));
    if (st) goto fail;
    if (enable_in) {
        AudioStreamBasicDescription in_fmt = float_format(sample_rate, io_channels);
        st = AudioUnitSetProperty(io->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &in_fmt, sizeof(in_fmt));
        if (st) goto fail;
    }
    UInt32 max_frames = RO_MAX_FRAMES;
    AudioUnitSetProperty(io->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max_frames, sizeof(max_frames));

    AURenderCallbackStruct cb = {render_cb, io};
    st = AudioUnitSetProperty(io->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (st) goto fail;

    st = AudioUnitInitialize(io->unit);
    if (st) goto fail;
    st = AudioOutputUnitStart(io->unit);
    if (st) goto fail;
    atomic_store(&io->running, true);
    return noErr;

fail:
    AudioComponentInstanceDispose(io->unit);
    io->unit = NULL;
    return st;
}

void ro_io_stop(ro_io *io) {
    if (!io || !io->unit) return;
    AudioOutputUnitStop(io->unit);
    AudioUnitUninitialize(io->unit);
    AudioComponentInstanceDispose(io->unit);
    io->unit = NULL;
    atomic_store(&io->running, false);
}

bool ro_io_is_running(ro_io *io) { return atomic_load(&io->running); }
void ro_io_set_monitor_audible(ro_io *io, bool a) { atomic_store(&io->monitor_audible, a); }
void ro_io_set_output_muted(ro_io *io, bool m) { atomic_store(&io->muted, m); }
uint64_t ro_io_callback_count(ro_io *io) { return atomic_load_explicit(&io->callbacks, memory_order_relaxed); }
uint32_t ro_io_last_frames(ro_io *io) { return atomic_load_explicit(&io->last_frames, memory_order_relaxed); }
uint32_t ro_io_render_errors(ro_io *io) { return atomic_load_explicit(&io->render_errors, memory_order_relaxed); }

void ro_io_begin_latency_measurement(ro_io *io) {
    atomic_store(&io->lat_state, 1);
    atomic_store_explicit(&io->lat_request, 1, memory_order_release);
}

int ro_io_latency_result(ro_io *io, float *samples) {
    int s = atomic_load_explicit(&io->lat_state, memory_order_acquire);
    if (s == 2) { if (samples) *samples = atomic_load(&io->lat_result); return 1; }
    if (s == 1) return 0;
    return -1;
}
