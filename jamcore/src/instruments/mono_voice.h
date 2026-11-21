// Held-note stack for monophonic instruments (low / last / high priority).
#pragma once

namespace jam {

struct MonoNoteStack {
	static constexpr int MAX = 16;
	int notes[MAX];
	int count = 0;
	int priority = 1; // 0 low, 1 last, 2 high
	int last_played = 48;

	void clear() { count = 0; }
	bool any() const { return count > 0; }
	void press(int note) {
		release(note);
		if (count == MAX) {
			for (int i = 1; i < MAX; i++) notes[i - 1] = notes[i];
			count--;
		}
		notes[count++] = note;
		last_played = current();
	}
	void release(int note) {
		int w = 0;
		for (int i = 0; i < count; i++)
			if (notes[i] != note) notes[w++] = notes[i];
		count = w;
		if (count) last_played = current();
	}
	// The sounding note; keeps the last one after release so the tail stays in pitch.
	int current() const {
		if (!count) return last_played;
		if (priority == 1) return notes[count - 1];
		int best = notes[0];
		for (int i = 1; i < count; i++) {
			if (priority == 0 && notes[i] < best) best = notes[i];
			if (priority == 2 && notes[i] > best) best = notes[i];
		}
		return best;
	}
};

} // namespace jam
