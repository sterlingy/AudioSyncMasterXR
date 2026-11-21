// Voice allocation for polyphonic instruments: free voice first, otherwise
// steal the oldest released voice, otherwise the oldest held voice.
#pragma once
#include <cstdint>

namespace jam {

struct VoiceSlot {
	int note = -1;
	bool held = false; // key is down
	bool sustained = false; // key up but sustain pedal down
	uint32_t age = 0; // allocation order
};

template <int N>
struct VoiceAllocator {
	VoiceSlot slots[N];
	uint32_t counter = 0;
	int polyphony = N;

	// is_active(i): whether voice i is still sounding (supplied by the instrument).
	template <typename F>
	int allocate(int note, F is_active) {
		const int lim = polyphony < 1 ? 1 : (polyphony > N ? N : polyphony);
		// Retrigger the same note on the voice already playing it.
		for (int i = 0; i < lim; i++)
			if (slots[i].note == note && is_active(i)) return claim(i, note);
		for (int i = 0; i < lim; i++)
			if (!is_active(i)) return claim(i, note);
		int best = -1;
		for (int i = 0; i < lim; i++)
			if (!slots[i].held && (best < 0 || slots[i].age < slots[best].age)) best = i;
		if (best < 0) {
			best = 0;
			for (int i = 1; i < lim; i++)
				if (slots[i].age < slots[best].age) best = i;
		}
		return claim(best, note);
	}
	int claim(int i, int note) {
		slots[i].note = note;
		slots[i].held = true;
		slots[i].sustained = false;
		slots[i].age = ++counter;
		return i;
	}
	// Returns the voice to release, or -1. With the pedal down the voice is only marked.
	int release(int note, bool pedal) {
		for (int i = 0; i < N; i++) {
			if (slots[i].note == note && slots[i].held) {
				slots[i].held = false;
				if (pedal) {
					slots[i].sustained = true;
					return -1;
				}
				return i;
			}
		}
		return -1;
	}
};

} // namespace jam
