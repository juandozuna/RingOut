// Lock-free single-producer / single-consumer ring. Fixed capacity, no
// allocation. push() fails (returns false) when full; pop() when empty.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>

namespace ro {

template <typename T, size_t N>
class SpscQueue {
    static_assert((N & (N - 1)) == 0, "capacity must be a power of two");

public:
    bool push(const T& v) {
        const size_t h = head_.load(std::memory_order_relaxed);
        const size_t t = tail_.load(std::memory_order_acquire);
        if (h - t >= N) return false;
        buf_[h & (N - 1)] = v;
        head_.store(h + 1, std::memory_order_release);
        return true;
    }
    bool pop(T& out) {
        const size_t t = tail_.load(std::memory_order_relaxed);
        const size_t h = head_.load(std::memory_order_acquire);
        if (t == h) return false;
        out = buf_[t & (N - 1)];
        tail_.store(t + 1, std::memory_order_release);
        return true;
    }

private:
    std::array<T, N> buf_{};
    alignas(64) std::atomic<size_t> head_{0};
    alignas(64) std::atomic<size_t> tail_{0};
};

}  // namespace ro
