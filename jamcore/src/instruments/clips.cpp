#include "clips.h"
#include <algorithm>

namespace jam {

ClipPlayer::ClipPlayer() {
	info.push_back(pf("level", "Level", "Output", 0.0f, 2.0f, 1.0f));
	p_level = 0;
	finish_params();
}

ClipPlayer::~ClipPlayer() {
	collect();
	for (Clip *&c : clips) {
		delete c;
		c = nullptr;
	}
}

void ClipPlayer::collect() {
	Clip *c;
	while (dead.pop(c)) delete c;
}

void ClipPlayer::custom_event(const Event &e) {
	if (e.value >= 0.0f) {
		play(e.a, e.value, (size_t)std::max(0, e.b));
		return;
	}
	if (e.a < 0 || e.a >= SLOTS) {
		if (e.ptr) dead.push((Clip *)e.ptr);
		return;
	}
	// Stop voices still reading the old clip before it leaves.
	for (Voice &v : voices)
		if (v.slot == e.a) v.slot = -1;
	Clip *old = clips[e.a];
	clips[e.a] = (Clip *)e.ptr;
	if (old && !dead.push(old)) {
		// Main thread hasn't collected for a long time; keep the clip rather than free here.
		clips[e.a] = old;
		if (e.ptr) dead.push((Clip *)e.ptr);
	}
}

void ClipPlayer::note_on(int slot, float velocity) { play(slot, velocity, 0); }

void ClipPlayer::play(int slot, float velocity, size_t offset) {
	if (slot < 0 || slot >= SLOTS || !clips[slot] || offset >= clips[slot]->data.size()) return;
	// A restart of the same clip fades the previous pass out quickly.
	for (Voice &v : voices)
		if (v.slot == slot && v.step == 0.0f) v.step = 1.0f / (0.003f * sr);
	Voice *best = nullptr;
	for (Voice &v : voices)
		if (v.slot < 0) {
			best = &v;
			break;
		}
	if (!best) {
		best = &voices[0];
		for (Voice &v : voices)
			if (v.pos > best->pos) best = &v; // steal the one that has played longest
	}
	best->slot = slot;
	best->pos = offset;
	best->gain = velocity;
	best->env = 1.0f;
	best->step = 0.0f;
}

void ClipPlayer::note_off(int slot) {
	for (Voice &v : voices)
		if (v.slot == slot && v.step == 0.0f) v.step = 1.0f / (0.005f * sr);
}

void ClipPlayer::all_notes_off() {
	for (Voice &v : voices)
		if (v.slot >= 0 && v.step == 0.0f) v.step = 1.0f / (0.005f * sr);
}

void ClipPlayer::render(float *l, float *r, int n) {
	const float level = p(p_level);
	for (Voice &v : voices) {
		if (v.slot < 0) continue;
		const Clip *c = clips[v.slot];
		if (!c) {
			v.slot = -1;
			continue;
		}
		const size_t len = c->data.size();
		const float g = v.gain * level;
		for (int i = 0; i < n; i++) {
			if (v.pos >= len || v.env <= 0.0f) {
				v.slot = -1;
				break;
			}
			const float s = c->data[v.pos++] * g * v.env;
			l[i] += s;
			r[i] += s;
			if (v.step > 0.0f) v.env -= v.step;
		}
	}
}

Instrument *make_clips() { return new ClipPlayer(); }

} // namespace jam
