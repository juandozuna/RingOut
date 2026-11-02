// Engine object behind the C API.
#pragma once

#include <atomic>

#include "Channel.hpp"
#include "TripleBuffer.hpp"

namespace ro {

struct ControlMsg {
    uint8_t isCommand = 0;
    int8_t channel = -1;
    int16_t id = 0;
    float a = 0, b = 0;
};

}  // namespace ro

struct ro_engine {
    ro::SpscQueue<ro::ControlMsg, 1024> control;
    ro::EventQueue events;
    ro::Channel channel[RO_MAX_CHANNELS];
    ro::TripleBuffer<ro_channel_snapshot> snapshot[RO_MAX_CHANNELS];
    std::atomic<float> load{0.0f};
    double sampleRate = 0;
    int maxFrames = 0;
    std::atomic<int> channels{0};
    std::atomic<bool> prepared{false};
    double secondsPerTick = 1e-9;

    void drainControl();
    void publish(int c);
};
