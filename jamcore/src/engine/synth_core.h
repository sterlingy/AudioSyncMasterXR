// SynthCore: owns one Instrument, receives timestamped events from the main
// thread, and renders on the audio thread with sample-accurate event timing.
#pragma once
#include "event_queue.h"
#include "instrument.h"
#include "output_tap.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <vector>

namespace jam {

// Process-wide monotonic clock in seconds (shared by every core and the main thread).
inline double mono_seconds() {
	static const auto epoch = std::chrono::steady_clock::now();
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - epoch).count();
}

// What actually played, for jam export (MIDI): written on the audio thread
// at the moment each event is applied, with its exact time.
struct LogEntry {
	double t = 0.0;
	uint8_t type = 0; // EventType
	int32_t a = 0;
	float value = 0.0f;
};

class SynthCore {
public:
	SynthCore() {}
	~SynthCore() {
		delete log;
		delete tap;
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
	// Network thread (the only producer of this queue): live notes from a
	// remote player, scheduled at their frame without waiting for a game frame.
	bool push_net(const Event &e) { return net_queue.push(e); }
	void collect_garbage() {
		Instrument *g;
		while (garbage.pop(g)) delete g;
	}
	void set_tempo_main(float bpm) { tempo = bpm; }

	// Jam recording (main thread). The log and tap are created once and kept
	// until the core dies, so the audio thread never sees them freed.
	void set_recording(bool on) {
		if (on) {
			if (!log) log = new SpscQueue<LogEntry, 16384>();
			if (!tap) tap = new OutputTap();
			LogEntry le;
			while (log->pop(le)) {}
			TapBlock tb;
			while (tap->read(tb)) {}
		}
		recording.store(on, std::memory_order_release);
	}
	bool take_log(LogEntry &out) { return log && log->pop(out); }
	OutputTap *get_tap() const { return tap; }

	// ---- audio thread ----
	// Renders n frames into l/r (overwrites).
	void process(float *l, float *r, int n, bool realtime = true) {
		auto t0 = std::chrono::steady_clock::now();
		if (realtime) update_anchor(frame_pos.load(std::memory_order_relaxed));
		const bool rec = realtime && recording.load(std::memory_order_acquire);
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
					if (rec) log_event(e, now);
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
		if (rec) tap->write(l, r, n, anchor_time_rt, (int)sample_rate);
		frame_pos.store(start + n, std::memory_order_relaxed);
		peak_l.store(std::max(pk_l, peak_l.load(std::memory_order_relaxed)), std::memory_order_relaxed);
		peak_r.store(std::max(pk_r, peak_r.load(std::memory_order_relaxed)), std::memory_order_relaxed);
		const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
		const double avail = (double)n / (double)sample_rate;
		const float load = (float)(used / avail);
		cpu_load.store(cpu_load.load(std::memory_order_relaxed) * 0.9f + load * 0.1f, std::memory_order_relaxed);
	}

	// Main thread: the engine frame that will be rendered at monotonic time t
	// (seconds). -1 until the core has rendered in real time.
	int64_t time_to_frame(double t) const {
		double at;
		int64_t af;
		if (!read_anchor(at, af)) return -1;
		return af + (int64_t)std::llround((t - at) * sample_rate);
	}
	// Offline rendering (tests, export): fix the frame<->time mapping by hand.
	void set_anchor(double t, int64_t f) {
		anchored = true;
		anchor_time_rt = t;
		anchor_frame_rt = f;
		const uint32_t s = seq.load(std::memory_order_relaxed);
		seq.store(s + 1, std::memory_order_release);
		pub_time.store(t, std::memory_order_relaxed);
		pub_frame.store(f, std::memory_order_relaxed);
		seq.store(s + 2, std::memory_order_release);
	}
	double frame_to_time(int64_t f) const {
		double at;
		int64_t af;
		if (!read_anchor(at, af)) return -1.0;
		return at + (double)(f - af) / sample_rate;
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
	// A delay-locked loop: the time each block starts is predicted from the
	// sample count and nudged toward the measured callback time, which removes
	// callback jitter. Every core mixes in the same callback, so all converge
	// on the same mapping.
	void update_anchor(int64_t frame) {
		const double now = mono_seconds();
		double t;
		if (!anchored) {
			t = now;
			anchored = true;
		} else {
			const double predicted = anchor_time_rt + (double)(frame - anchor_frame_rt) / sample_rate;
			const double err = now - predicted;
			t = (err > 0.05 || err < -0.05) ? now : predicted + err * 0.02;
		}
		anchor_time_rt = t;
		anchor_frame_rt = frame;
		const uint32_t s = seq.load(std::memory_order_relaxed);
		seq.store(s + 1, std::memory_order_release);
		pub_time.store(t, std::memory_order_relaxed);
		pub_frame.store(frame, std::memory_order_relaxed);
		seq.store(s + 2, std::memory_order_release);
	}
	bool read_anchor(double &t, int64_t &f) const {
		for (int tries = 0; tries < 8; tries++) {
			const uint32_t s1 = seq.load(std::memory_order_acquire);
			if (s1 == 0) return false;
			if (s1 & 1) continue;
			t = pub_time.load(std::memory_order_relaxed);
			f = pub_frame.load(std::memory_order_relaxed);
			if (seq.load(std::memory_order_acquire) == s1) return true;
		}
		return false;
	}
	void log_event(const Event &e, int64_t frame) {
		switch (e.type) {
			case EV_NOTE_ON:
			case EV_NOTE_OFF:
			case EV_ALL_OFF:
			case EV_PARAM:
			case EV_CC:
			case EV_BEND: {
				LogEntry le;
				le.t = anchor_time_rt + (double)(frame - anchor_frame_rt) / sample_rate;
				le.type = (uint8_t)e.type;
				le.a = e.a;
				le.value = e.value;
				log->push(le);
			} break;
			default:
				break;
		}
	}
	std::atomic<bool> recording{false};
	SpscQueue<LogEntry, 16384> *log = nullptr;
	OutputTap *tap = nullptr;

	bool anchored = false;
	double anchor_time_rt = 0.0;
	int64_t anchor_frame_rt = 0;
	std::atomic<uint32_t> seq{ 0 };
	std::atomic<double> pub_time{ 0.0 };
	std::atomic<int64_t> pub_frame{ 0 };

	void drain() {
		Event e;
		while (queue.pop(e)) {
			if (npending < MAX_PENDING) pending[npending++] = e;
			else apply(e); // overflow: play it now rather than drop it
		}
		while (net_queue.pop(e)) {
			if (npending < MAX_PENDING) pending[npending++] = e;
			else apply(e);
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
					case EV_TRANSPORT: inst->set_transport((double)e.b + (double)e.value, e.a != 0); break;
					default: break;
				}
		}
	}
	Instrument *inst = nullptr;
	float tempo = 120.0f;
	SpscQueue<Event, 8192> queue;
	SpscQueue<Event, 1024> net_queue;
	SpscQueue<Instrument *, 64> garbage;
	Event pending[MAX_PENDING];
	int npending = 0;
};

} // namespace jam
