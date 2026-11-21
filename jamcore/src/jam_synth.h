// JamSynth: a Godot AudioStream that plays one jamcore instrument.
// Play it with AudioStreamPlayer (flat) or AudioStreamPlayer3D (at an avatar).
#pragma once
#include "dsp/dsp.h"
#include "engine/synth_core.h"
#include "instruments/tangle.h"
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <memory>

namespace godot {

class JamSynth;

class JamSynthPlayback : public AudioStreamPlayback {
	GDCLASS(JamSynthPlayback, AudioStreamPlayback)

	std::shared_ptr<jam::SynthCore> core;
	bool playing = false;
	bool counted = false; // counted in core->active_playbacks
	uint32_t token = 0; // the newest started playback owns the core

protected:
	static void _bind_methods() {}

public:
	~JamSynthPlayback();
	void setup(const std::shared_ptr<jam::SynthCore> &p_core);
	void _start(double p_from_pos) override;
	void _stop() override;
	bool _is_playing() const override;
	int32_t _mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) override;
};

class JamSynth : public AudioStream {
	GDCLASS(JamSynth, AudioStream)

	std::shared_ptr<jam::SynthCore> core;
	jam::Instrument *main_inst = nullptr; // newest instrument; its param table is read-only
	std::unique_ptr<jam::TangleModel> tangle; // only when the instrument is Tangle
	String instrument_type = "Undertow";
	std::vector<float> values; // main-thread mirror of parameter values
	float volume_db = 0.0f;
	float tempo = 120.0f;

	int index_of(const String &id) const;
	void ensure_rate(float sr) const;
	void collect();
	bool tangle_ok(const char *fn) const;
	void send(jam::EventType t, int a, float v, int64_t frame);

protected:
	static void _bind_methods();

public:
	JamSynth();

	Ref<AudioStreamPlayback> _instantiate_playback() const override;
	String _get_stream_name() const override { return instrument_type; }
	double _get_length() const override { return 0.0; }
	bool _is_monophonic() const override { return true; }

	void set_instrument(const String &p_type);
	String get_instrument() const { return instrument_type; }
	static PackedStringArray get_instrument_types();

	// Parameters
	Array get_param_list() const;
	void set_param(const String &id, float value);
	float get_param(const String &id) const;
	Dictionary get_params() const;
	void set_params(const Dictionary &params);
	void reset_params();

	// Clips instrument (audio loops): mono samples at `sample_rate`, resampled
	// to the engine rate here; then note_on(slot) plays the clip.
	bool clip_set(int slot, const PackedFloat32Array &samples, float sample_rate);
	void clip_clear(int slot);
	void clip_play(int slot, float gain, int64_t frame, int offset);

	// Playing. frame = absolute engine frame (see get_frame_position); -1 = now.
	void note_on(int note, float velocity = 1.0f, int64_t frame = -1);
	void note_off(int note, int64_t frame = -1);
	void all_notes_off();
	void control_change(int cc, float value, int64_t frame = -1);
	void pitch_bend(float value, int64_t frame = -1);
	void set_tempo(float bpm);
	void sync_transport(double beat, int64_t frame, bool running = true);
	float get_tempo() const { return tempo; }

	void set_volume_db(float db);
	float get_volume_db() const { return volume_db; }

	// Monitoring
	int64_t get_frame_position() const;
	// Shared clock: monotonic seconds, and the mapping to this synth's frames.
	static double get_time();
	int64_t time_to_frame(double t) const; // -1 until playing in real time
	double frame_to_time(int64_t frame) const;
	void set_clock_anchor(double time, int64_t frame); // offline rendering only
	float get_sample_rate() const;
	Vector2 take_peak(); // peak since the last call (for meters)
	float get_cpu_load() const; // render time / real time, smoothed
	bool is_playing() const;

	// Offline rendering for tests and export. Only when not playing.
	PackedVector2Array render_offline(int frames, float sample_rate = 48000.0f);

	// Tangle (modular) patch editing. Ports and params are addressed by id strings.
	Array tangle_get_module_types() const;
	int tangle_add_module(const String &type, Vector2 position = Vector2());
	bool tangle_remove_module(int id);
	bool tangle_connect(int from_id, const String &out_port, int to_id, const String &in_port);
	bool tangle_disconnect(int to_id, const String &in_port);
	bool tangle_set_param(int id, const String &param, float value);
	float tangle_get_param(int id, const String &param) const;
	void tangle_set_position(int id, Vector2 position);
	Dictionary tangle_get_patch() const;
	bool tangle_set_patch(const Dictionary &patch);
	void tangle_clear();
	void tangle_load_default();

	// Low-level access for instrument-specific classes (Tangle).
	std::shared_ptr<jam::SynthCore> get_core() const { return core; }
	bool push_custom(int a, int b, float value, void *ptr);
};

} // namespace godot
