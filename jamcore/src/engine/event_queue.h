// Lock-free single-producer / single-consumer queue between the main thread
// (producer) and the audio thread (consumer). Fixed capacity, no allocation.
#pragma once
#include <atomic>
#include <cstdint>

namespace jam {

enum EventType : uint8_t {
	EV_NOTE_ON = 0,
	EV_NOTE_OFF,
	EV_ALL_OFF,
	EV_PARAM,
	EV_CC,
	EV_BEND,
	EV_TEMPO,
	EV_SWAP_INSTRUMENT, // ptr = new Instrument*
	EV_CUSTOM, // instrument-specific (ptr / ints)
};

struct Event {
	EventType type;
	int32_t a = 0; // note, param index, cc number
	int32_t b = 0;
	float value = 0.0f;
	int64_t frame = -1; // absolute engine frame; -1 = as soon as possible
	void *ptr = nullptr;
};

template <typename T, int CAP>
class SpscQueue {
	static_assert((CAP & (CAP - 1)) == 0, "capacity must be a power of two");
	T items[CAP];
	std::atomic<uint32_t> head{ 0 }; // written by consumer
	std::atomic<uint32_t> tail{ 0 }; // written by producer

public:
	bool push(const T &item) {
		const uint32_t t = tail.load(std::memory_order_relaxed);
		if (t - head.load(std::memory_order_acquire) >= CAP) return false;
		items[t & (CAP - 1)] = item;
		tail.store(t + 1, std::memory_order_release);
		return true;
	}
	bool pop(T &out) {
		const uint32_t h = head.load(std::memory_order_relaxed);
		if (h == tail.load(std::memory_order_acquire)) return false;
		out = items[h & (CAP - 1)];
		head.store(h + 1, std::memory_order_release);
		return true;
	}
};

} // namespace jam
