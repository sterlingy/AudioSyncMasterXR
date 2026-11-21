// OutputTap: copies an audio stream's blocks, with the time they belong to,
// from the audio (or capture) thread to the main thread for jam recording.
// Lock-free and allocation-free on the producer side; if the main thread
// falls behind by more than the queue (~5 s), blocks are dropped and counted.
#pragma once
#include "event_queue.h"
#include <atomic>
#include <cstring>

namespace jam {

struct TapBlock {
	static constexpr int FRAMES = 256;
	double time = 0.0; // monotonic time of the first frame
	int frames = 0;
	int rate = 48000;
	float l[FRAMES];
	float r[FRAMES];
};

class OutputTap {
public:
	// Producer (one thread). Splits into blocks of at most 256 frames.
	void write(const float *l, const float *r, int n, double t, int rate) {
		int done = 0;
		while (done < n) {
			const int k = n - done < TapBlock::FRAMES ? n - done : TapBlock::FRAMES;
			TapBlock &b = scratch;
			b.time = t + (double)done / rate;
			b.frames = k;
			b.rate = rate;
			memcpy(b.l, l + done, sizeof(float) * k);
			memcpy(b.r, (r ? r : l) + done, sizeof(float) * k);
			if (!queue.push(b)) dropped.fetch_add(1, std::memory_order_relaxed);
			done += k;
		}
	}
	// Consumer (main thread).
	bool read(TapBlock &out) { return queue.pop(out); }
	std::atomic<int> dropped{0};

private:
	TapBlock scratch;
	SpscQueue<TapBlock, 1024> queue;
};

} // namespace jam
