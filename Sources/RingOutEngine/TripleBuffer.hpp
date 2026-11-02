// Wait-free triple buffer: one writer publishes whole values, one reader always
// gets the most recent complete value. Neither side ever blocks or retries.
#pragma once

#include <atomic>
#include <cstdint>

namespace ro {

template <typename T>
class TripleBuffer {
public:
    void fill(const T& v) { bufs_[0] = bufs_[1] = bufs_[2] = v; }

    T& writeBuffer() { return bufs_[back_]; }
    void publish() {
        const uint8_t prev = middle_.exchange(static_cast<uint8_t>(back_ | kDirty), std::memory_order_acq_rel);
        back_ = prev & kIndex;
    }

    const T& read() {
        if (middle_.load(std::memory_order_relaxed) & kDirty) {
            const uint8_t prev = middle_.exchange(front_, std::memory_order_acq_rel);
            front_ = prev & kIndex;
        }
        return bufs_[front_];
    }

private:
    static constexpr uint8_t kDirty = 4;
    static constexpr uint8_t kIndex = 3;
    T bufs_[3]{};
    std::atomic<uint8_t> middle_{0};
    uint8_t back_ = 1;   // writer-owned
    uint8_t front_ = 2;  // reader-owned
};

}  // namespace ro
