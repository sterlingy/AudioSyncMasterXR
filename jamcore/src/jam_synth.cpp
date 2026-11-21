#include "jam_synth.h"
#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

// ---------------- Playback ----------------

JamSynthPlayback::~JamSynthPlayback() {
	if (counted && core) core->active_playbacks.fetch_sub(1);
}

void JamSynthPlayback::setup(const std::shared_ptr<jam::SynthCore> &p_core) {
	core = p_core;
}

void JamSynthPlayback::_start(double p_from_pos) {
	if (!core) return;
	if (!counted) {
		core->active_playbacks.fetch_add(1);
		counted = true;
	}
	// The newest playback takes over; an older one (a player being restarted)
	// goes silent. All playbacks are mixed on the same audio thread, so the
	// handover never renders the core twice at once.
	token = core->owner_token.fetch_add(1) + 1;
	core->owner_current.store(token);
	playing = true;
}

void JamSynthPlayback::_stop() {
	playing = false;
	if (counted && core) {
		core->active_playbacks.fetch_sub(1);
		counted = false;
	}
}

bool JamSynthPlayback::_is_playing() const {
	return playing;
}

int32_t JamSynthPlayback::_mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) {
	if (!playing || !core || core->owner_current.load() != token || core->temp_l.empty()) {
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
	if (core->active_playbacks.load() == 0) ensure_rate((float)AudioServer::get_singleton()->get_mix_rate());
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
	main_inst = inst;
	tangle.reset();
	if (p_type == "Tangle") {
		tangle = std::make_unique<jam::TangleModel>();
		tangle->sample_rate = core->sample_rate;
		std::weak_ptr<jam::SynthCore> weak = core;
		tangle->send = [weak](int op, int b, int c, float v, void *ptr) {
			auto k = weak.lock();
			if (!k) return false;
			jam::Event e;
			e.type = jam::EV_CUSTOM;
			e.a = op;
			e.b = b;
			e.value = v;
			e.ptr = ptr;
			return k->push(e);
		};
		tangle->build_default();
	}
	notify_property_list_changed();
	emit_changed();
}

void JamSynth::ensure_rate(float sr) const {
	if (sr == core->sample_rate) return;
	core->prepare(sr);
	if (tangle) tangle->sample_rate = sr;
}

void JamSynth::collect() {
	core->collect_garbage();
	if (tangle && main_inst) tangle->collect(static_cast<jam::TangleInstrument *>(main_inst));
}

int JamSynth::index_of(const String &id) const {
	// Main thread: the instrument's param table is immutable after construction,
	// so reading it while the audio thread renders is safe.
	jam::Instrument *inst = main_inst;
	if (!inst) return -1;
	return inst->param_index(std::string(id.utf8().get_data()));
}

Array JamSynth::get_param_list() const {
	Array out;
	jam::Instrument *inst = main_inst;
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
	collect();
	if (!core->push(e)) UtilityFunctions::push_warning("JamSynth: event queue full, event dropped");
}

void JamSynth::set_param(const String &id, float value) {
	const int i = index_of(id);
	if (i < 0) {
		UtilityFunctions::push_warning("JamSynth(", instrument_type, "): unknown parameter '", id, "'");
		return;
	}
	const jam::ParamInfo &p = main_inst->params()[i];
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
	jam::Instrument *inst = main_inst;
	if (!inst) return d;
	const auto &ps = inst->params();
	for (size_t i = 0; i < ps.size(); i++) d[String(ps[i].id.c_str())] = values[i];
	if (tangle) d["patch"] = tangle_get_patch();
	return d;
}

void JamSynth::set_params(const Dictionary &params) {
	Array keys = params.keys();
	for (int i = 0; i < keys.size(); i++) {
		const String k = keys[i];
		if (index_of(k) >= 0) set_param(k, (float)params[k]);
	}
	if (tangle && params.has("patch")) tangle_set_patch(params["patch"]);
}

void JamSynth::reset_params() {
	jam::Instrument *inst = main_inst;
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
	collect();
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
	ensure_rate(sample_rate);
	collect();
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

// ---------------- Tangle ----------------

bool JamSynth::tangle_ok(const char *fn) const {
	if (tangle) return true;
	UtilityFunctions::push_error("JamSynth.", fn, ": instrument is ", instrument_type, ", not Tangle.");
	return false;
}

static Array ports_to_array(const std::vector<jam::PortInfo> &ports) {
	Array a;
	for (const jam::PortInfo &p : ports) {
		Dictionary d;
		d["id"] = String(p.id.c_str());
		d["name"] = String::utf8(p.name.c_str());
		a.push_back(d);
	}
	return a;
}

static Dictionary param_to_dict(const jam::ParamInfo &p, int index, float value) {
	Dictionary d;
	d["index"] = index;
	d["id"] = String(p.id.c_str());
	d["name"] = String::utf8(p.name.c_str());
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
	d["value"] = value;
	return d;
}

Array JamSynth::tangle_get_module_types() const {
	Array out;
	for (const jam::ModuleDesc &m : jam::tangle_modules()) {
		Dictionary d;
		d["type"] = String(m.type.c_str());
		d["name"] = String::utf8(m.name.c_str());
		d["description"] = String::utf8(m.description.c_str());
		d["inputs"] = ports_to_array(m.inputs);
		d["outputs"] = ports_to_array(m.outputs);
		Array ps;
		for (size_t i = 0; i < m.params.size(); i++) ps.push_back(param_to_dict(m.params[i], (int)i, m.params[i].def));
		d["params"] = ps;
		out.push_back(d);
	}
	return out;
}

int JamSynth::tangle_add_module(const String &type, Vector2 position) {
	if (!tangle_ok("tangle_add_module")) return -1;
	collect();
	return tangle->add(std::string(type.utf8().get_data()), position.x, position.y);
}

bool JamSynth::tangle_remove_module(int id) {
	if (!tangle_ok("tangle_remove_module")) return false;
	collect();
	return tangle->remove(id);
}

bool JamSynth::tangle_connect(int from_id, const String &out_port, int to_id, const String &in_port) {
	if (!tangle_ok("tangle_connect")) return false;
	collect();
	return tangle->connect(from_id, std::string(out_port.utf8().get_data()), to_id, std::string(in_port.utf8().get_data()));
}

bool JamSynth::tangle_disconnect(int to_id, const String &in_port) {
	if (!tangle_ok("tangle_disconnect")) return false;
	collect();
	return tangle->disconnect(to_id, std::string(in_port.utf8().get_data()));
}

bool JamSynth::tangle_set_param(int id, const String &param, float value) {
	if (!tangle_ok("tangle_set_param")) return false;
	return tangle->set_param(id, std::string(param.utf8().get_data()), value);
}

float JamSynth::tangle_get_param(int id, const String &param) const {
	if (!tangle_ok("tangle_get_param")) return 0.0f;
	return tangle->get_param(id, std::string(param.utf8().get_data()));
}

void JamSynth::tangle_set_position(int id, Vector2 position) {
	if (!tangle_ok("tangle_set_position")) return;
	if (id >= 0 && id < jam::TANGLE_MAX_MODULES && tangle->mods[id].id >= 0) {
		tangle->mods[id].x = position.x;
		tangle->mods[id].y = position.y;
	}
}

Dictionary JamSynth::tangle_get_patch() const {
	Dictionary patch;
	if (!tangle) return patch;
	const auto &descs = jam::tangle_modules();
	Array mods;
	for (const auto &m : tangle->mods) {
		if (m.id < 0) continue;
		const jam::ModuleDesc &d = descs[m.type];
		Dictionary md;
		md["id"] = m.id;
		md["type"] = String(d.type.c_str());
		md["position"] = Vector2(m.x, m.y);
		Dictionary ps;
		for (size_t i = 0; i < d.params.size(); i++) ps[String(d.params[i].id.c_str())] = m.params[i];
		md["params"] = ps;
		mods.push_back(md);
	}
	Array cables;
	for (const auto &c : tangle->cables) {
		Dictionary cd;
		cd["from"] = c.from;
		cd["out"] = String(descs[tangle->mods[c.from].type].outputs[c.out].id.c_str());
		cd["to"] = c.to;
		cd["in"] = String(descs[tangle->mods[c.to].type].inputs[c.in].id.c_str());
		cables.push_back(cd);
	}
	patch["modules"] = mods;
	patch["cables"] = cables;
	return patch;
}

bool JamSynth::tangle_set_patch(const Dictionary &patch) {
	if (!tangle_ok("tangle_set_patch")) return false;
	collect();
	tangle->clear();
	// Saved ids may not match the slots we get; map them.
	Dictionary remap;
	Array mods = patch.get("modules", Array());
	for (int i = 0; i < mods.size(); i++) {
		Dictionary md = mods[i];
		Vector2 pos = md.get("position", Vector2());
		const int id = tangle_add_module(md.get("type", ""), pos);
		if (id < 0) continue;
		remap[md.get("id", i)] = id;
		Dictionary ps = md.get("params", Dictionary());
		Array keys = ps.keys();
		for (int k = 0; k < keys.size(); k++) tangle_set_param(id, keys[k], ps[keys[k]]);
	}
	Array cables = patch.get("cables", Array());
	for (int i = 0; i < cables.size(); i++) {
		Dictionary cd = cables[i];
		if (!remap.has(cd.get("from", -1)) || !remap.has(cd.get("to", -1))) continue;
		tangle_connect(remap[cd["from"]], cd.get("out", ""), remap[cd["to"]], cd.get("in", ""));
	}
	return true;
}

void JamSynth::tangle_clear() {
	if (!tangle_ok("tangle_clear")) return;
	collect();
	tangle->clear();
}

void JamSynth::tangle_load_default() {
	if (!tangle_ok("tangle_load_default")) return;
	collect();
	tangle->build_default();
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

	ClassDB::bind_method(D_METHOD("tangle_get_module_types"), &JamSynth::tangle_get_module_types);
	ClassDB::bind_method(D_METHOD("tangle_add_module", "type", "position"), &JamSynth::tangle_add_module, DEFVAL(Vector2()));
	ClassDB::bind_method(D_METHOD("tangle_remove_module", "id"), &JamSynth::tangle_remove_module);
	ClassDB::bind_method(D_METHOD("tangle_connect", "from_id", "out_port", "to_id", "in_port"), &JamSynth::tangle_connect);
	ClassDB::bind_method(D_METHOD("tangle_disconnect", "to_id", "in_port"), &JamSynth::tangle_disconnect);
	ClassDB::bind_method(D_METHOD("tangle_set_param", "id", "param", "value"), &JamSynth::tangle_set_param);
	ClassDB::bind_method(D_METHOD("tangle_get_param", "id", "param"), &JamSynth::tangle_get_param);
	ClassDB::bind_method(D_METHOD("tangle_set_position", "id", "position"), &JamSynth::tangle_set_position);
	ClassDB::bind_method(D_METHOD("tangle_get_patch"), &JamSynth::tangle_get_patch);
	ClassDB::bind_method(D_METHOD("tangle_set_patch", "patch"), &JamSynth::tangle_set_patch);
	ClassDB::bind_method(D_METHOD("tangle_clear"), &JamSynth::tangle_clear);
	ClassDB::bind_method(D_METHOD("tangle_load_default"), &JamSynth::tangle_load_default);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "instrument", PROPERTY_HINT_ENUM, "Undertow,Comet,Lumen,Pulsar,Driftwood,Tangle"), "set_instrument", "get_instrument");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "volume_db", PROPERTY_HINT_RANGE, "-60,12,0.1,suffix:dB"), "set_volume_db", "get_volume_db");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tempo", PROPERTY_HINT_RANGE, "20,400,0.1,suffix:BPM"), "set_tempo", "get_tempo");
}
