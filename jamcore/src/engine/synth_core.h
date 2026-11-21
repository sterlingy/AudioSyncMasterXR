// SynthCore: owns one Instrument, receives timestamped events from the main
// thread, and renders on the audio thread with sample-accurate event timing.
#pragma once
#include "event_queue.h"
#include "instrument.h"
#include <atomic>
#include <chrono>
#include <memory>
#include <vector>

namespace jam {

class SynthCore {
public:
	SynthCore() {}
	~SynthCore() {
		Instrument *g;
		while (garbage.pop(g)) delete g;
		delete inst;
	}

	// ---- main thread ----
	void set_instrument(Instrument *p_inst, bool playing) {
		p_inst->prepare(sample_rate);
		p_inst->set_tempo(tempo);
		if (playing) {
			Event e;
			e.type = EV_SWAP_INSTRUMENT;
			e.ptr = p_inst;
			push(e);
		} else {
			delete inst;
			inst = p_inst;
		}
		collect_garbage();
	}
	Instrument *instrument_unsafe() const { return inst; } // main thread, when not playing
	// Main thread, not playing: applies every queued event now, so objects
	// still in the queue get prepared for the new sample rate too.
	void prepare(float sr) {
		drain();
		for (int i = 0; i < npending; i++) apply(pending[i]);
		npending = 0;
		sample_rate = sr;
		if (inst) inst->prepare(sr);
		temp_l.assign(MAX_BLOCK, 0.0f);
		temp_r.assign(MAX_BLOCK, 0.0f);
	}
	bool push(const Event &e) {
		collect_garbage();
		return queue.push(e);
	}
	void collect_garbage() {
		Instrument *g;
		while (garbage.pop(g)) delete g;
	}
	void set_tempo_main(float bpm) { tempo = bpm; }

	// ---- audio thread ----
	// Renders n frames into l/r (overwrites).
	void process(float *l, float *r, int n) {
		auto t0 = std::chrono::steady_clock::now();
		for (int i = 0; i < n; i++) l[i] = r[i] = 0.0f;
		drain();
		const int64_t start = frame_pos.load(std::memory_order_relaxed);
		int pos = 0;
		while (pos < n) {
			// Apply every event due at or before this position.
			int64_t now = start + pos;
			int next = n;
			int w = 0;
			for (int i = 0; i < npending; i++) {
				Event &e = pending[i];
				if (e.frame < 0 || e.frame <= now) {
					apply(e);
				} else {
					const int64_t rel = e.frame - start;
					if (rel < next) next = (int)rel;
					pending[w++] = e;
				}
			}
			npending = w;
			if (next <= pos) next = pos + 1;
			const int len = next - pos;
			if (inst) inst->render(l + pos, r + pos, len);
			pos = next;
		}
		float pk_l = 0.0f, pk_r = 0.0f;
		for (int i = 0; i < n; i++) {
			l[i] *= gain;
			r[i] *= gain;
			const float al = l[i] < 0 ? -l[i] : l[i];
			const float ar = r[i] < 0 ? -r[i] : r[i];
			if (al > pk_l) pk_l = al;
			if (ar > pk_r) pk_r = ar;
		}
		frame_pos.store(start + n, std::memory_order_relaxed);
		peak_l.store(std::max(pk_l, peak_l.load(std::memory_order_relaxed)), std::memory_order_relaxed);
		peak_r.store(std::max(pk_r, peak_r.load(std::memory_order_relaxed)), std::memory_order_relaxed);
		const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
		const double avail = (double)n / (double)sample_rate;
		const float load = (float)(used / avail);
		cpu_load.store(cpu_load.load(std::memory_order_relaxed) * 0.9f + load * 0.1f, std::memory_order_relaxed);
	}

	static constexpr int MAX_BLOCK = 4096;
	static constexpr int MAX_PENDING = 2048;
	std::atomic<int64_t> frame_pos{ 0 };
	std::atomic<float> peak_l{ 0.0f }, peak_r{ 0.0f }, cpu_load{ 0.0f };
	std::atomic<int> active_playbacks{ 0 };
	std::atomic<uint32_t> owner_token{ 0 }, owner_current{ 0 };
	float sample_rate = 48000.0f;
	float gain = 1.0f;
	std::vector<float> temp_l, temp_r;

private:
	void drain() {
		Event e;
		while (queue.pop(e)) {
			if (npending < MAX_PENDING) pending[npending++] = e;
			else apply(e); // overflow: play it now rather than drop it
		}
	}
	void apply(const Event &e) {
		switch (e.type) {
			case EV_SWAP_INSTRUMENT: {
				Instrument *old = inst;
				inst = (Instrument *)e.ptr;
				if (old) garbage.push(old);
			} break;
			default:
				if (!inst) return;
				switch (e.type) {
					case EV_NOTE_ON: inst->note_on(e.a, e.value); break;
					case EV_NOTE_OFF: inst->note_off(e.a); break;
					case EV_ALL_OFF: inst->all_notes_off(); break;
					case EV_PARAM: inst->set_param(e.a, e.value); break;
					case EV_CC: inst->control_change(e.a, e.value); break;
					case EV_BEND: inst->pitch_bend(e.value); break;
					case EV_TEMPO: inst->set_tempo(e.value); break;
					case EV_CUSTOM: inst->custom_event(e); break;
					default: break;
				}
		}
	}
	Instrument *inst = nullptr;
	float tempo = 120.0f;
	SpscQueue<Event, 8192> queue;
	SpscQueue<Instrument *, 64> garbage;
	Event pending[MAX_PENDING];
	int npending = 0;
};

} // namespace jam
