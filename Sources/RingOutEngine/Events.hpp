// RT -> UI event plumbing.
#pragma once

#include "SpscQueue.hpp"
#include "include/ringout_engine.h"

namespace ro {

using EventQueue = SpscQueue<ro_event, 512>;

// Stamps events with the channel and its frame counter. Drops when full.
struct EventSink {
    EventQueue* queue = nullptr;
    int channel = 0;
    uint64_t frame = 0;

    void emit(ro_event_type type, float freq, float conf, float depth, float duration) const {
        if (!queue) return;
        ro_event e{type, channel, freq, conf, depth, duration, frame};
        queue->push(e);
    }
};

}  // namespace ro
