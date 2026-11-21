// Driftwood: physically modelled plucks and mallets. 8 voices.
// Pluck = Karplus-Strong string with pick position and body; mallet models
// = banks of tuned resonators (marimba, vibes, kalimba, bell, glass).
#include "dsp/env.h"
#include "dsp/filters.h"
#include "dsp/fx.h"
#include "engine/instrument.h"
#include "poly.h"

namespace jam {

class Driftwood : public Instrument {
	static constexpr int NV = 8;
	static constexpr int NMODES = 6;
	enum Model { STRING = 0, MARIMBA, VIBES, KALIMBA, BELL, GLASS, MODEL_COUNT };
	enum P {
		MODEL, BRIGHTNESS, HARDNESS, DECAY, DAMPING, POSITION, INHARM, BODY, VEL,
		TREMOLO, TREM_RATE, SPREAD,
		RV_SIZE, RV_DECAY, RV_MIX,
		VOLUME, COUNT
	};
	struct Voice {
		// String
		DelayLine line;
		OnePole loop_lp;
		float loop_gain = 0.99f;
		float period = 100.0f;
		float excite_left = 0.0f; // samples of excitation remaining
		OnePole excite_lp;
		DelayLine pick; // pick-position comb
		float pick_delay = 10.0f;
		// Modal
		Resonator modes[NMODES];
		float mode_gain[NMODES];
		DecayEnv strike;
		float strike_norm = 1.0f;
		OnePole strike_lp;
		// Common
		DecayEnv release;
		bool released = false;
		bool active = false;
		float vel = 1.0f;
		float energy = 0.0f;
		float pan = 0.0f;
		int model = STRING;
	};
	Voice voices[NV];
	VoiceAllocator<NV> alloc;
	Rng rng;
	Resonator body_l, body_r;
	Reverb reverb;
	DcBlocker dc_l, dc_r;
	float trem_phase = 0.0f;
	int pan_counter = 0;

public:
	Driftwood() {
		info.resize(COUNT);
		info[MODEL] = pe("model.type", "Model", "Model", { "String", "Marimba", "Vibes", "Kalimba", "Bell", "Glass" }, 0);
		info[BRIGHTNESS] = pf("model.brightness", "Brightness", "Model", 0, 10, 6);
		info[HARDNESS] = pf("model.hardness", "Hardness (Pick/Mallet)", "Model", 0, 10, 5);
		info[DECAY] = pf("model.decay", "Decay", "Model", 0.05f, 20, 2.5f, "s", true);
		info[DAMPING] = pf("model.damping", "Damping (Highs)", "Model", 0, 10, 4);
		info[POSITION] = pf("model.position", "Pick/Strike Position", "Model", 0, 10, 2.5f);
		info[INHARM] = pf("model.inharmonicity", "Inharmonicity", "Model", 0, 10, 0);
		info[BODY] = pf("body.amount", "Body Resonance", "Body", 0, 10, 3);
		info[VEL] = pf("perf.velocity", "Velocity Sensitivity", "Performance", 0, 10, 6);
		info[TREMOLO] = pf("perf.tremolo", "Tremolo (Vibes Motor)", "Performance", 0, 10, 0);
		info[TREM_RATE] = pf("perf.tremolo_rate", "Tremolo Rate", "Performance", 0.5f, 10, 5, "Hz");
		info[SPREAD] = pf("perf.spread", "Stereo Spread", "Performance", 0, 10, 5);
		info[RV_SIZE] = pf("reverb.size", "Size", "Reverb", 0, 10, 5);
		info[RV_DECAY] = pf("reverb.decay", "Decay", "Reverb", 0.2f, 12, 2.0f, "s", true);
		info[RV_MIX] = pf("reverb.mix", "Mix", "Reverb", 0, 10, 2);
		info[VOLUME] = pf("out.volume", "Volume", "Output", 0, 10, 7);
		finish_params();
	}
	const char *type_name() const override { return "Driftwood"; }

	void prepare(float p_sr) override {
		sr = p_sr;
		for (Voice &v : voices) {
			v.line.init((int)(sr / 20.0f) + 8); // down to 20 Hz
			v.pick.init((int)(sr / 20.0f) + 8);
			v.strike.init(sr);
			v.release.init(sr);
		}
		reverb.init(sr);
		dc_l.init(sr);
		dc_r.init(sr);
		body_l.set_peak_unity(180.0f, 0.03f, sr);
		body_r.set_peak_unity(240.0f, 0.03f, sr);
	}

	// Mode frequency ratios and relative decays for each mallet model.
	static void mode_table(int model, float *ratio, float *decay, float *gain) {
		static const float marimba_r[NMODES] = { 1.0f, 3.99f, 9.9f, 2.0f, 6.0f, 14.5f };
		static const float vibes_r[NMODES] = { 1.0f, 4.0f, 10.0f, 2.76f, 5.4f, 8.93f };
		static const float kalimba_r[NMODES] = { 1.0f, 5.4f, 9.6f, 2.0f, 12.8f, 3.0f };
		static const float bell_r[NMODES] = { 0.5f, 1.0f, 1.19f, 1.56f, 2.0f, 2.66f };
		static const float glass_r[NMODES] = { 1.0f, 2.32f, 4.25f, 6.63f, 9.38f, 12.6f };
		static const float marimba_d[NMODES] = { 1.0f, 0.35f, 0.15f, 0.3f, 0.2f, 0.1f };
		static const float vibes_d[NMODES] = { 1.0f, 0.6f, 0.3f, 0.4f, 0.3f, 0.2f };
		static const float kalimba_d[NMODES] = { 1.0f, 0.3f, 0.2f, 0.4f, 0.1f, 0.25f };
		static const float bell_d[NMODES] = { 1.0f, 0.9f, 0.7f, 0.6f, 0.5f, 0.4f };
		static const float glass_d[NMODES] = { 1.0f, 0.8f, 0.6f, 0.5f, 0.4f, 0.3f };
		static const float marimba_g[NMODES] = { 1.0f, 0.4f, 0.15f, 0.08f, 0.06f, 0.03f };
		static const float vibes_g[NMODES] = { 1.0f, 0.5f, 0.2f, 0.1f, 0.08f, 0.05f };
		static const float kalimba_g[NMODES] = { 1.0f, 0.35f, 0.2f, 0.12f, 0.08f, 0.1f };
		static const float bell_g[NMODES] = { 0.33f, 0.55f, 0.39f, 0.28f, 0.25f, 0.19f };
		static const float glass_g[NMODES] = { 1.0f, 0.6f, 0.4f, 0.3f, 0.2f, 0.15f };
		const float *r = marimba_r, *d = marimba_d, *g = marimba_g;
		if (model == VIBES) { r = vibes_r; d = vibes_d; g = vibes_g; }
		else if (model == KALIMBA) { r = kalimba_r; d = kalimba_d; g = kalimba_g; }
		else if (model == BELL) { r = bell_r; d = bell_d; g = bell_g; }
		else if (model == GLASS) { r = glass_r; d = glass_d; g = glass_g; }
		for (int k = 0; k < NMODES; k++) {
			ratio[k] = r[k];
			decay[k] = d[k];
			gain[k] = g[k];
		}
	}

	void note_on(int note, float vel) override {
		const int i = alloc.allocate(note, [this](int k) { return voices[k].active; });
		Voice &v = voices[i];
		const float sens = p(VEL) * 0.1f;
		v.vel = 1.0f - sens * (1.0f - vel);
		v.model = pi_(MODEL);
		v.active = true;
		v.released = false;
		v.energy = 1.0f;
		static const float pans[NV] = { -0.6f, 0.6f, -0.3f, 0.3f, -0.85f, 0.85f, -0.1f, 0.1f };
		v.pan = pans[(pan_counter++) & (NV - 1)];
		const float f = midi_to_hz((float)note);
		const float bright = p(BRIGHTNESS) * 0.1f * (0.6f + 0.4f * vel);
		const float hard = p(HARDNESS) * 0.1f;
		if (v.model == STRING) {
			v.period = sr / f;
			v.line.clear();
			v.pick.clear();
			const float decay = p(DECAY);
			v.loop_gain = std::pow(10.0f, -3.0f / (decay * f)); // RT60 = decay
			v.loop_lp.set(exp_map(1.0f - p(DAMPING) * 0.1f, 1500.0f, 16000.0f), sr);
			v.excite_lp.set(exp_map(bright, 300.0f, 16000.0f), sr);
			v.excite_left = v.period * (0.5f + (1.0f - hard) * 1.5f);
			v.pick_delay = std::max(1.0f, v.period * (0.02f + p(POSITION) * 0.1f * 0.48f));
		} else {
			float ratio[NMODES], decay[NMODES], gain[NMODES];
			mode_table(v.model, ratio, decay, gain);
			const float stretch = p(INHARM) * 0.1f * 0.08f;
			const float dec = p(DECAY);
			const float damp = p(DAMPING) * 0.1f;
			const float pos = p(POSITION) * 0.1f;
			for (int k = 0; k < NMODES; k++) {
				const float rk = ratio[k] * (1.0f + stretch * k * k);
				const float fk = f * rk;
				// Higher modes die faster; damping shortens them further.
				const float dk = dec * decay[k] * (1.0f - damp * 0.8f * std::min(1.0f, (rk - 1.0f) / 8.0f));
				v.modes[k].reset();
				v.modes[k].set_normalized(fk, std::max(0.01f, dk), sr);
				// Strike position: modes with a node near the strike point are weaker.
				const float pos_g = std::fabs(std::sin(PI * (k + 1) * (0.05f + pos * 0.45f)));
				const float bright_g = k == 0 ? 1.0f : std::pow(bright, 0.5f * k);
				v.mode_gain[k] = fk < sr * 0.45f ? gain[k] * bright_g * (0.3f + 0.7f * pos_g) * 2.2f : 0.0f;
			}
			const float strike_s = 0.0008f + (1.0f - hard) * 0.006f;
			v.strike.trigger(1.0f, strike_s);
			v.strike_norm = 1.0f / std::max(1.0f, strike_s / 4.6f * sr);
			v.strike_lp.set(exp_map(bright * 0.5f + hard * 0.5f, 400.0f, 16000.0f), sr);
		}
	}
	void note_off(int note) override {
		const int i = alloc.release(note, sustain_pedal);
		if (i >= 0) release_voice(voices[i]);
	}
	void release_voice(Voice &v) {
		// Strings and bars ring on when released, but a damped string stops sooner.
		if (v.model == STRING) {
			v.released = true;
			v.release.trigger(1.0f, std::min(p(DECAY), 0.35f));
		}
	}
	void set_sustain(bool on) override {
		sustain_pedal = on;
		if (!on)
			for (int i = 0; i < NV; i++)
				if (alloc.slots[i].sustained) {
					alloc.slots[i].sustained = false;
					release_voice(voices[i]);
				}
	}
	void all_notes_off() override {
		for (int i = 0; i < NV; i++) {
			alloc.slots[i].held = alloc.slots[i].sustained = false;
			release_voice(voices[i]);
		}
	}

	inline float render_voice(Voice &v) {
		float y = 0.0f;
		if (v.model == STRING) {
			float ex = 0.0f;
			if (v.excite_left > 0.0f) {
				ex = v.excite_lp.lp(rng.white()) * v.vel;
				v.excite_left -= 1.0f;
				// Pick-position comb: subtract a delayed copy of the excitation.
				v.pick.write(ex);
				ex -= v.pick.read(v.pick_delay);
			}
			const float fb = v.line.read(v.period - 0.5f); // -0.5 compensates the averaging filter
			float g = v.loop_gain;
			if (v.released) g *= 0.999f;
			const float s = v.loop_lp.lp(fb) * g;
			v.line.write(undenormal(s + ex));
			y = s * 0.9f;
			if (v.released) y *= v.release.process() + 0.0f;
		} else {
			float ex = 0.0f;
			if (v.strike.active()) ex = v.strike_lp.lp(rng.white() * 0.5f + 1.0f) * v.strike.process() * v.vel * v.strike_norm;
			for (int k = 0; k < NMODES; k++) y += v.modes[k].process(ex) * v.mode_gain[k];
		}
		const float a = y < 0 ? -y : y;
		v.energy = v.energy * 0.9995f + a * 0.0005f * 50.0f;
		return y;
	}

	void render(float *l, float *r, int n) override {
		bool any = false;
		for (Voice &v : voices) any = any || v.active;
		const float rv_mix = p(RV_MIX) * 0.1f;
		if (!any && rv_mix <= 0.001f) return;
		const float spread = p(SPREAD) * 0.1f;
		const float body = p(BODY) * 0.1f;
		const float trem = p(TREMOLO) * 0.1f;
		const float trem_rate = p(TREM_RATE);
		const float vol = p(VOLUME) * 0.1f * 0.9f;
		const float rv_size = p(RV_SIZE) * 0.1f, rv_decay = p(RV_DECAY);
		float gl[NV], gr[NV];
		for (int k = 0; k < NV; k++) {
			const float a = (voices[k].pan * spread + 1.0f) * 0.25f * PI;
			gl[k] = std::cos(a);
			gr[k] = std::sin(a);
		}
		for (int i = 0; i < n; i++) {
			float sl = 0.0f, srr = 0.0f;
			for (int k = 0; k < NV; k++) {
				Voice &v = voices[k];
				if (!v.active) continue;
				const float s = render_voice(v);
				sl += s * gl[k];
				srr += s * gr[k];
				if (v.energy < 0.0005f && !v.strike.active() && v.excite_left <= 0.0f) {
					v.active = false;
					alloc.slots[k].held = false;
				}
			}
			if (trem > 0.0f) {
				trem_phase += trem_rate / sr;
				if (trem_phase >= 1.0f) trem_phase -= 1.0f;
				const float t = 1.0f - trem * 0.5f * (1.0f + std::sin(TWO_PI * trem_phase));
				sl *= t;
				srr *= t;
			}
			if (body > 0.0f) {
				sl += body_l.process(sl) * body * 1.5f;
				srr += body_r.process(srr) * body * 1.5f;
			}
			sl = dc_l.process(sl * vol);
			srr = dc_r.process(srr * vol);
			if (rv_mix > 0.001f) reverb.process(sl, srr, rv_size, rv_decay, 0.4f, 0.01f, rv_mix);
			l[i] += sl;
			r[i] += srr;
		}
	}
};

Instrument *make_driftwood() { return new Driftwood(); }

} // namespace jam
