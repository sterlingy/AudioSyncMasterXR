// Lumen: 8-voice polyphonic keys/pad synth. Two oscillators + noise per voice,
// multimode filter with envelope, LFO, analog drift, stereo spread, chorus, reverb.
#include "dsp/env.h"
#include "dsp/filters.h"
#include "dsp/fx.h"
#include "dsp/osc.h"
#include "engine/instrument.h"
#include "poly.h"

namespace jam {

class Lumen : public Instrument {
	static constexpr int NV = 8;
	enum P {
		O1_WAVE, O1_PW, O1_LEVEL,
		O2_WAVE, O2_SEMI, O2_FINE, O2_LEVEL,
		NOISE, DRIFT,
		F_MODE, F_CUTOFF, F_RES, F_ENV, F_KEY, F_VEL,
		FE_A, FE_D, FE_S, FE_R,
		AE_A, AE_D, AE_S, AE_R, AE_VEL,
		LFO_RATE, LFO_SHAPE, LFO_PITCH, LFO_FILTER, LFO_PWM,
		POLY, SPREAD, BEND_RANGE,
		CH_ON, CH_RATE, CH_DEPTH, CH_MIX,
		RV_SIZE, RV_DECAY, RV_DAMP, RV_MIX,
		VOLUME,
		COUNT
	};
	struct Voice {
		Osc o1, o2;
		MultiFilter filt;
		Adsr fenv, aenv;
		float note = 60.0f;
		float vel = 1.0f;
		float pan = 0.0f;
		float drift = 0.0f;
		float drift_target = 0.0f;
	};
	Voice voices[NV];
	VoiceAllocator<NV> alloc;
	Lfo lfo;
	Chorus chorus;
	Reverb reverb;
	Rng rng;
	DcBlocker dc_l, dc_r;
	int pan_counter = 0;

public:
	Lumen() {
		const std::vector<std::string> waves = { "Saw", "Square", "Pulse", "Triangle", "Sine" };
		info.resize(COUNT);
		info[O1_WAVE] = pe("osc1.wave", "Waveform", "Oscillator 1", waves, 0);
		info[O1_PW] = pf("osc1.pw", "Pulse Width", "Oscillator 1", 0.05f, 0.95f, 0.5f);
		info[O1_LEVEL] = pf("osc1.level", "Level", "Oscillator 1", 0, 10, 7);
		info[O2_WAVE] = pe("osc2.wave", "Waveform", "Oscillator 2", waves, 0);
		info[O2_SEMI] = pi("osc2.semi", "Semitones", "Oscillator 2", -24, 24, 0, "st");
		info[O2_FINE] = pf("osc2.fine", "Detune", "Oscillator 2", -50, 50, 9, "ct");
		info[O2_LEVEL] = pf("osc2.level", "Level", "Oscillator 2", 0, 10, 6);
		info[NOISE] = pf("mix.noise", "Noise", "Mixer", 0, 10, 0);
		info[DRIFT] = pf("mix.drift", "Analog Drift", "Mixer", 0, 10, 3);
		info[F_MODE] = pe("filter.mode", "Mode", "Filter", { "LP 24", "LP 12", "Band Pass", "High Pass" }, 1);
		info[F_CUTOFF] = pf("filter.cutoff", "Cutoff", "Filter", 30, 18000, 2500, "Hz", true);
		info[F_RES] = pf("filter.resonance", "Resonance", "Filter", 0, 10, 2);
		info[F_ENV] = pf("filter.env", "Envelope Amount", "Filter", -10, 10, 3);
		info[F_KEY] = pf("filter.keytrack", "Key Tracking", "Filter", 0, 10, 5);
		info[F_VEL] = pf("filter.velocity", "Velocity", "Filter", 0, 10, 4);
		info[FE_A] = pf("fenv.attack", "Attack", "Filter Envelope", 0.001f, 10, 0.01f, "s", true);
		info[FE_D] = pf("fenv.decay", "Decay", "Filter Envelope", 0.005f, 10, 0.8f, "s", true);
		info[FE_S] = pf("fenv.sustain", "Sustain", "Filter Envelope", 0, 10, 4);
		info[FE_R] = pf("fenv.release", "Release", "Filter Envelope", 0.005f, 10, 0.6f, "s", true);
		info[AE_A] = pf("aenv.attack", "Attack", "Amp Envelope", 0.001f, 10, 0.01f, "s", true);
		info[AE_D] = pf("aenv.decay", "Decay", "Amp Envelope", 0.005f, 10, 1.0f, "s", true);
		info[AE_S] = pf("aenv.sustain", "Sustain", "Amp Envelope", 0, 10, 7);
		info[AE_R] = pf("aenv.release", "Release", "Amp Envelope", 0.005f, 10, 0.7f, "s", true);
		info[AE_VEL] = pf("aenv.velocity", "Velocity", "Amp Envelope", 0, 10, 6);
		info[LFO_RATE] = pf("lfo.rate", "Rate", "LFO", 0.05f, 20, 0.8f, "Hz", true);
		info[LFO_SHAPE] = pe("lfo.shape", "Shape", "LFO", { "Sine", "Triangle", "Saw", "Square", "Random" }, 0);
		info[LFO_PITCH] = pf("lfo.pitch", "To Pitch", "LFO", 0, 10, 0);
		info[LFO_FILTER] = pf("lfo.filter", "To Filter", "LFO", 0, 10, 0);
		info[LFO_PWM] = pf("lfo.pwm", "To Pulse Width", "LFO", 0, 10, 0);
		info[POLY] = pi("voice.polyphony", "Polyphony", "Voice", 1, NV, NV);
		info[SPREAD] = pf("voice.spread", "Stereo Spread", "Voice", 0, 10, 5);
		info[BEND_RANGE] = pi("voice.bend_range", "Bend Range", "Voice", 1, 12, 2, "st");
		info[CH_ON] = pb("chorus.on", "Chorus", "Chorus", true);
		info[CH_RATE] = pf("chorus.rate", "Rate", "Chorus", 0.05f, 5, 0.5f, "Hz", true);
		info[CH_DEPTH] = pf("chorus.depth", "Depth", "Chorus", 0, 10, 5);
		info[CH_MIX] = pf("chorus.mix", "Mix", "Chorus", 0, 10, 4);
		info[RV_SIZE] = pf("reverb.size", "Size", "Reverb", 0, 10, 6);
		info[RV_DECAY] = pf("reverb.decay", "Decay", "Reverb", 0.2f, 15, 2.5f, "s", true);
		info[RV_DAMP] = pf("reverb.damping", "Damping", "Reverb", 0, 10, 4);
		info[RV_MIX] = pf("reverb.mix", "Mix", "Reverb", 0, 10, 2.5f);
		info[VOLUME] = pf("out.volume", "Volume", "Output", 0, 10, 7);
		finish_params();
	}
	const char *type_name() const override { return "Lumen"; }

	void prepare(float p_sr) override {
		sr = p_sr;
		for (Voice &v : voices) {
			v.filt.init(sr);
			v.fenv.init(sr);
			v.aenv.init(sr);
		}
		chorus.init(sr);
		reverb.init(sr);
		dc_l.init(sr);
		dc_r.init(sr);
		update();
	}
	void update() {
		for (Voice &v : voices) {
			v.fenv.set(p(FE_A), p(FE_D), p(FE_S) * 0.1f, p(FE_R));
			v.aenv.set(p(AE_A), p(AE_D), p(AE_S) * 0.1f, p(AE_R));
		}
		alloc.polyphony = pi_(POLY);
	}
	void param_changed(int i) override {
		if ((i >= FE_A && i <= AE_R) || i == POLY) update();
	}

	void note_on(int note, float vel) override {
		const int i = alloc.allocate(note, [this](int k) { return voices[k].aenv.active(); });
		Voice &v = voices[i];
		v.note = (float)note;
		v.vel = vel;
		// Alternate voices left/right so chords spread across the stereo field.
		static const float pans[NV] = { -0.7f, 0.7f, -0.35f, 0.35f, -0.9f, 0.9f, -0.15f, 0.15f };
		v.pan = pans[(pan_counter++) & (NV - 1)];
		v.drift_target = rng.white();
		v.fenv.gate_on(true);
		v.aenv.gate_on(true);
	}
	void note_off(int note) override {
		const int i = alloc.release(note, sustain_pedal);
		if (i >= 0) {
			voices[i].fenv.gate_off();
			voices[i].aenv.gate_off();
		}
	}
	void set_sustain(bool on) override {
		sustain_pedal = on;
		if (!on) {
			for (int i = 0; i < NV; i++) {
				if (alloc.slots[i].sustained) {
					alloc.slots[i].sustained = false;
					voices[i].fenv.gate_off();
					voices[i].aenv.gate_off();
				}
			}
		}
	}
	void all_notes_off() override {
		for (int i = 0; i < NV; i++) {
			alloc.slots[i].held = alloc.slots[i].sustained = false;
			voices[i].fenv.gate_off();
			voices[i].aenv.gate_off();
		}
	}

	static int wave(int w) {
		static const int map[] = { WAVE_SAW, WAVE_SQUARE, WAVE_PULSE, WAVE_TRIANGLE, WAVE_SINE };
		return map[w < 0 ? 0 : (w > 4 ? 4 : w)];
	}

	void render(float *l, float *r, int n) override {
		const int w1 = wave(pi_(O1_WAVE)), w2 = wave(pi_(O2_WAVE));
		const float lv1 = p(O1_LEVEL) * 0.1f, lv2 = p(O2_LEVEL) * 0.1f, lvn = p(NOISE) * 0.1f;
		const float o2_off = (float)pi_(O2_SEMI) + p(O2_FINE) * 0.01f;
		const float drift_amt = p(DRIFT) * 0.1f * 0.15f; // up to 15 cents
		const int mode = pi_(F_MODE);
		const float res = p(F_RES) * 0.1f;
		const float cut_base = std::log2(p(F_CUTOFF));
		const float env_oct = p(F_ENV) * 0.5f;
		const float key = p(F_KEY) * 0.1f;
		const float fvel = p(F_VEL) * 0.1f * 2.0f;
		const float avel = p(AE_VEL) * 0.1f;
		const float lfo_pitch = p(LFO_PITCH) * 0.1f + mod_wheel * 0.5f;
		const float lfo_filt = p(LFO_FILTER) * 0.1f * 3.0f;
		const float lfo_pwm = p(LFO_PWM) * 0.1f * 0.4f;
		const float spread = p(SPREAD) * 0.1f;
		const float bend_st = bend * p(BEND_RANGE);
		const float vol = p(VOLUME) * 0.1f * 0.5f;
		const float pw = p(O1_PW);
		const int lfo_shape = pi_(LFO_SHAPE);
		const float lfo_rate = p(LFO_RATE);
		const bool ch_on = p(CH_ON) > 0.5f;
		const float ch_rate = p(CH_RATE), ch_depth = p(CH_DEPTH) * 0.1f, ch_mix = p(CH_MIX) * 0.1f;
		const float rv_size = p(RV_SIZE) * 0.1f, rv_decay = p(RV_DECAY), rv_damp = p(RV_DAMP) * 0.1f, rv_mix = p(RV_MIX) * 0.1f;

		// Pans per voice (equal power), computed once per block.
		float gl[NV], gr[NV];
		bool any = false;
		for (int k = 0; k < NV; k++) {
			const float a = (voices[k].pan * spread + 1.0f) * 0.25f * PI;
			gl[k] = std::cos(a);
			gr[k] = std::sin(a);
			Voice &v = voices[k];
			v.drift += (v.drift_target - v.drift) * 0.002f * (float)n / 64.0f;
			if (rng.uni() < 0.002f * n / 64.0f) v.drift_target = rng.white();
			any = any || v.aenv.active();
		}

		for (int i = 0; i < n; i++) {
			const float lf = lfo.process(lfo_rate, sr, lfo_shape);
			float sl = 0.0f, srr = 0.0f;
			if (any) {
				for (int k = 0; k < NV; k++) {
					Voice &v = voices[k];
					if (!v.aenv.active()) continue;
					const float pitch = v.note + bend_st + lf * lfo_pitch + v.drift * drift_amt;
					const float dt1 = midi_to_hz(pitch) / sr;
					const float dt2 = midi_to_hz(pitch + o2_off) / sr;
					const float x = v.o1.process(dt1, w1, pw + lf * lfo_pwm) * lv1 + v.o2.process(dt2, w2, pw - lf * lfo_pwm) * lv2 + rng.white() * lvn;
					const float fe = v.fenv.process();
					const float coct = cut_base + fe * env_oct + key * (v.note - 60.0f) / 12.0f + fvel * v.vel + lf * lfo_filt;
					const float y = v.filt.process(x, std::exp2(clampf(coct, 4.0f, 14.2f)), res, mode);
					const float amp = v.aenv.process() * (1.0f - avel * (1.0f - v.vel));
					const float s = y * amp;
					sl += s * gl[k];
					srr += s * gr[k];
				}
			}
			sl = dc_l.process(sl * vol);
			srr = dc_r.process(srr * vol);
			if (ch_on) chorus.process(sl, srr, ch_rate, ch_depth, ch_mix);
			if (rv_mix > 0.001f) reverb.process(sl, srr, rv_size, rv_decay, rv_damp, 0.015f, rv_mix);
			l[i] += sl;
			r[i] += srr;
		}
	}
};

Instrument *make_lumen() { return new Lumen(); }

} // namespace jam
