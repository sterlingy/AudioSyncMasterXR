// Undertow: three-oscillator monophonic bass synth in the style of the classic
// 1970s portable analog (three VCOs, mixer, 24 dB ladder, two contours).
#include "dsp/env.h"
#include "dsp/filters.h"
#include "dsp/osc.h"
#include "engine/instrument.h"
#include "mono_voice.h"

namespace jam {

class Undertow : public Instrument {
	enum P {
		TUNE, GLIDE, MOD_MIX, MOD_AMOUNT, OSC_MOD, FILTER_MOD, OSC3_CTRL, BEND_RANGE, PRIORITY, LEGATO,
		O1_RANGE, O1_WAVE,
		O2_RANGE, O2_FREQ, O2_WAVE,
		O3_RANGE, O3_FREQ, O3_WAVE,
		M_O1_ON, M_O1, M_O2_ON, M_O2, M_O3_ON, M_O3, M_EXT_ON, M_EXT, M_NOISE_ON, M_NOISE, M_NOISE_COLOR,
		F_CUTOFF, F_EMPHASIS, F_CONTOUR, F_KEYTRACK, F_VEL,
		FE_ATTACK, FE_DECAY, FE_SUSTAIN,
		LE_ATTACK, LE_DECAY, LE_SUSTAIN, LE_VEL,
		DECAY_SW, VOLUME,
		COUNT
	};

	Osc osc[3];
	LadderFilter ladder;
	Adsr fenv, lenv;
	Glide glide;
	MonoNoteStack notes;
	Rng rng;
	PinkNoise pink;
	DcBlocker dc;
	Smoother cutoff_s, vol_s;
	float last_out = 0.0f;
	float velocity = 1.0f;

public:
	Undertow() {
		const std::vector<std::string> ranges = { "LO", "32'", "16'", "8'", "4'", "2'" };
		const std::vector<std::string> waves = { "Triangle", "Shark", "Saw", "Reverse Saw", "Square", "Wide Pulse", "Narrow Pulse" };
		info.resize(COUNT);
		info[TUNE] = pf("ctrl.tune", "Tune", "Controllers", -100, 100, 0, "ct");
		info[GLIDE] = pf("ctrl.glide", "Glide", "Controllers", 0, 5, 0, "s");
		info[MOD_MIX] = pf("ctrl.mod_mix", "Mod Mix (Osc 3 / Noise)", "Controllers", 0, 10, 0);
		info[MOD_AMOUNT] = pf("ctrl.mod_amount", "Mod Amount", "Controllers", 0, 10, 0);
		info[OSC_MOD] = pb("ctrl.osc_mod", "Osc Modulation", "Controllers", false);
		info[FILTER_MOD] = pb("ctrl.filter_mod", "Filter Modulation", "Controllers", false);
		info[OSC3_CTRL] = pb("ctrl.osc3_kbd", "Osc 3 Keyboard Control", "Controllers", true);
		info[BEND_RANGE] = pi("ctrl.bend_range", "Bend Range", "Controllers", 1, 12, 2, "st");
		info[PRIORITY] = pe("ctrl.priority", "Note Priority", "Controllers", { "Low", "Last", "High" }, 1);
		info[LEGATO] = pb("ctrl.legato", "Legato (Single Trigger)", "Controllers", false);

		info[O1_RANGE] = pe("osc1.range", "Range", "Oscillator 1", ranges, 2);
		info[O1_WAVE] = pe("osc1.wave", "Waveform", "Oscillator 1", waves, 2);
		info[O2_RANGE] = pe("osc2.range", "Range", "Oscillator 2", ranges, 2);
		info[O2_FREQ] = pf("osc2.freq", "Frequency", "Oscillator 2", -7, 7, 0.08f, "st");
		info[O2_WAVE] = pe("osc2.wave", "Waveform", "Oscillator 2", waves, 2);
		info[O3_RANGE] = pe("osc3.range", "Range", "Oscillator 3", ranges, 1);
		info[O3_FREQ] = pf("osc3.freq", "Frequency", "Oscillator 3", -7, 7, -0.06f, "st");
		info[O3_WAVE] = pe("osc3.wave", "Waveform", "Oscillator 3", waves, 4);

		info[M_O1_ON] = pb("mix.osc1_on", "Osc 1", "Mixer", true);
		info[M_O1] = pf("mix.osc1", "Osc 1 Level", "Mixer", 0, 10, 8);
		info[M_O2_ON] = pb("mix.osc2_on", "Osc 2", "Mixer", true);
		info[M_O2] = pf("mix.osc2", "Osc 2 Level", "Mixer", 0, 10, 6);
		info[M_O3_ON] = pb("mix.osc3_on", "Osc 3", "Mixer", true);
		info[M_O3] = pf("mix.osc3", "Osc 3 Level", "Mixer", 0, 10, 4);
		info[M_EXT_ON] = pb("mix.ext_on", "Feedback", "Mixer", false);
		info[M_EXT] = pf("mix.ext", "Feedback Level", "Mixer", 0, 10, 3);
		info[M_NOISE_ON] = pb("mix.noise_on", "Noise", "Mixer", false);
		info[M_NOISE] = pf("mix.noise", "Noise Level", "Mixer", 0, 10, 3);
		info[M_NOISE_COLOR] = pe("mix.noise_color", "Noise Color", "Mixer", { "White", "Pink" }, 0);

		info[F_CUTOFF] = pf("filter.cutoff", "Cutoff", "Filter", 20, 18000, 900, "Hz", true);
		info[F_EMPHASIS] = pf("filter.emphasis", "Emphasis", "Filter", 0, 10, 2.5f);
		info[F_CONTOUR] = pf("filter.contour", "Amount of Contour", "Filter", 0, 10, 5);
		info[F_KEYTRACK] = pe("filter.keytrack", "Keyboard Control", "Filter", { "Off", "1/3", "2/3", "Full" }, 1);
		info[F_VEL] = pf("filter.velocity", "Velocity to Cutoff", "Filter", 0, 10, 2);

		info[FE_ATTACK] = pf("fenv.attack", "Attack", "Filter Contour", 0.001f, 10, 0.004f, "s", true);
		info[FE_DECAY] = pf("fenv.decay", "Decay", "Filter Contour", 0.004f, 10, 0.35f, "s", true);
		info[FE_SUSTAIN] = pf("fenv.sustain", "Sustain", "Filter Contour", 0, 10, 2);

		info[LE_ATTACK] = pf("lenv.attack", "Attack", "Loudness Contour", 0.001f, 10, 0.002f, "s", true);
		info[LE_DECAY] = pf("lenv.decay", "Decay", "Loudness Contour", 0.004f, 10, 0.6f, "s", true);
		info[LE_SUSTAIN] = pf("lenv.sustain", "Sustain", "Loudness Contour", 0, 10, 8);
		info[LE_VEL] = pf("lenv.velocity", "Velocity to Loudness", "Loudness Contour", 0, 10, 3);

		info[DECAY_SW] = pb("out.decay_switch", "Decay (Release)", "Output", true);
		info[VOLUME] = pf("out.volume", "Volume", "Output", 0, 10, 7);
		finish_params();
	}

	const char *type_name() const override { return "Undertow"; }

	void prepare(float p_sr) override {
		sr = p_sr;
		ladder.init(sr);
		fenv.init(sr);
		lenv.init(sr);
		dc.init(sr);
		cutoff_s.init(sr, 5.0f);
		cutoff_s.reset(std::log2(p(F_CUTOFF)));
		vol_s.init(sr, 10.0f);
		vol_s.reset(p(VOLUME) * 0.1f);
		rng.seed(1234);
		update_envs();
		glide.set(p(GLIDE), sr);
	}

	void update_envs() {
		const float rel_f = p(DECAY_SW) > 0.5f ? p(FE_DECAY) : 0.006f;
		const float rel_l = p(DECAY_SW) > 0.5f ? p(LE_DECAY) : 0.006f;
		fenv.set(p(FE_ATTACK), p(FE_DECAY), p(FE_SUSTAIN) * 0.1f, rel_f);
		lenv.set(p(LE_ATTACK), p(LE_DECAY), p(LE_SUSTAIN) * 0.1f, rel_l);
	}

	void param_changed(int i) override {
		if ((i >= FE_ATTACK && i <= LE_SUSTAIN) || i == DECAY_SW) update_envs();
		if (i == GLIDE) glide.set(p(GLIDE), sr);
		if (i == PRIORITY) notes.priority = pi_(PRIORITY);
	}

	void note_on(int note, float vel) override {
		const bool was_empty = !notes.any();
		notes.priority = pi_(PRIORITY);
		notes.press(note);
		if (was_empty) {
			velocity = vel;
			if (p(GLIDE) <= 0.0f) glide.jump((float)notes.current());
			fenv.gate_on(true);
			lenv.gate_on(true);
		} else if (p(LEGATO) < 0.5f) {
			velocity = vel;
			fenv.gate_on(true);
			lenv.gate_on(true);
		}
	}

	void note_off(int note) override {
		notes.release(note);
		if (!notes.any() && !sustain_pedal) {
			fenv.gate_off();
			lenv.gate_off();
		}
	}

	void set_sustain(bool on) override {
		sustain_pedal = on;
		if (!on && !notes.any()) {
			fenv.gate_off();
			lenv.gate_off();
		}
	}

	void all_notes_off() override {
		notes.clear();
		fenv.gate_off();
		lenv.gate_off();
	}

	static float range_octaves(int r) {
		// LO, 32', 16', 8', 4', 2'  (8' = concert pitch)
		static const float oct[] = { -7.0f, -2.0f, -1.0f, 0.0f, 1.0f, 2.0f };
		return oct[r < 0 ? 0 : (r > 5 ? 5 : r)];
	}
	static int wave_of(int w) {
		static const int map[] = { WAVE_TRIANGLE, WAVE_SHARK, WAVE_SAW, WAVE_REVERSE_SAW, WAVE_SQUARE, WAVE_PULSE_WIDE, WAVE_PULSE_NARROW };
		return map[w < 0 ? 0 : (w > 6 ? 6 : w)];
	}

	void render(float *l, float *r, int n) override {
		if (!lenv.active() && !notes.any()) {
			last_out = 0.0f;
			return;
		}
		const float tune_st = p(TUNE) * 0.01f;
		const float bend_st = bend * p(BEND_RANGE);
		const float mod_depth = clampf(mod_wheel + p(MOD_AMOUNT) * 0.1f, 0.0f, 1.0f);
		const float mod_mix = p(MOD_MIX) * 0.1f;
		const bool osc_mod = p(OSC_MOD) > 0.5f, filt_mod = p(FILTER_MOD) > 0.5f;
		const float lv1 = p(M_O1_ON) > 0.5f ? p(M_O1) * 0.1f : 0.0f;
		const float lv2 = p(M_O2_ON) > 0.5f ? p(M_O2) * 0.1f : 0.0f;
		const float lv3 = p(M_O3_ON) > 0.5f ? p(M_O3) * 0.1f : 0.0f;
		const float lvx = p(M_EXT_ON) > 0.5f ? p(M_EXT) * 0.1f : 0.0f;
		const float lvn = p(M_NOISE_ON) > 0.5f ? p(M_NOISE) * 0.1f : 0.0f;
		const bool pink_noise = pi_(M_NOISE_COLOR) == 1;
		// Driving the mixer hard overdrives the filter input, like the original.
		const float mix_sum = lv1 + lv2 + lv3 + lvx + lvn;
		const float drive = 1.0f + std::max(0.0f, mix_sum - 1.0f) * 1.2f;
		const float keytrack = pi_(F_KEYTRACK) / 3.0f;
		const float contour = p(F_CONTOUR) * 0.1f * 5.0f; // up to 5 octaves
		const float res = p(F_EMPHASIS) * 0.1f;
		const float vel_cut = p(F_VEL) * 0.1f * velocity * 2.0f; // up to 2 octaves
		const float vel_amp = 1.0f - p(LE_VEL) * 0.1f * (1.0f - velocity);
		const float vol_target = p(VOLUME) * 0.1f;
		const float r1 = range_octaves(pi_(O1_RANGE)), r2 = range_octaves(pi_(O2_RANGE)), r3 = range_octaves(pi_(O3_RANGE));
		const int w1 = wave_of(pi_(O1_WAVE)), w2 = wave_of(pi_(O2_WAVE)), w3 = wave_of(pi_(O3_WAVE));
		const float f2 = p(O2_FREQ), f3 = p(O3_FREQ);
		const bool o3_kbd = p(OSC3_CTRL) > 0.5f;
		const float cutoff_oct_base = std::log2(p(F_CUTOFF));
		const float target_note = (float)notes.current();

		for (int i = 0; i < n; i++) {
			const float note = glide.process(target_note) + tune_st + bend_st;
			// Osc 3 runs first: it can be a modulation source.
			const float n3 = (o3_kbd ? note : 60.0f + tune_st) + f3 + r3 * 12.0f;
			const float s3 = osc[2].process(midi_to_hz(n3) / sr, w3);
			const float wn = rng.white();
			const float noise = pink_noise ? pink.process(wn) * 1.4f : wn;
			const float mod = lerpf(s3, noise, mod_mix) * mod_depth;

			const float om = osc_mod ? mod * 12.0f : 0.0f;
			const float s1 = osc[0].process(midi_to_hz(note + r1 * 12.0f + om) / sr, w1);
			const float s2 = osc[1].process(midi_to_hz(note + f2 + r2 * 12.0f + om) / sr, w2);

			float x = s1 * lv1 + s2 * lv2 + s3 * lv3 + noise * lvn + last_out * lvx * 3.0f;

			const float fe = fenv.process();
			float coct = cutoff_s.process(cutoff_oct_base) + fe * contour + keytrack * (note - 60.0f) / 12.0f + vel_cut;
			if (filt_mod) coct += mod * 4.0f;
			const float y = ladder.process(x * 0.5f, std::exp2(coct), res, drive);
			const float le = lenv.process();
			const float out = dc.process(y * le * vel_amp * vol_s.process(vol_target)) * 1.4f;
			last_out = out;
			l[i] += out;
			r[i] += out;
		}
	}
};

Instrument *make_undertow() { return new Undertow(); }

} // namespace jam
