// JamStemRecorder: writes a jam to WAV while it happens.
//
// Sources are taps on what this machine plays (each player's instrument,
// their audio loops, their voice, our own input). Every block carries the
// time it belongs to; pump() (main thread, every frame) places blocks on one
// timeline starting at `t_start`, sums them into one stem per player and a
// stereo mixdown, and streams finished audio (older than ~1 s) to
// 32-bit float WAV files. Nothing is allocated or locked on audio threads.
#pragma once
#include "engine/output_tap.h"
#include "engine/synth_core.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace godot {

class JamStemRecorder : public RefCounted {
	GDCLASS(JamStemRecorder, RefCounted)

	struct Writer {
		std::string path;
		FILE *file = nullptr;
		int64_t frames = 0;
		std::vector<float> ring; // stereo interleaved, WINDOW frames
		bool used = false;
	};
	struct Source {
		std::string player;
		double shift = 0.0; // seconds added to block times (e.g. output latency)
		jam::OutputTap *tap = nullptr;
		std::shared_ptr<void> keep; // keeps the tap's owner alive
		std::function<void()> stop;
	};

	std::vector<Source> sources;
	std::map<std::string, Writer> writers; // per player, plus "" = mixdown
	std::string dir;
	double t_start = 0.0;
	int rate = 48000;
	int64_t flushed = 0; // frames written so far (all writers advance together)
	int64_t latest = 0; // newest frame index seen
	bool active = false;
	int window = 0;

	Writer &writer(const std::string &player);
	void add_block(Writer &w, int64_t index, const float *l, const float *r, int n);
	void flush_to(int64_t upto);
	static void write_header(FILE *f, int rate, int64_t frames);

protected:
	static void _bind_methods();

public:
	~JamStemRecorder();
	Error start(const String &p_dir, double p_t_start, int p_rate);
	void add_synth(const String &player, Object *synth, double shift);
#ifdef JAM_HAVE_AOO
	void add_peer_voice(const String &player, Object *link, int peer_id, double shift);
	void add_input(const String &player, Object *link, double shift);
#endif
	void pump();
	PackedStringArray stop();
	bool is_active() const { return active; }
	double get_length() const { return (double)latest / rate; }
	int get_dropped() const;
};

} // namespace godot
