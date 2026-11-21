// Tangle: modular synth. Modules process 32-sample blocks; cables connect any
// output to any input (one cable per input, fan-out allowed). A cable that
// closes a loop adds one block (0.67 ms) of delay, like a real feedback patch.
//
// Threading: the main thread owns TangleModel (what the patch looks like) and
// builds modules and routing tables; the audio thread (TangleInstrument) only
// swaps pointers it receives through the event queue. Old objects go back on a
// garbage queue and are deleted on the main thread.
#pragma once
#include "engine/event_queue.h"
#include "engine/instrument.h"
#include <functional>
#include <string>
#include <vector>

namespace jam {

constexpr int TB = 32; // block size
constexpr int TANGLE_MAX_MODULES = 32;
constexpr int TANGLE_MAX_PORTS = 8;

struct PortInfo {
	std::string id;
	std::string name;
};

struct TangleCtx {
	float sr = 48000.0f;
	float tempo = 120.0f;
	double beat = 0.0; // musical position at block start, in beats
	double beats_per_sample = 0.0;
	// Keyboard state for MIDI->CV
	float pitch = 0.0f; // V/oct, 0 = C4
	float velocity = 0.0f;
	float mod = 0.0f;
	float pressure = 0.0f;
	float bend = 0.0f; // -1..1
	bool gate = false;
	int retrig_at = -1; // sample within block where a new note started, -1 none
	float out_l[TB];
	float out_r[TB];
};

class Module {
public:
	virtual ~Module() {}
	virtual void prepare(float sr) { this->sr = sr; }
	virtual void process(TangleCtx &ctx) = 0;
	virtual void param_changed(int i) {}

	const float *in[TANGLE_MAX_PORTS] = {};
	bool connected[TANGLE_MAX_PORTS] = {};
	float out[TANGLE_MAX_PORTS][TB] = {};
	std::vector<float> p;
	float sr = 48000.0f;
	int type_index = -1;
};

struct ModuleDesc {
	std::string type; // stable key: "vco"
	std::string name; // "VCO"
	std::string description;
	std::vector<PortInfo> inputs;
	std::vector<PortInfo> outputs;
	std::vector<ParamInfo> params;
	std::function<Module *()> make;
};

const std::vector<ModuleDesc> &tangle_modules();
int tangle_module_index(const std::string &type);

// Routing table: for each slot and input, the (slot, output port) feeding it.
struct TangleRouting {
	int order[TANGLE_MAX_MODULES];
	int count = 0;
	int src_slot[TANGLE_MAX_MODULES][TANGLE_MAX_PORTS];
	int src_port[TANGLE_MAX_MODULES][TANGLE_MAX_PORTS];
	TangleRouting() {
		for (int s = 0; s < TANGLE_MAX_MODULES; s++)
			for (int i = 0; i < TANGLE_MAX_PORTS; i++) src_slot[s][i] = src_port[s][i] = -1;
	}
};

enum TangleOp {
	TOP_ADD = 1, // b = slot, ptr = Module*
	TOP_REMOVE, // b = slot
	TOP_ROUTING, // ptr = TangleRouting*
	TOP_PARAM, // b = slot, a2 = param (packed), value
};

struct TangleGarbage {
	Module *module = nullptr;
	TangleRouting *routing = nullptr;
};

class TangleInstrument : public Instrument {
public:
	TangleInstrument();
	~TangleInstrument() override;
	const char *type_name() const override { return "Tangle"; }
	void prepare(float sr) override;
	void note_on(int note, float vel) override;
	void note_off(int note) override;
	void all_notes_off() override;
	void control_change(int cc, float value) override;
	void custom_event(const Event &e) override;
	void set_transport(double beat, bool running) override;
	void render(float *l, float *r, int n) override;

	SpscQueue<TangleGarbage, 256> garbage; // audio -> main

private:
	void run_block();
	Module *slots[TANGLE_MAX_MODULES] = {};
	TangleRouting *routing = nullptr;
	TangleCtx ctx;
	float zeros[TB] = {};
	float block_l[TB] = {}, block_r[TB] = {};
	int block_pos = TB; // samples of block_l/r already consumed
	int held[16];
	int nheld = 0;
	bool new_note = false;
};

// Main-thread description of a patch, mirrored into the audio thread.
class TangleModel {
public:
	struct Mod {
		int id = -1;
		int type = -1;
		float x = 0, y = 0;
		std::vector<float> params;
	};
	struct Cable {
		int from = -1, out = -1, to = -1, in = -1;
	};
	std::vector<Mod> mods; // index = slot, id = slot
	std::vector<Cable> cables;

	// `send` pushes an EV_CUSTOM event; returns false if the queue is full.
	using Sender = std::function<bool(int op, int b, int c, float v, void *ptr)>;
	Sender send;
	float sample_rate = 48000.0f;

	TangleModel();
	int add(const std::string &type, float x, float y);
	bool remove(int id);
	bool connect(int from, const std::string &out, int to, const std::string &in);
	bool disconnect(int to, const std::string &in);
	bool set_param(int id, const std::string &param, float v);
	float get_param(int id, const std::string &param) const;
	void clear();
	void build_default();
	const Mod *get(int id) const;
	void collect(TangleInstrument *inst);

private:
	void push_routing();
};

} // namespace jam
