// RingOut engine — public C API.
//
// This header is the ONLY surface the Swift app sees. Everything behind it
// (DC block, high-pass, FFT detector, peak tracker, logistic classifier,
// adaptive notch bank, isolator, Strength mix, limiter, meters, lock-free
// queues) is an implementation detail of the C++ core.
//
// Threading contract
//   - ro_engine_process / ro_sim_render: audio thread only. Real-time safe:
//     no allocation, no locks, no syscalls, no logging.
//   - ro_engine_set_param / ro_engine_command: ONE control thread (the Swift
//     main actor). They push onto a lock-free SPSC queue drained at the start
//     of the next process call.
//   - ro_engine_read_snapshot / ro_engine_pop_event: ONE reader thread (UI).
//     Lock-free; never blocks the audio thread.
//   - create/destroy/prepare: never concurrently with process.

#ifndef RINGOUT_ENGINE_H
#define RINGOUT_ENGINE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RO_MAX_CHANNELS 2
#define RO_MAX_AUTO_NOTCHES 8
#define RO_MAX_FIXED_NOTCHES 4
#define RO_MAX_NOTCHES (RO_MAX_AUTO_NOTCHES + RO_MAX_FIXED_NOTCHES)
#define RO_SPECTRUM_BINS 96   // log-spaced, 100 Hz .. 20 kHz
#define RO_MAX_FRAMES 1024

typedef struct ro_engine ro_engine;

// ---- Lifecycle -----------------------------------------------------------

ro_engine *ro_engine_create(void);
void ro_engine_destroy(ro_engine *e);

// Allocates everything. Call before the first process and whenever the sample
// rate or maximum buffer size changes. Clears detector + notch state but keeps
// parameters and fixed notches. channels: 1 or 2. Returns false on bad args.
bool ro_engine_prepare(ro_engine *e, double sample_rate, int max_frames, int channels);

// ---- Audio ---------------------------------------------------------------

// Non-interleaved. in[c] / out[c] for c < channels given to prepare.
// frames <= max_frames. in and out may alias. Adds zero samples of latency.
void ro_engine_process(ro_engine *e, const float *const *in, float *const *out, int frames);

// ---- Parameters (control thread) ----------------------------------------

typedef enum {
    RO_PARAM_STRENGTH = 0,         // 0..1, default 0.8. 0 = bit-exact dry.
    RO_PARAM_BYPASS = 1,           // 0/1. 1 = bit-exact dry, detector keeps analysing.
    RO_PARAM_MUTE = 2,             // 0/1. Output silence (ramped 5 ms).
    RO_PARAM_HIGHPASS = 3,         // 0/1, default 1. 80 Hz high-pass in the wet path.
    RO_PARAM_LIMITER = 4,          // 0/1, default 1. -0.3 dBFS output limiter.
    RO_PARAM_NOTCH_HOLD_S = 5,     // 2..10, default 4. Release ramp time.
    RO_PARAM_MAX_AUTO_NOTCHES = 6, // 4..8, default 8.
    RO_PARAM_PRESET = 7,           // ro_preset. Tunes detector + isolator.
    RO_PARAM_RING_OUT_MODE = 8,    // 0/1. While 1, confirmed rings are pinned as fixed (up to 4).
    RO_PARAM_INPUT_TRIM_DB = 9,    // -24..+24, default 0 (Topology B gain trim).
} ro_param;

typedef enum {
    RO_PRESET_SPEECH = 0,
    RO_PRESET_SINGING = 1,
    RO_PRESET_CUSTOM = 2,
} ro_preset;

// channel: 0..channels-1, or -1 for all channels.
void ro_engine_set_param(ro_engine *e, int channel, ro_param p, float value);

typedef enum {
    RO_CMD_CLEAR_AUTO_NOTCHES = 0,  // a, b unused
    RO_CMD_PIN_NOTCH = 1,           // a = slot index of an auto notch -> becomes fixed
    RO_CMD_RELEASE_NOTCH = 2,       // a = slot index (auto or fixed) -> removed
    RO_CMD_ADD_FIXED_NOTCH = 3,     // a = frequency Hz, b = depth dB (negative). Used to restore show files.
    RO_CMD_MOVE_NOTCH = 4,          // a = slot index, b = new frequency Hz (drag in S5)
    RO_CMD_RESET_METERS = 5,        // clears clip latch + peak holds
} ro_command;

void ro_engine_command(ro_engine *e, int channel, ro_command cmd, float a, float b);

// ---- Snapshot (UI thread) -----------------------------------------------

typedef enum {
    RO_STATE_SAFE = 0,     // stable, no notches active
    RO_STATE_WORKING = 1,  // notch(es) active or isolator activity > 0.5
    RO_STATE_RING = 2,     // ring caught in the last 2 s, or loop-gain warning
    RO_STATE_BYPASS = 3,   // bypassed (or muted)
} ro_channel_state;

typedef struct {
    float frequency_hz;
    float depth_db;      // <= 0
    float age_s;
    bool fixed;
    bool active;         // slot in use
} ro_notch_info;

typedef struct {
    // Levels, dBFS. Peak hold decays after 2 s.
    float input_peak_db, input_rms_db, input_peak_hold_db;
    float output_peak_db, output_rms_db, output_peak_hold_db;
    bool input_clip, output_clip;          // latched at >= -0.5 dBFS until RO_CMD_RESET_METERS

    ro_channel_state state;
    int active_auto_notches;
    int active_fixed_notches;
    ro_notch_info notches[RO_MAX_NOTCHES]; // slots 0..7 auto, 8..11 fixed

    float spectrum_db[RO_SPECTRUM_BINS];   // post-input-conditioning, dBFS, -120..0
    float last_ring_hz;                    // most recent detection, 0 if none
    float last_ring_age_s;                 // seconds since last detection (large if none)
    float isolator_activity;               // 0..1, how much the isolator is removing
    float gain_reduction_db;               // total wet-vs-dry reduction, <= 0
    bool loop_gain_warning;                // oscillation guard tripped
    bool multi_talker;                     // > 1 dominant voice
    uint64_t frames_processed;
} ro_channel_snapshot;

// Returns false if channel is out of range. Never blocks.
bool ro_engine_read_snapshot(ro_engine *e, int channel, ro_channel_snapshot *out);

// Engine compute time of the last process call divided by the buffer period
// (0..1+). Measured inside process with a monotonic clock read.
float ro_engine_dsp_load(ro_engine *e);

// ---- Events (UI thread) -------------------------------------------------

typedef enum {
    RO_EVENT_RING_DETECTED = 0,   // notch placed
    RO_EVENT_NOTCH_DEEPENED = 1,
    RO_EVENT_NOTCH_RELEASED = 2,
    RO_EVENT_NOTCH_PINNED = 3,    // via ring-out mode or command
    RO_EVENT_LOOP_GAIN_WARNING = 4,
} ro_event_type;

typedef struct {
    ro_event_type type;
    int channel;
    float frequency_hz;
    float confidence;   // 0..1
    float depth_db;
    float duration_s;   // for releases: how long the notch lived
    uint64_t frame;     // engine frame counter at the event
} ro_event;

// Pops one event; returns false when the queue is empty.
bool ro_engine_pop_event(ro_engine *e, ro_event *out);

// ---- Simulated feedback loop (demo + tests) ------------------------------
//
// A closed acoustic loop around the engine so the app can be exercised with
// no audio interface (simulator, demo mode) and so tests can assert stability.
// Per channel: synthetic talker (pitched, formant-filtered, with pauses) +
// room noise -> mic -> [engine] -> console gain -> PA EQ -> room IR (with
// a few resonant modes) and 2..25 ms loop delay -> back into the mic.

typedef struct ro_sim ro_sim;

typedef enum {
    RO_SIM_SPEECH = 0,
    RO_SIM_SINGING = 1,
    RO_SIM_SILENCE = 2,  // room noise only
} ro_sim_source;

ro_sim *ro_sim_create(double sample_rate, int channels, uint32_t seed);
void ro_sim_destroy(ro_sim *s);
// Loop gain relative to the bypass stability limit, dB. 0 = marginal,
// +6 = 6 dB past where bypass rings. Default -6.
void ro_sim_set_loop_gain_db(ro_sim *s, int channel, float db);
void ro_sim_set_source(ro_sim *s, int channel, ro_sim_source src);
// Renders `frames` samples through the loop, calling ro_engine_process
// internally (engine may be NULL = bypass loop). monitor[c] receives the
// engine output (what the PA plays). Real-time safe.
void ro_sim_render(ro_sim *s, ro_engine *e, float *const *monitor, int frames);

#ifdef __cplusplus
}
#endif

#endif
