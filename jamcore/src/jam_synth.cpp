#include "jam_synth.h"
#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

// ---------------- Playback ----------------

JamSynthPlayback::~JamSynthPlayback() {
	if (owner && core) core->active_playbacks.fetch_sub(1);
}

void JamSynthPlayback::setup(const std::shared_ptr<jam::SynthCore> &p_core) {
	core = p_core;
}

void JamSynthPlayback::_start(double p_from_pos) {
	if (!core) return;
	if (!owner) {
		int expected = 0;
		if (core->active_playbacks.compare_exchange_strong(expected, 1)) {
			owner = true;
		} else {
			UtilityFunctions::push_warning("JamSynth is already playing on another player; this one stays silent.");
		}
	}
	playing = true;
}

void JamSynthPlayback::_stop() {
	playing = false;
	if (owner && core) {
		core->active_playbacks.fetch_sub(1);
		owner = false;
	}
}

bool JamSynthPlayback::_is_playing() const {
	return playing;
}

int32_t JamSynthPlayback::_mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) {
	if (!playing || !owner || !core || core->temp_l.empty()) {
		for (int i = 0; i < p_frames; i++) p_buffer[i] = AudioFrame{ 0.0f, 0.0f };
		return p_frames;
	}
	float *l = core->temp_l.data();
	float *r = core->temp_r.data();
	int done = 0;
	while (done < p_frames) {
		const int n = std::min<int>(p_frames - done, jam::SynthCore::MAX_BLOCK);
		core->process(l, r, n);
		for (int i = 0; i < n; i++) {
			p_buffer[done + i].left = l[i];
			p_buffer[done + i].right = r[i];
		}
		done += n;
	}
	return p_frames;
}

// ---------------- Stream ----------------

JamSynth::JamSynth() {
	core = std::make_shared<jam::SynthCore>();
	core->prepare(48000.0f);
	set_instrument("Undertow");
}

Ref<AudioStreamPlayback> JamSynth::_instantiate_playback() const {
	Ref<JamSynthPlayback> pb;
	pb.instantiate();
	if (core->active_playbacks.load() == 0) {
		const float sr = (float)AudioServer::get_singleton()->get_mix_rate();
		if (sr != core->sample_rate) core->prepare(sr);
	}
	pb->setup(core);
	return pb;
}

PackedStringArray JamSynth::get_instrument_types() {
	PackedStringArray out;
	for (const std::string &t : jam::instrument_types()) out.push_back(String(t.c_str()));
	return out;
}

void JamSynth::set_instrument(const String &p_type) {
	jam::Instrument *inst = jam::create_instrument(std::string(p_type.utf8().get_data()));
	if (!inst) {
		UtilityFunctions::push_error("JamSynth: unknown instrument '", p_type, "'. Known: ", get_instrument_types());
		return;
	}
	instrument_type = p_type;
	values.clear();
	for (const jam::ParamInfo &p : inst->params()) values.push_back(p.def);
	core->set_instrument(inst, is_playing());
	notify_property_list_changed();
	emit_changed();
}

int JamSynth::index_of(const String &id) const {
	// Main thread: the instrument's param table is immutable after construction,
	// so reading it while the audio thread renders is safe.
	jam::Instrument *inst = core->instrument_unsafe();
	if (!inst) return -1;
	return inst->param_index(std::string(id.utf8().get_data()));
}

Array JamSynth::get_param_list() const {
	Array out;
	jam::Instrument *inst = core->instrument_unsafe();
	if (!inst) return out;
	const auto &ps = inst->params();
	for (size_t i = 0; i < ps.size(); i++) {
		const jam::ParamInfo &p = ps[i];
		Dictionary d;
		d["index"] = (int)i;
		d["id"] = String(p.id.c_str());
		d["name"] = String(p.name.c_str());
		d["group"] = String(p.group.c_str());
		static const char *types[] = { "float", "int", "enum", "bool" };
		d["type"] = String(types[p.type]);
		d["min"] = p.min;
		d["max"] = p.max;
		d["default"] = p.def;
		d["unit"] = String(p.unit.c_str());
		d["log"] = p.log_scale;
		PackedStringArray opts;
		for (const std::string &o : p.options) opts.push_back(String(o.c_str()));
		d["options"] = opts;
		d["value"] = i < values.size() ? values[i] : p.def;
		out.push_back(d);
	}
	return out;
}

void JamSynth::send(jam::EventType t, int a, float v, int64_t frame) {
	jam::Event e;
	e.type = t;
	e.a = a;
	e.value = v;
	e.frame = frame;
	if (!core->push(e)) UtilityFunctions::push_warning("JamSynth: event queue full, event dropped");
}

void JamSynth::set_param(const String &id, float value) {
	const int i = index_of(id);
	if (i < 0) {
		UtilityFunctions::push_warning("JamSynth(", instrument_type, "): unknown parameter '", id, "'");
		return;
	}
	const jam::ParamInfo &p = core->instrument_unsafe()->params()[i];
	value = value < p.min ? p.min : (value > p.max ? p.max : value);
	if (p.type != jam::P_FLOAT) value = (float)(int)(value + 0.5f);
	values[i] = value;
	send(jam::EV_PARAM, i, value, -1);
}

float JamSynth::get_param(const String &id) const {
	const int i = index_of(id);
	return (i >= 0 && i < (int)values.size()) ? values[i] : 0.0f;
}

Dictionary JamSynth::get_params() const {
	Dictionary d;
	jam::Instrument *inst = core->instrument_unsafe();
	if (!inst) return d;
	const auto &ps = inst->params();
	for (size_t i = 0; i < ps.size(); i++) d[String(ps[i].id.c_str())] = values[i];
	return d;
}

void JamSynth::set_params(const Dictionary &params) {
	Array keys = params.keys();
	for (int i = 0; i < keys.size(); i++) {
		const String k = keys[i];
		if (index_of(k) >= 0) set_param(k, (float)params[k]);
	}
}

void JamSynth::reset_params() {
	jam::Instrument *inst = core->instrument_unsafe();
	if (!inst) return;
	const auto &ps = inst->params();
	for (size_t i = 0; i < ps.size(); i++) {
		values[i] = ps[i].def;
		send(jam::EV_PARAM, (int)i, ps[i].def, -1);
	}
}

void JamSynth::note_on(int note, float velocity, int64_t frame) {
	if (velocity <= 0.0f) {
		note_off(note, frame);
		return;
	}
	send(jam::EV_NOTE_ON, note, velocity > 1.0f ? 1.0f : velocity, frame);
}

void JamSynth::note_off(int note, int64_t frame) {
	send(jam::EV_NOTE_OFF, note, 0.0f, frame);
}

void JamSynth::all_notes_off() {
	send(jam::EV_ALL_OFF, 0, 0.0f, -1);
}

void JamSynth::control_change(int cc, float value, int64_t frame) {
	send(jam::EV_CC, cc, value, frame);
}

void JamSynth::pitch_bend(float value, int64_t frame) {
	send(jam::EV_BEND, 0, value, frame);
}

void JamSynth::set_tempo(float bpm) {
	tempo = bpm < 20.0f ? 20.0f : (bpm > 400.0f ? 400.0f : bpm);
	core->set_tempo_main(tempo);
	send(jam::EV_TEMPO, 0, tempo, -1);
}

void JamSynth::set_volume_db(float db) {
	volume_db = db;
	core->gain = jam::db_to_gain(db);
}

int64_t JamSynth::get_frame_position() const {
	return core->frame_pos.load();
}

float JamSynth::get_sample_rate() const {
	return core->sample_rate;
}

Vector2 JamSynth::take_peak() {
	const float l = core->peak_l.exchange(0.0f);
	const float r = core->peak_r.exchange(0.0f);
	return Vector2(l, r);
}

float JamSynth::get_cpu_load() const {
	return core->cpu_load.load();
}

bool JamSynth::is_playing() const {
	return core->active_playbacks.load() > 0;
}

PackedVector2Array JamSynth::render_offline(int frames, float sample_rate) {
	PackedVector2Array out;
	if (is_playing()) {
		UtilityFunctions::push_error("JamSynth.render_offline: stop playback first.");
		return out;
	}
	if (sample_rate != core->sample_rate) core->prepare(sample_rate);
	out.resize(frames);
	float *l = core->temp_l.data();
	float *r = core->temp_r.data();
	int done = 0;
	while (done < frames) {
		const int n = std::min<int>(frames - done, 256);
		core->process(l, r, n);
		for (int i = 0; i < n; i++) out.set(done + i, Vector2(l[i], r[i]));
		done += n;
	}
	return out;
}

bool JamSynth::push_custom(int a, int b, float value, void *ptr) {
	jam::Event e;
	e.type = jam::EV_CUSTOM;
	e.a = a;
	e.b = b;
	e.value = value;
	e.ptr = ptr;
	return core->push(e);
}

void JamSynth::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_instrument", "type"), &JamSynth::set_instrument);
	ClassDB::bind_method(D_METHOD("get_instrument"), &JamSynth::get_instrument);
	ClassDB::bind_static_method("JamSynth", D_METHOD("get_instrument_types"), &JamSynth::get_instrument_types);
	ClassDB::bind_method(D_METHOD("get_param_list"), &JamSynth::get_param_list);
	ClassDB::bind_method(D_METHOD("set_param", "id", "value"), &JamSynth::set_param);
	ClassDB::bind_method(D_METHOD("get_param", "id"), &JamSynth::get_param);
	ClassDB::bind_method(D_METHOD("get_params"), &JamSynth::get_params);
	ClassDB::bind_method(D_METHOD("set_params", "params"), &JamSynth::set_params);
	ClassDB::bind_method(D_METHOD("reset_params"), &JamSynth::reset_params);
	ClassDB::bind_method(D_METHOD("note_on", "note", "velocity", "frame"), &JamSynth::note_on, DEFVAL(1.0f), DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("note_off", "note", "frame"), &JamSynth::note_off, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("all_notes_off"), &JamSynth::all_notes_off);
	ClassDB::bind_method(D_METHOD("control_change", "cc", "value", "frame"), &JamSynth::control_change, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("pitch_bend", "value", "frame"), &JamSynth::pitch_bend, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("set_tempo", "bpm"), &JamSynth::set_tempo);
	ClassDB::bind_method(D_METHOD("get_tempo"), &JamSynth::get_tempo);
	ClassDB::bind_method(D_METHOD("set_volume_db", "db"), &JamSynth::set_volume_db);
	ClassDB::bind_method(D_METHOD("get_volume_db"), &JamSynth::get_volume_db);
	ClassDB::bind_method(D_METHOD("get_frame_position"), &JamSynth::get_frame_position);
	ClassDB::bind_method(D_METHOD("get_sample_rate"), &JamSynth::get_sample_rate);
	ClassDB::bind_method(D_METHOD("take_peak"), &JamSynth::take_peak);
	ClassDB::bind_method(D_METHOD("get_cpu_load"), &JamSynth::get_cpu_load);
	ClassDB::bind_method(D_METHOD("is_playing"), &JamSynth::is_playing);
	ClassDB::bind_method(D_METHOD("render_offline", "frames", "sample_rate"), &JamSynth::render_offline, DEFVAL(48000.0f));

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "instrument", PROPERTY_HINT_ENUM, "Undertow,Comet,Lumen,Pulsar,Driftwood,Tangle"), "set_instrument", "get_instrument");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "volume_db", PROPERTY_HINT_RANGE, "-60,12,0.1,suffix:dB"), "set_volume_db", "get_volume_db");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tempo", PROPERTY_HINT_RANGE, "20,400,0.1,suffix:BPM"), "set_tempo", "get_tempo");
}
