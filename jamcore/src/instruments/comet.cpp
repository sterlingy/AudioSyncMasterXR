// Comet: two-oscillator monophonic lead with hard sync, sub, multimode filter,
// vibrato, portamento, drive and a tempo-synced ping-pong delay.
#include "dsp/env.h"
#include "dsp/filters.h"
#include "dsp/fx.h"
#include "dsp/osc.h"
#include "engine/instrument.h"
#include "mono_voice.h"

namespace jam {

static const std::vector<std::string> LEAD_WAVES = { "Saw", "Square", "Pulse", "Triangle", "Sine" };
static int lead_wave(int w) {
	static const int map[] = { WAVE_SAW, WAVE_SQUARE, WAVE_PULSE, WAVE_TRIANGLE, WAVE_SINE };
	return map[w < 0 ? 0 : (w > 4 ? 4 : w)];
}

// Tempo divisions in beats (quarter notes).
static const std::vector<std::string> DIVISIONS = { "1/2", "1/4", "1/4.", "1/4T", "1/8", "1/8.", "1/8T", "1/16", "1/16T" };
static float division_beats(int d) {
	static const float b[] = { 2.0f, 1.0f, 1.5f, 2.0f / 3.0f, 0.5f, 0.75f, 1.0f / 3.0f, 0.25f, 1.0f / 6.0f };
	return b[d < 0 ? 0 : (d > 8 ? 8 : d)];
}

class Comet : public Instrument {
	enum P {
		O1_WAVE, O1_PW, O1_LEVEL,
		O2_WAVE, O2_SEMI, O2_FINE, O2_PW, O2_LEVEL, O2_SYNC,
		SUB_LEVEL, NOISE_LEVEL,
		F_MODE, F_CUTOFF, F_RES, F_ENV, F_KEY, F_VEL, F_DRIVE,
		FE_A, FE_D, FE_S, FE_R,
		AE_A, AE_D, AE_S, AE_R, AE_VEL,
		VIB_RATE, VIB_DEPTH, VIB_DELAY, VIB_WHEEL,
		GLIDE, GLIDE_MODE, LEGATO, BEND_RANGE,
		DLY_ON, DLY_DIV, DLY_FB, DLY_TONE, DLY_MIX, DLY_PINGPONG,
		VOLUME,
		COUNT
	};
	Osc o1, o2, sub;
	MultiFilter filt;
	Adsr fenv, aenv;
	Glide glide;
	MonoNoteStack notes;
	StereoDelay delay;
	Rng rng;
	DcBlocker dc;
	Smoother cut_s;
	float velocity = 1.0f;
	float vib_phase = 0.0f;
	float vib_time = 0.0f;
	bool sliding = false;

public:
	Comet() {
		info.resize(COUNT);
		info[O1_WAVE] = pe("osc1.wave", "Waveform", "Oscillator 1", LEAD_WAVES, 0);
		info[O1_PW] = pf("osc1.pw", "Pulse Width", "Oscillator 1", 0.05f, 0.95f, 0.5f);
		info[O1_LEVEL] = pf("osc1.level", "Level", "Oscillator 1", 0, 10, 8);
		info[O2_WAVE] = pe("osc2.wave", "Waveform", "Oscillator 2", LEAD_WAVES, 0);
		info[O2_SEMI] = pi("osc2.semi", "Semitones", "Oscillator 2", -24, 24, 7, "st");
		info[O2_FINE] = pf("osc2.fine", "Fine", "Oscillator 2", -50, 50, 6, "ct");
		info[O2_PW] = pf("osc2.pw", "Pulse Width", "Oscillator 2", 0.05f, 0.95f, 0.5f);
		info[O2_LEVEL] = pf("osc2.level", "Level", "Oscillator 2", 0, 10, 5);
		info[O2_SYNC] = pb("osc2.sync", "Hard Sync to Osc 1", "Oscillator 2", false);
		info[SUB_LEVEL] = pf("mix.sub", "Sub Osc (-1 oct)", "Mixer", 0, 10, 0);
		info[NOISE_LEVEL] = pf("mix.noise", "Noise", "Mixer", 0, 10, 0);
		info[F_MODE] = pe("filter.mode", "Mode", "Filter", { "LP 24", "LP 12", "Band Pass", "High Pass" }, 0);
		info[F_CUTOFF] = pf("filter.cutoff", "Cutoff", "Filter", 30, 18000, 2200, "Hz", true);
		info[F_RES] = pf("filter.resonance", "Resonance", "Filter", 0, 10, 3);
		info[F_ENV] = pf("filter.env", "Envelope Amount", "Filter", -10, 10, 4);
		info[F_KEY] = pf("filter.keytrack", "Key Tracking", "Filter", 0, 10, 5);
		info[F_VEL] = pf("filter.velocity", "Velocity", "Filter", 0, 10, 3);
		info[F_DRIVE] = pf("filter.drive", "Drive", "Filter", 0, 10, 2);
		info[FE_A] = pf("fenv.attack", "Attack", "Filter Envelope", 0.001f, 8, 0.003f, "s", true);
		info[FE_D] = pf("fenv.decay", "Decay", "Filter Envelope", 0.005f, 8, 0.4f, "s", true);
		info[FE_S] = pf("fenv.sustain", "Sustain", "Filter Envelope", 0, 10, 3);
		info[FE_R] = pf("fenv.release", "Release", "Filter Envelope", 0.005f, 8, 0.3f, "s", true);
		info[AE_A] = pf("aenv.attack", "Attack", "Amp Envelope", 0.001f, 8, 0.004f, "s", true);
		info[AE_D] = pf("aenv.decay", "Decay", "Amp Envelope", 0.005f, 8, 0.5f, "s", true);
		info[AE_S] = pf("aenv.sustain", "Sustain", "Amp Envelope", 0, 10, 8);
		info[AE_R] = pf("aenv.release", "Release", "Amp Envelope", 0.005f, 8, 0.25f, "s", true);
		info[AE_VEL] = pf("aenv.velocity", "Velocity", "Amp Envelope", 0, 10, 4);
		info[VIB_RATE] = pf("vibrato.rate", "Rate", "Vibrato", 0.1f, 12, 5.5f, "Hz", true);
		info[VIB_DEPTH] = pf("vibrato.depth", "Depth", "Vibrato", 0, 10, 0, "");
		info[VIB_DELAY] = pf("vibrato.delay", "Delay", "Vibrato", 0, 3, 0.4f, "s");
		info[VIB_WHEEL] = pf("vibrato.wheel", "Mod Wheel Depth", "Vibrato", 0, 10, 5);
		info[GLIDE] = pf("perf.glide", "Portamento", "Performance", 0, 2, 0.06f, "s");
		info[GLIDE_MODE] = pe("perf.glide_mode", "Portamento Mode", "Performance", { "Off", "Always", "Legato" }, 2);
		info[LEGATO] = pb("perf.legato", "Legato (Single Trigger)", "Performance", true);
		info[BEND_RANGE] = pi("perf.bend_range", "Bend Range", "Performance", 1, 12, 2, "st");
		info[DLY_ON] = pb("delay.on", "Delay", "Delay", true);
		info[DLY_DIV] = pe("delay.division", "Time", "Delay", DIVISIONS, 5);
		info[DLY_FB] = pf("delay.feedback", "Feedback", "Delay", 0, 9.5f, 4);
		info[DLY_TONE] = pf("delay.tone", "Tone", "Delay", 500, 16000, 4500, "Hz", true);
		info[DLY_MIX] = pf("delay.mix", "Mix", "Delay", 0, 10, 2.5f);
		info[DLY_PINGPONG] = pb("delay.pingpong", "Ping-Pong", "Delay", true);
		info[VOLUME] = pf("out.volume", "Volume", "Output", 0, 10, 7);
		finish_params();
	}
	const char *type_name() const override { return "Comet"; }

	void prepare(float p_sr) override {
		sr = p_sr;
		filt.init(sr);
		fenv.init(sr);
		aenv.init(sr);
		delay.init(sr, 2.5f);
		dc.init(sr);
		cut_s.init(sr, 5.0f);
		cut_s.reset(std::log2(p(F_CUTOFF)));
		update();
	}
	void update() {
		fenv.set(p(FE_A), p(FE_D), p(FE_S) * 0.1f, p(FE_R));
		aenv.set(p(AE_A), p(AE_D), p(AE_S) * 0.1f, p(AE_R));
		glide.set(p(GLIDE), sr);
	}
	void param_changed(int i) override {
		if ((i >= FE_A && i <= AE_R) || i == GLIDE) update();
	}

	void note_on(int note, float vel) override {
		const bool was_empty = !notes.any();
		notes.press(note);
		const int mode = pi_(GLIDE_MODE);
		sliding = mode == 1 || (mode == 2 && !was_empty);
		if (!sliding) glide.jump((float)notes.current());
		if (was_empty || p(LEGATO) < 0.5f) {
			velocity = vel;
			fenv.gate_on(true);
			aenv.gate_on(true);
			if (was_empty) vib_time = 0.0f;
		}
	}
	void note_off(int note) override {
		notes.release(note);
		if (!notes.any() && !sustain_pedal) {
			fenv.gate_off();
			aenv.gate_off();
		}
	}
	void set_sustain(bool on) override {
		sustain_pedal = on;
		if (!on && !notes.any()) {
			fenv.gate_off();
			aenv.gate_off();
		}
	}
	void all_notes_off() override {
		notes.clear();
		fenv.gate_off();
		aenv.gate_off();
	}

	void render(float *l, float *r, int n) override {
		const bool delay_on = p(DLY_ON) > 0.5f;
		if (!aenv.active() && !notes.any() && !delay_on) return;
		const float target = (float)notes.current();
		const float bend_st = bend * p(BEND_RANGE);
		const int w1 = lead_wave(pi_(O1_WAVE)), w2 = lead_wave(pi_(O2_WAVE));
		const float pw1 = p(O1_PW), pw2 = p(O2_PW);
		const float lv1 = p(O1_LEVEL) * 0.1f, lv2 = p(O2_LEVEL) * 0.1f, lvs = p(SUB_LEVEL) * 0.1f, lvn = p(NOISE_LEVEL) * 0.1f;
		const float o2_off = (float)pi_(O2_SEMI) + p(O2_FINE) * 0.01f;
		const bool sync = p(O2_SYNC) > 0.5f;
		const int mode = pi_(F_MODE);
		const float res = p(F_RES) * 0.1f;
		const float env_oct = p(F_ENV) * 0.5f; // +-5 octaves
		const float key = p(F_KEY) * 0.1f;
		const float vel_oct = p(F_VEL) * 0.1f * 2.0f * velocity;
		const float drv = p(F_DRIVE) * 0.1f;
		const float vel_amp = 1.0f - p(AE_VEL) * 0.1f * (1.0f - velocity);
		const float vib_rate = p(VIB_RATE);
		const float vib_depth = (p(VIB_DEPTH) * 0.1f + mod_wheel * p(VIB_WHEEL) * 0.1f) * 1.0f; // semitones
		const float vib_delay = p(VIB_DELAY);
		const float vol = p(VOLUME) * 0.1f;
		const float cut_base = std::log2(p(F_CUTOFF));
		const float dly_time = 60.0f / tempo * division_beats(pi_(DLY_DIV));
		const float dly_fb = p(DLY_FB) * 0.1f;
		const float dly_tone = p(DLY_TONE);
		const float dly_mix = delay_on ? p(DLY_MIX) * 0.1f : 0.0f;
		const bool pingpong = p(DLY_PINGPONG) > 0.5f;
		const bool voice_on = aenv.active() || notes.any();

		for (int i = 0; i < n; i++) {
			float out = 0.0f;
			if (voice_on) {
				const float note = (sliding ? glide.process(target) : (glide.jump(target), target)) + bend_st;
				vib_time += 1.0f / sr;
				const float vib_amt = vib_delay <= 0.0f ? 1.0f : clampf(vib_time / vib_delay, 0.0f, 1.0f);
				vib_phase += vib_rate / sr;
				if (vib_phase >= 1.0f) vib_phase -= 1.0f;
				const float pitch = note + std::sin(TWO_PI * vib_phase) * vib_depth * vib_amt;
				const float dt1 = midi_to_hz(pitch) / sr;
				const float dt2 = midi_to_hz(pitch + o2_off) / sr;
				const float s1 = o1.process(dt1, w1, pw1);
				if (sync && o1.wrapped) o2.sync_to(o1.wrap_frac, dt2);
				const float s2 = o2.process(dt2, w2, pw2);
				const float ss = sub.process(dt1 * 0.5f, WAVE_SQUARE);
				float x = s1 * lv1 + s2 * lv2 + ss * lvs + rng.white() * lvn;
				x = drive(x * 0.6f, drv);
				const float fe = fenv.process();
				const float coct = cut_s.process(cut_base) + fe * env_oct + key * (note - 60.0f) / 12.0f + vel_oct;
				const float y = filt.process(x, std::exp2(clampf(coct, 4.0f, 14.2f)), res, mode);
				out = dc.process(y * aenv.process() * vel_amp * vol * 0.8f);
			}
			float ol = out, or_ = out;
			if (delay_on) delay.process(ol, or_, dly_time, dly_fb, dly_tone, dly_mix, pingpong);
			l[i] += ol;
			r[i] += or_;
		}
	}
};

Instrument *make_comet() { return new Comet(); }

} // namespace jam
