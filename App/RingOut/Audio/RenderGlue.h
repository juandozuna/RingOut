// RenderGlue — the only code that runs on the Core Audio I/O thread besides
// the engine itself. Written in C so the real-time path has no Swift, no
// Objective-C dispatch, no allocation and no locks.

#ifndef RINGOUT_RENDER_GLUE_H
#define RINGOUT_RENDER_GLUE_H

#include <stdbool.h>
#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>
#include "ringout_engine.h"

typedef struct ro_io ro_io;

typedef enum {
    RO_IO_HARDWARE = 0,   // interface in -> engine -> interface out
    RO_IO_SIMULATED = 1,  // ro_sim closed loop drives the engine
} ro_io_mode;

ro_io *ro_io_create(void);
void ro_io_destroy(ro_io *io);

// Starts a RemoteIO unit. io_channels is the hardware channel count opened in
// each direction (2 when the interface has it, so the Out 2 -> In 2 loopback
// is reachable). engine_channels <= io_channels are processed.
// monitor_audible only matters in simulated mode (play the loop on the speaker).
OSStatus ro_io_start(ro_io *io, ro_engine *engine, ro_sim *sim, ro_io_mode mode,
                     int io_channels, int engine_channels, double sample_rate,
                     bool monitor_audible);
void ro_io_stop(ro_io *io);
bool ro_io_is_running(ro_io *io);

void ro_io_set_monitor_audible(ro_io *io, bool audible);

// Route-loss mute. Unmuting fades output in over 200 ms.
void ro_io_set_output_muted(ro_io *io, bool muted);

// Health counters, read from any thread.
uint64_t ro_io_callback_count(ro_io *io);
uint32_t ro_io_last_frames(ro_io *io);
uint32_t ro_io_render_errors(ro_io *io);  // AudioUnitRender failures + frame-size overruns

// Loopback latency measurement on Out 2 -> In 2 (hardware mode only).
// Plays five clicks 0.5 s apart on output 2 and times their arrival on input 2.
void ro_io_begin_latency_measurement(ro_io *io);
// 0 = in progress, 1 = done (*samples set to median round trip), -1 = failed / idle.
int ro_io_latency_result(ro_io *io, float *samples);

#endif
