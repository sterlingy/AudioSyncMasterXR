// Instrument base class and parameter descriptions.
#pragma once
#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

namespace jam {

struct Event;

enum ParamType { P_FLOAT = 0, P_INT, P_ENUM, P_BOOL };

// One knob, switch or selector. `id` is the stable key used in presets
// ("osc1.range"); `group` is the panel section it belongs to.
struct ParamInfo {
	std::string id;
	std::string name;
	std::string group;
	ParamType type = P_FLOAT;
	float min = 0.0f;
	float max = 1.0f;
	float def = 0.0f;
	std::string unit;
	std::vector<std::string> options; // P_ENUM labels
	bool log_scale = false; // knob moves geometrically (frequencies, times)
};

// Builder helpers used by instrument tables.
inline ParamInfo pf(const char *id, const char *name, const char *group, float mn, float mx, float df, const char *unit = "", bool log_scale = false) {
	ParamInfo p;
	p.id = id;
	p.name = name;
	p.group = group;
	p.type = P_FLOAT;
	p.min = mn;
	p.max = mx;
	p.def = df;
	p.unit = unit;
	p.log_scale = log_scale;
	return p;
}
inline ParamInfo pi(const char *id, const char *name, const char *group, int mn, int mx, int df, const char *unit = "") {
	ParamInfo p = pf(id, name, group, (float)mn, (float)mx, (float)df, unit);
	p.type = P_INT;
	return p;
}
inline ParamInfo pe(const char *id, const char *name, const char *group, std::vector<std::string> opts, int df) {
	ParamInfo p = pf(id, name, group, 0.0f, (float)(opts.size() - 1), (float)df);
	p.type = P_ENUM;
	p.options = std::move(opts);
	return p;
}
inline ParamInfo pb(const char *id, const char *name, const char *group, bool df) {
	ParamInfo p = pf(id, name, group, 0.0f, 1.0f, df ? 1.0f : 0.0f);
	p.type = P_BOOL;
	return p;
}

// Base for every synth. All methods except describe/prepare run on the audio thread.
class Instrument {
public:
	virtual ~Instrument() {}
	virtual const char *type_name() const = 0;

	// Main thread, before playback starts: allocate buffers, set sample rate.
	virtual void prepare(float sample_rate) = 0;

	virtual void note_on(int note, float velocity) = 0;
	virtual void note_off(int note) = 0;
	virtual void all_notes_off() = 0;
	virtual void pitch_bend(float value) { bend = value; } // -1..1
	virtual void control_change(int cc, float value) {
		if (cc == 1) mod_wheel = value;
		else if (cc == 64) set_sustain(value >= 0.5f);
	}
	virtual void set_sustain(bool on) { sustain_pedal = on; }
	virtual void set_tempo(float bpm) { tempo = bpm; }
	// The transport's beat position at the moment this is applied (sample-accurate).
	virtual void set_transport(double beat, bool running) {}
	virtual void param_changed(int index) {}
	// Instrument-specific commands (Tangle patch edits). Audio thread.
	virtual void custom_event(const Event &e) {}

	// Render n stereo frames, ADDING into l/r (the caller clears them).
	virtual void render(float *l, float *r, int n) = 0;

	const std::vector<ParamInfo> &params() const { return info; }
	int param_index(const std::string &id) const {
		for (size_t i = 0; i < info.size(); i++)
			if (info[i].id == id) return (int)i;
		return -1;
	}
	void set_param(int index, float v) {
		if (index < 0 || index >= (int)values.size()) return;
		const ParamInfo &p = info[index];
		if (v < p.min) v = p.min;
		if (v > p.max) v = p.max;
		if (p.type != P_FLOAT) v = (float)(int)(v + 0.5f);
		values[index] = v;
		param_changed(index);
	}
	float get_param(int index) const { return (index >= 0 && index < (int)values.size()) ? values[index] : 0.0f; }

protected:
	void finish_params() {
		values.resize(info.size());
		for (size_t i = 0; i < info.size(); i++) values[i] = info[i].def;
	}
	inline float p(int index) const { return values[index]; }
	inline int pi_(int index) const { return (int)values[index]; }

	std::vector<ParamInfo> info;
	std::vector<float> values;
	float sr = 48000.0f;
	float bend = 0.0f;
	float mod_wheel = 0.0f;
	float tempo = 120.0f;
	bool sustain_pedal = false;
};

Instrument *create_instrument(const std::string &type);
std::vector<std::string> instrument_types();

} // namespace jam
