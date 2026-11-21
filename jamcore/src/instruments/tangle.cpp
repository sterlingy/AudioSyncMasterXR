#include "tangle.h"
#include "dsp/env.h"
#include "dsp/filters.h"
#include "dsp/fx.h"
#include "dsp/osc.h"

namespace jam {

// Signal conventions: audio +-1, envelopes/gates 0..1, LFOs +-1,
// pitch in volts per octave with 0 V = C4 (261.63 Hz).
static constexpr float C4_HZ = 261.6256f;
static inline bool high(float v) { return v > 0.5f; }

static const std::vector<std::string> SYNC_DIVS = { "Free", "4 Bars", "2 Bars", "1 Bar", "1/2", "1/4", "1/8", "1/16", "1/4T", "1/8T" };
static double sync_beats(int i) {
	static const double b[] = { 0, 16, 8, 4, 2, 1, 0.5, 0.25, 2.0 / 3.0, 1.0 / 3.0 };
	return b[i < 0 ? 0 : (i > 9 ? 9 : i)];
}

// ---------------------------------------------------------------- modules

// 1. MIDI -> CV
class MidiCvModule : public Module {
	Glide glide;
	float gate_low = 0; // samples left of forced-low gate on retrigger
public:
	enum { O_PITCH, O_GATE, O_VEL, O_MOD, O_PRESS, O_TRIG };
	enum { P_GLIDE, P_BEND, P_OCT };
	void prepare(float p_sr) override {
		sr = p_sr;
		glide.set(p[P_GLIDE], sr);
		glide.jump(0.0f);
	}
	void param_changed(int i) override {
		if (i == P_GLIDE) glide.set(p[P_GLIDE], sr);
	}
	void process(TangleCtx &c) override {
		const float bend_v = c.bend * p[P_BEND] / 12.0f;
		const float target = c.pitch + p[P_OCT];
		for (int i = 0; i < TB; i++) {
			const bool retrig = i == c.retrig_at;
			if (retrig) gate_low = 2;
			out[O_PITCH][i] = glide.process(target) + bend_v;
			float g = c.gate ? 1.0f : 0.0f;
			if (gate_low > 0) {
				g = 0.0f;
				gate_low--;
			}
			out[O_GATE][i] = g;
			out[O_VEL][i] = c.velocity;
			out[O_MOD][i] = c.mod;
			out[O_PRESS][i] = c.pressure;
			out[O_TRIG][i] = retrig ? 1.0f : 0.0f;
		}
	}
};

// 2. Clock (follows the session tempo and beat position)
class ClockModule : public Module {
public:
	enum { O_16, O_8, O_4, O_BAR, O_8T, O_RESET };
	enum { P_SWING, P_WIDTH, P_RUN };
	void process(TangleCtx &c) override {
		const bool run = p[P_RUN] > 0.5f;
		const float swing = p[P_SWING] * 0.01f; // 50..75 %
		const float width = p[P_WIDTH];
		double beat = c.beat;
		for (int i = 0; i < TB; i++) {
			if (!run) {
				for (int o = 0; o <= O_RESET; o++) out[o][i] = 0.0f;
				continue;
			}
			auto pulse = [&](double period, bool swung) {
				double ph = beat / period;
				ph -= std::floor(ph);
				if (swung) {
					// Pairs of steps: the second one starts late.
					double pair = beat / (period * 2.0);
					pair -= std::floor(pair);
					const double start = pair < swing ? 0.0 : swing;
					const double len = (pair < swing ? swing : 1.0 - swing);
					ph = (pair - start) / len;
				}
				return ph < width ? 1.0f : 0.0f;
			};
			out[O_16][i] = pulse(0.25, swing > 0.505f);
			out[O_8][i] = pulse(0.5, swing > 0.505f);
			out[O_4][i] = pulse(1.0, false);
			out[O_BAR][i] = pulse(4.0, false);
			out[O_8T][i] = pulse(1.0 / 3.0, false);
			double bar = beat / 4.0;
			bar -= std::floor(bar);
			out[O_RESET][i] = bar * 4.0 < 0.01 ? 1.0f : 0.0f;
			beat += c.beats_per_sample;
		}
	}
};

// 3. VCO
class VcoModule : public Module {
	float phase = 0.0f;
	float last_sync = 0.0f;
public:
	enum { I_PITCH, I_FM, I_PWM, I_SYNC };
	enum { O_SINE, O_TRI, O_SAW, O_PULSE };
	enum { P_OCT, P_SEMI, P_FINE, P_FM, P_PW, P_PWM };
	void process(TangleCtx &c) override {
		const float base_v = p[P_OCT] + p[P_SEMI] / 12.0f + p[P_FINE] / 1200.0f;
		const float fm = p[P_FM];
		for (int i = 0; i < TB; i++) {
			const float v = base_v + in[I_PITCH][i] + in[I_FM][i] * fm;
			const float dt = clampf(C4_HZ * std::exp2(v) / sr, 0.0f, 0.45f);
			const float pw = clampf(p[P_PW] + in[I_PWM][i] * p[P_PWM] * 0.45f, 0.03f, 0.97f);
			const float s = in[I_SYNC][i];
			if (s > 0.0f && last_sync <= 0.0f) phase = 0.0f;
			last_sync = s;
			const float t = phase;
			out[O_SINE][i] = std::sin(TWO_PI * t);
			out[O_TRI][i] = -(1.0f - 4.0f * std::fabs(t - 0.5f));
			out[O_SAW][i] = 2.0f * t - 1.0f - poly_blep(t, dt);
			float pu = t < pw ? 1.0f : -1.0f;
			pu += poly_blep(t, dt);
			float t2 = t - pw;
			if (t2 < 0.0f) t2 += 1.0f;
			pu -= poly_blep(t2, dt);
			out[O_PULSE][i] = pu;
			phase += dt;
			if (phase >= 1.0f) phase -= 1.0f;
		}
	}
};

// 4. Noise / Sample & Hold
class NoiseShModule : public Module {
	Rng rng;
	PinkNoise pink;
	float held = 0.0f, smooth = 0.0f, last_trig = 0.0f;
public:
	enum { I_SIGNAL, I_TRIG };
	enum { O_WHITE, O_PINK, O_SH };
	enum { P_GLIDE, P_LEVEL };
	void prepare(float p_sr) override {
		sr = p_sr;
		rng.seed((uint32_t)(size_t)this);
	}
	void process(TangleCtx &) override {
		const float k = p[P_GLIDE] <= 0.0005f ? 0.0f : std::exp(-4.6f / (p[P_GLIDE] * sr));
		const float lvl = p[P_LEVEL];
		for (int i = 0; i < TB; i++) {
			const float w = rng.white();
			out[O_WHITE][i] = w * lvl;
			out[O_PINK][i] = pink.process(w) * 1.4f * lvl;
			const float t = in[I_TRIG][i];
			if (high(t) && !high(last_trig)) held = connected[I_SIGNAL] ? in[I_SIGNAL][i] : w;
			last_trig = t;
			smooth = held + k * (smooth - held);
			out[O_SH][i] = smooth;
		}
	}
};

// 5. VCF
class VcfModule : public Module {
	LadderFilter ladder;
	Svf svf;
public:
	enum { I_IN, I_CUTOFF, I_RES };
	enum { O_LP24, O_LP12, O_BP, O_HP };
	enum { P_CUTOFF, P_RES, P_CV, P_DRIVE };
	void prepare(float p_sr) override {
		sr = p_sr;
		ladder.init(sr);
		svf.init(sr);
	}
	void process(TangleCtx &) override {
		const float base = std::log2(p[P_CUTOFF]);
		const float cv = p[P_CV];
		const float drive = 1.0f + p[P_DRIVE] * 0.9f;
		for (int i = 0; i < TB; i++) {
			const float hz = std::exp2(clampf(base + in[I_CUTOFF][i] * cv, 3.0f, 14.3f));
			const float res = clampf(p[P_RES] + in[I_RES][i], 0.0f, 1.0f);
			const float x = in[I_IN][i];
			out[O_LP24][i] = ladder.process(x * 0.7f, hz, res, drive) * 1.4f;
			svf.process(x, hz, res);
			out[O_LP12][i] = svf.lp;
			out[O_BP][i] = svf.bp;
			out[O_HP][i] = svf.hp;
		}
	}
};

// 6. Dual VCA
class VcaModule : public Module {
public:
	enum { I_A, I_A_CV, I_B, I_B_CV };
	enum { O_A, O_B, O_MIX };
	enum { P_A, P_B, P_RESPONSE };
	void process(TangleCtx &) override {
		const bool expo = p[P_RESPONSE] > 0.5f;
		for (int i = 0; i < TB; i++) {
			float ga = clampf(p[P_A] + in[I_A_CV][i], 0.0f, 1.5f);
			float gb = clampf(p[P_B] + in[I_B_CV][i], 0.0f, 1.5f);
			if (expo) {
				ga = ga * ga * ga;
				gb = gb * gb * gb;
			}
			out[O_A][i] = in[I_A][i] * ga;
			out[O_B][i] = in[I_B][i] * gb;
			out[O_MIX][i] = out[O_A][i] + out[O_B][i];
		}
	}
};

// 7. ADSR
class AdsrModule : public Module {
	Adsr env;
	float last_gate = 0.0f, last_retrig = 0.0f;
public:
	enum { I_GATE, I_RETRIG };
	enum { O_ENV, O_INV };
	enum { P_A, P_D, P_S, P_R };
	void prepare(float p_sr) override {
		sr = p_sr;
		env.init(sr);
		param_changed(0);
	}
	void param_changed(int) override { env.set(p[P_A], p[P_D], p[P_S], p[P_R]); }
	void process(TangleCtx &) override {
		for (int i = 0; i < TB; i++) {
			const float g = in[I_GATE][i], rt = in[I_RETRIG][i];
			if (high(g) && !high(last_gate)) env.gate_on(true);
			else if (!high(g) && high(last_gate)) env.gate_off();
			if (high(rt) && !high(last_retrig) && high(g)) env.gate_on(true);
			last_gate = g;
			last_retrig = rt;
			const float v = env.process();
			out[O_ENV][i] = v;
			out[O_INV][i] = 1.0f - v;
		}
	}
};

// 8. LFO
class LfoModule : public Module {
	float phase = 0.0f;
	float held = 0.0f;
	float last_reset = 0.0f;
	float last_ph = 0.0f;
	Rng rng;
public:
	enum { I_RATE, I_RESET };
	enum { O_SINE, O_TRI, O_SAW, O_SQUARE, O_RANDOM };
	enum { P_RATE, P_SYNC, P_UNI };
	void process(TangleCtx &c) override {
		const int sync = (int)p[P_SYNC];
		const bool uni = p[P_UNI] > 0.5f;
		double beat = c.beat;
		for (int i = 0; i < TB; i++) {
			float ph;
			if (sync > 0) {
				double x = beat / sync_beats(sync);
				ph = (float)(x - std::floor(x));
				beat += c.beats_per_sample;
			} else {
				const float hz = p[P_RATE] * std::exp2(in[I_RATE][i]);
				phase += hz / sr;
				const float r = in[I_RESET][i];
				if (high(r) && !high(last_reset)) phase = 0.0f;
				last_reset = r;
				phase -= std::floor(phase);
				ph = phase;
			}
			if (ph < last_ph) held = rng.white(); // new random value each cycle
			last_ph = ph;
			float s = std::sin(TWO_PI * ph), t = 1.0f - 4.0f * std::fabs(ph - 0.5f), w = 2.0f * ph - 1.0f, q = ph < 0.5f ? 1.0f : -1.0f;
			float rd = held;
			if (uni) {
				s = 0.5f * (s + 1.0f);
				t = 0.5f * (t + 1.0f);
				w = 0.5f * (w + 1.0f);
				q = 0.5f * (q + 1.0f);
				rd = 0.5f * (rd + 1.0f);
			}
			out[O_SINE][i] = s;
			out[O_TRI][i] = t;
			out[O_SAW][i] = w;
			out[O_SQUARE][i] = q;
			out[O_RANDOM][i] = rd;
		}
	}
};

// 9. Step sequencer (16 steps, scale quantizer)
class SeqModule : public Module {
	int step = -1;
	float last_clock = 0.0f, last_reset = 0.0f;
	int samples_since_clock = 0;
	int clock_period = 6000;
	int gate_left = 0;
	float pitch_v = 0.0f;
public:
	enum { I_CLOCK, I_RESET };
	enum { O_PITCH, O_GATE, O_TRIG, O_EOC };
	enum { P_STEPS, P_LENGTH, P_SCALE, P_ROOT, P_OCT, P_NOTE0, P_GATE0 = P_NOTE0 + 16, P_COUNT = P_GATE0 + 16 };
	static int quantize(int degree, int scale) {
		static const int scales[7][8] = {
			{ 12, 0, 1, 2, 3, 4, 5, 6 }, // chromatic (special-cased)
			{ 7, 0, 2, 4, 5, 7, 9, 11 }, // major
			{ 7, 0, 2, 3, 5, 7, 8, 10 }, // minor
			{ 5, 0, 2, 4, 7, 9, 0, 0 }, // pentatonic major
			{ 5, 0, 3, 5, 7, 10, 0, 0 }, // pentatonic minor
			{ 7, 0, 2, 3, 5, 7, 9, 10 }, // dorian
			{ 6, 0, 3, 5, 6, 7, 10, 0 }, // blues
		};
		if (scale <= 0) return degree;
		const int *s = scales[scale > 6 ? 6 : scale];
		const int n = s[0];
		const int oct = degree >= 0 ? degree / n : -((-degree + n - 1) / n);
		const int idx = degree - oct * n;
		return oct * 12 + s[1 + idx];
	}
	void process(TangleCtx &) override {
		const int steps = (int)p[P_STEPS];
		for (int i = 0; i < TB; i++) {
			out[O_TRIG][i] = 0.0f;
			out[O_EOC][i] = 0.0f;
			const float rs = in[I_RESET][i];
			if (high(rs) && !high(last_reset)) step = -1;
			last_reset = rs;
			const float ck = in[I_CLOCK][i];
			samples_since_clock++;
			if (high(ck) && !high(last_clock)) {
				clock_period = std::max(16, samples_since_clock);
				samples_since_clock = 0;
				step = (step + 1) % std::max(1, steps);
				if (step == 0) out[O_EOC][i] = 1.0f;
				const int degree = (int)p[P_NOTE0 + step];
				const int semis = quantize(degree, (int)p[P_SCALE]) + (int)p[P_ROOT] + 12 * (int)p[P_OCT];
				pitch_v = semis / 12.0f;
				if (p[P_GATE0 + step] > 0.5f) {
					gate_left = std::max(1, (int)(clock_period * p[P_LENGTH]));
					out[O_TRIG][i] = 1.0f;
				}
			}
			last_clock = ck;
			out[O_PITCH][i] = pitch_v;
			out[O_GATE][i] = gate_left > 0 ? 1.0f : 0.0f;
			if (gate_left > 0) gate_left--;
		}
	}
};

// 10. Utility: 4-channel mixer, attenuverter + offset, slew limiter
class UtilityModule : public Module {
	float slew = 0.0f;
public:
	enum { I_A, I_B, I_C, I_D, I_X, I_SLEW };
	enum { O_MIX, O_X, O_SLEW, O_INV };
	enum { P_A, P_B, P_C, P_D, P_ATT, P_OFFSET, P_SLEW };
	void process(TangleCtx &) override {
		const float k = p[P_SLEW] <= 0.0005f ? 0.0f : std::exp(-4.6f / (p[P_SLEW] * sr));
		for (int i = 0; i < TB; i++) {
			out[O_MIX][i] = in[I_A][i] * p[P_A] + in[I_B][i] * p[P_B] + in[I_C][i] * p[P_C] + in[I_D][i] * p[P_D];
			out[O_X][i] = in[I_X][i] * p[P_ATT] + p[P_OFFSET];
			out[O_INV][i] = -in[I_X][i];
			slew = in[I_SLEW][i] + k * (slew - in[I_SLEW][i]);
			out[O_SLEW][i] = slew;
		}
	}
};

// 11. Delay
class DelayModule : public Module {
	DelayLine line;
	OnePole tone;
	Smoother time_s;
public:
	enum { I_IN, I_TIME };
	enum { O_OUT, O_WET };
	enum { P_SYNC, P_TIME, P_FB, P_TONE, P_MIX };
	void prepare(float p_sr) override {
		sr = p_sr;
		line.init((int)(sr * 4.2f));
		time_s.init(sr, 60.0f);
		time_s.reset(0.3f * sr);
	}
	void process(TangleCtx &c) override {
		const int sync = (int)p[P_SYNC];
		const float base = sync > 0 ? (float)(sync_beats(sync) * 60.0 / c.tempo) : p[P_TIME];
		tone.set(p[P_TONE], sr);
		for (int i = 0; i < TB; i++) {
			const float t = clampf(base * std::exp2(in[I_TIME][i]), 0.001f, 4.0f);
			const float d = time_s.process(t * sr);
			const float w = line.read(std::max(1.0f, d));
			line.write(undenormal(tone.lp(in[I_IN][i] + w * p[P_FB])));
			out[O_WET][i] = w;
			out[O_OUT][i] = in[I_IN][i] + w * p[P_MIX];
		}
	}
};

// 12. Reverb + Output
class OutputModule : public Module {
	Reverb reverb;
	DcBlocker dc_l, dc_r;
public:
	enum { I_L, I_R };
	enum { P_SIZE, P_DECAY, P_DAMP, P_MIX, P_LEVEL, P_PAN };
	void prepare(float p_sr) override {
		sr = p_sr;
		reverb.init(sr);
		dc_l.init(sr);
		dc_r.init(sr);
	}
	void process(TangleCtx &c) override {
		const bool stereo = connected[I_R];
		const float a = (p[P_PAN] + 1.0f) * 0.25f * PI;
		const float pl = std::cos(a) * 1.414f, pr = std::sin(a) * 1.414f;
		for (int i = 0; i < TB; i++) {
			float l = in[I_L][i], r = stereo ? in[I_R][i] : in[I_L][i];
			l *= pl;
			r *= pr;
			if (p[P_MIX] > 0.001f) reverb.process(l, r, p[P_SIZE], p[P_DECAY], p[P_DAMP], 0.01f, p[P_MIX]);
			c.out_l[i] += dc_l.process(l) * p[P_LEVEL];
			c.out_r[i] += dc_r.process(r) * p[P_LEVEL];
		}
	}
};

// ---------------------------------------------------------------- descriptors

static std::vector<ModuleDesc> build_descs() {
	std::vector<ModuleDesc> d;
	auto ports = [](std::initializer_list<std::pair<const char *, const char *>> l) {
		std::vector<PortInfo> v;
		for (auto &x : l) v.push_back({ x.first, x.second });
		return v;
	};
	{
		ModuleDesc m{ "midi", "MIDI→CV", "Turns your playing into pitch, gate, velocity and modulation voltages." };
		m.outputs = ports({ { "pitch", "Pitch" }, { "gate", "Gate" }, { "velocity", "Velocity" }, { "mod", "Mod Wheel" }, { "pressure", "Pressure" }, { "trig", "Trigger" } });
		m.params = { pf("glide", "Glide", "", 0, 2, 0, "s"), pi("bend", "Bend Range", "", 0, 12, 2, "st"), pi("octave", "Octave", "", -3, 3, 0) };
		m.make = [] { return new MidiCvModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "clock", "Clock", "Pulses locked to the session tempo." };
		m.outputs = ports({ { "16", "1/16" }, { "8", "1/8" }, { "4", "1/4" }, { "bar", "Bar" }, { "8t", "1/8T" }, { "reset", "Reset" } });
		m.params = { pf("swing", "Swing", "", 50, 75, 50, "%"), pf("width", "Pulse Width", "", 0.05f, 0.95f, 0.5f), pb("run", "Run", "", true) };
		m.make = [] { return new ClockModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "vco", "VCO", "Oscillator with sine, triangle, saw and pulse outputs." };
		m.inputs = ports({ { "pitch", "V/Oct" }, { "fm", "FM" }, { "pwm", "PWM" }, { "sync", "Sync" } });
		m.outputs = ports({ { "sine", "Sine" }, { "tri", "Triangle" }, { "saw", "Saw" }, { "pulse", "Pulse" } });
		m.params = { pi("octave", "Octave", "", -4, 4, -1), pi("semi", "Semitones", "", -12, 12, 0, "st"), pf("fine", "Fine", "", -50, 50, 0, "ct"), pf("fm", "FM Amount", "", 0, 4, 0), pf("pw", "Pulse Width", "", 0.05f, 0.95f, 0.5f), pf("pwm", "PWM Amount", "", 0, 1, 0) };
		m.make = [] { return new VcoModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "noise", "Noise / S&H", "White and pink noise, and a sample & hold." };
		m.inputs = ports({ { "signal", "S&H In" }, { "trig", "Trigger" } });
		m.outputs = ports({ { "white", "White" }, { "pink", "Pink" }, { "sh", "S&H" } });
		m.params = { pf("glide", "S&H Glide", "", 0, 1, 0, "s"), pf("level", "Noise Level", "", 0, 1, 0.8f) };
		m.make = [] { return new NoiseShModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "vcf", "VCF", "Filter with 24 dB ladder, 12 dB low-pass, band-pass and high-pass outputs." };
		m.inputs = ports({ { "in", "In" }, { "cutoff", "Cutoff CV" }, { "res", "Res CV" } });
		m.outputs = ports({ { "lp24", "LP 24" }, { "lp12", "LP 12" }, { "bp", "BP" }, { "hp", "HP" } });
		m.params = { pf("cutoff", "Cutoff", "", 20, 18000, 1200, "Hz", true), pf("res", "Resonance", "", 0, 1, 0.25f), pf("cv", "CV Amount", "", -8, 8, 4, "oct"), pf("drive", "Drive", "", 0, 10, 1) };
		m.make = [] { return new VcfModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "vca", "Dual VCA", "Two amplifiers; the level knob is the opening with no CV." };
		m.inputs = ports({ { "a", "A In" }, { "a_cv", "A CV" }, { "b", "B In" }, { "b_cv", "B CV" } });
		m.outputs = ports({ { "a", "A Out" }, { "b", "B Out" }, { "mix", "Mix" } });
		m.params = { pf("a", "A Level", "", 0, 1, 0), pf("b", "B Level", "", 0, 1, 0), pe("response", "Response", "", { "Linear", "Exponential" }, 0) };
		m.make = [] { return new VcaModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "adsr", "ADSR", "Envelope generator." };
		m.inputs = ports({ { "gate", "Gate" }, { "retrig", "Retrigger" } });
		m.outputs = ports({ { "env", "Env" }, { "inv", "Inverted" } });
		m.params = { pf("attack", "Attack", "", 0.001f, 10, 0.005f, "s", true), pf("decay", "Decay", "", 0.005f, 10, 0.3f, "s", true), pf("sustain", "Sustain", "", 0, 1, 0.6f), pf("release", "Release", "", 0.005f, 10, 0.4f, "s", true) };
		m.make = [] { return new AdsrModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "lfo", "LFO", "Slow oscillator; can lock to the clock." };
		m.inputs = ports({ { "rate", "Rate CV" }, { "reset", "Reset" } });
		m.outputs = ports({ { "sine", "Sine" }, { "tri", "Triangle" }, { "saw", "Saw" }, { "square", "Square" }, { "random", "Random" } });
		m.params = { pf("rate", "Rate", "", 0.01f, 40, 1, "Hz", true), pe("sync", "Sync", "", SYNC_DIVS, 0), pb("unipolar", "Unipolar", "", false) };
		m.make = [] { return new LfoModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "seq", "Step Sequencer", "16 steps of pitch and gate, quantized to a scale." };
		m.inputs = ports({ { "clock", "Clock" }, { "reset", "Reset" } });
		m.outputs = ports({ { "pitch", "Pitch" }, { "gate", "Gate" }, { "trig", "Trigger" }, { "eoc", "End of Cycle" } });
		m.params = { pi("steps", "Steps", "", 1, 16, 8), pf("length", "Gate Length", "", 0.05f, 1.0f, 0.5f),
			pe("scale", "Scale", "", { "Chromatic", "Major", "Minor", "Pentatonic Major", "Pentatonic Minor", "Dorian", "Blues" }, 2),
			pi("root", "Root", "", 0, 11, 0), pi("octave", "Octave", "", -3, 3, -1) };
		static const int pattern[16] = { 0, 0, 7, 0, 3, 0, 5, 4, 0, 0, 7, 9, 3, 2, 5, 4 };
		for (int s = 0; s < 16; s++) m.params.push_back(pi(("note" + std::to_string(s + 1)).c_str(), ("Step " + std::to_string(s + 1)).c_str(), "Notes", 0, 24, pattern[s]));
		for (int s = 0; s < 16; s++) m.params.push_back(pb(("gate" + std::to_string(s + 1)).c_str(), ("Gate " + std::to_string(s + 1)).c_str(), "Gates", s % 4 != 3));
		m.make = [] { return new SeqModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "util", "Utility", "Mixer, attenuverter with offset, inverter and slew limiter." };
		m.inputs = ports({ { "a", "Mix A" }, { "b", "Mix B" }, { "c", "Mix C" }, { "d", "Mix D" }, { "x", "Atten In" }, { "slew", "Slew In" } });
		m.outputs = ports({ { "mix", "Mix" }, { "x", "Atten Out" }, { "slew", "Slew Out" }, { "inv", "Inverted" } });
		m.params = { pf("a", "Level A", "", 0, 1, 1), pf("b", "Level B", "", 0, 1, 1), pf("c", "Level C", "", 0, 1, 1), pf("d", "Level D", "", 0, 1, 1), pf("atten", "Attenuverter", "", -1, 1, 1), pf("offset", "Offset", "", -5, 5, 0, "V"), pf("slew", "Slew Time", "", 0, 2, 0.05f, "s") };
		m.make = [] { return new UtilityModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "delay", "Delay", "Echo with feedback; can lock to the tempo." };
		m.inputs = ports({ { "in", "In" }, { "time", "Time CV" } });
		m.outputs = ports({ { "out", "Out" }, { "wet", "Wet" } });
		m.params = { pe("sync", "Sync", "", SYNC_DIVS, 6), pf("time", "Time (Free)", "", 0.01f, 4, 0.35f, "s", true), pf("feedback", "Feedback", "", 0, 0.95f, 0.4f), pf("tone", "Tone", "", 300, 16000, 4000, "Hz", true), pf("mix", "Mix", "", 0, 1, 0.35f) };
		m.make = [] { return new DelayModule(); };
		d.push_back(m);
	}
	{
		ModuleDesc m{ "output", "Reverb + Output", "Reverb, then out to the instrument's speaker." };
		m.inputs = ports({ { "l", "Left / Mono" }, { "r", "Right" } });
		m.params = { pf("size", "Size", "", 0, 1, 0.6f), pf("decay", "Decay", "", 0.2f, 15, 2.5f, "s", true), pf("damping", "Damping", "", 0, 1, 0.4f), pf("mix", "Reverb Mix", "", 0, 1, 0.2f), pf("level", "Level", "", 0, 1.5f, 0.8f), pf("pan", "Pan", "", -1, 1, 0) };
		m.make = [] { return new OutputModule(); };
		d.push_back(m);
	}
	return d;
}

const std::vector<ModuleDesc> &tangle_modules() {
	static const std::vector<ModuleDesc> descs = build_descs();
	return descs;
}

int tangle_module_index(const std::string &type) {
	const auto &d = tangle_modules();
	for (size_t i = 0; i < d.size(); i++)
		if (d[i].type == type) return (int)i;
	return -1;
}

// ---------------------------------------------------------------- instrument

TangleInstrument::TangleInstrument() {
	info.push_back(pf("master.volume", "Volume", "Master", 0, 10, 7));
	finish_params();
}

TangleInstrument::~TangleInstrument() {
	for (Module *m : slots) delete m;
	delete routing;
	TangleGarbage g;
	while (garbage.pop(g)) {
		delete g.module;
		delete g.routing;
	}
}

void TangleInstrument::prepare(float p_sr) {
	sr = p_sr;
	ctx.sr = sr;
	for (Module *m : slots)
		if (m) m->prepare(sr);
}

void TangleInstrument::note_on(int note, float vel) {
	// Last-note priority stack.
	for (int i = 0; i < nheld; i++)
		if (held[i] == note) {
			for (int k = i + 1; k < nheld; k++) held[k - 1] = held[k];
			nheld--;
			break;
		}
	if (nheld < 16) held[nheld++] = note;
	ctx.pitch = (note - 60) / 12.0f;
	ctx.velocity = vel;
	ctx.gate = true;
	new_note = true;
}

void TangleInstrument::note_off(int note) {
	for (int i = 0; i < nheld; i++)
		if (held[i] == note) {
			for (int k = i + 1; k < nheld; k++) held[k - 1] = held[k];
			nheld--;
			break;
		}
	if (nheld > 0) ctx.pitch = (held[nheld - 1] - 60) / 12.0f;
	else ctx.gate = false;
}

void TangleInstrument::all_notes_off() {
	nheld = 0;
	ctx.gate = false;
}

void TangleInstrument::control_change(int cc, float value) {
	if (cc == 1) ctx.mod = value;
	else if (cc == 2 || cc == 128) ctx.pressure = value; // 128 = channel pressure
}

void TangleInstrument::custom_event(const Event &e) {
	const int slot = e.b & 0xFF;
	switch (e.a) {
		case TOP_ADD:
			if (slot < TANGLE_MAX_MODULES) {
				if (slots[slot]) garbage.push({ slots[slot], nullptr });
				slots[slot] = (Module *)e.ptr;
			}
			break;
		case TOP_REMOVE:
			if (slot < TANGLE_MAX_MODULES && slots[slot]) {
				garbage.push({ slots[slot], nullptr });
				slots[slot] = nullptr;
			}
			break;
		case TOP_ROUTING: {
			TangleRouting *old = routing;
			routing = (TangleRouting *)e.ptr;
			if (old) garbage.push({ nullptr, old });
		} break;
		case TOP_PARAM: {
			const int param = e.b >> 8;
			Module *m = slot < TANGLE_MAX_MODULES ? slots[slot] : nullptr;
			if (m && param < (int)m->p.size()) {
				m->p[param] = e.value;
				m->param_changed(param);
			}
		} break;
		default:
			break;
	}
}

void TangleInstrument::run_block() {
	ctx.tempo = tempo;
	ctx.bend = bend;
	ctx.beats_per_sample = tempo / 60.0 / sr;
	for (int i = 0; i < TB; i++) ctx.out_l[i] = ctx.out_r[i] = 0.0f;
	if (routing) {
		for (int k = 0; k < routing->count; k++) {
			const int s = routing->order[k];
			Module *m = slots[s];
			if (!m) continue;
			for (int i = 0; i < TANGLE_MAX_PORTS; i++) {
				const int ss = routing->src_slot[s][i];
				const int sp = routing->src_port[s][i];
				if (ss >= 0 && slots[ss]) {
					m->in[i] = slots[ss]->out[sp];
					m->connected[i] = true;
				} else {
					m->in[i] = zeros;
					m->connected[i] = false;
				}
			}
			m->process(ctx);
		}
	}
	ctx.beat += ctx.beats_per_sample * TB;
	ctx.retrig_at = -1;
	const float vol = p(0) * 0.1f;
	for (int i = 0; i < TB; i++) {
		block_l[i] = ctx.out_l[i] * vol;
		block_r[i] = ctx.out_r[i] * vol;
	}
}

void TangleInstrument::render(float *l, float *r, int n) {
	// Events arrive between render calls; the retrigger lands at the start of
	// the next block (at most 32 samples late).
	for (int i = 0; i < n; i++) {
		if (block_pos >= TB) {
			if (new_note) {
				ctx.retrig_at = 0;
				new_note = false;
			}
			run_block();
			block_pos = 0;
		}
		l[i] += block_l[block_pos];
		r[i] += block_r[block_pos];
		block_pos++;
	}
}

// ---------------------------------------------------------------- model

TangleModel::TangleModel() {
	mods.resize(TANGLE_MAX_MODULES);
}

int TangleModel::add(const std::string &type, float x, float y) {
	const int ti = tangle_module_index(type);
	if (ti < 0) return -1;
	int slot = -1;
	for (int i = 0; i < TANGLE_MAX_MODULES; i++)
		if (mods[i].id < 0) {
			slot = i;
			break;
		}
	if (slot < 0) return -1;
	const ModuleDesc &d = tangle_modules()[ti];
	Module *m = d.make();
	m->type_index = ti;
	m->p.resize(d.params.size());
	for (size_t i = 0; i < d.params.size(); i++) m->p[i] = d.params[i].def;
	for (int i = 0; i < TANGLE_MAX_PORTS; i++) m->in[i] = nullptr;
	m->prepare(sample_rate);
	if (!send(TOP_ADD, slot, 0, 0.0f, m)) {
		delete m;
		return -1;
	}
	Mod &md = mods[slot];
	md.id = slot;
	md.type = ti;
	md.x = x;
	md.y = y;
	md.params = m->p;
	push_routing();
	return slot;
}

bool TangleModel::remove(int id) {
	if (id < 0 || id >= TANGLE_MAX_MODULES || mods[id].id < 0) return false;
	std::vector<Cable> keep;
	for (const Cable &c : cables)
		if (c.from != id && c.to != id) keep.push_back(c);
	cables = keep;
	mods[id] = Mod();
	push_routing(); // routing first, so nothing reads the removed module
	send(TOP_REMOVE, id, 0, 0.0f, nullptr);
	return true;
}

static int port_index(const std::vector<PortInfo> &ports, const std::string &id) {
	for (size_t i = 0; i < ports.size(); i++)
		if (ports[i].id == id) return (int)i;
	return -1;
}

bool TangleModel::connect(int from, const std::string &out, int to, const std::string &in) {
	const Mod *a = get(from), *b = get(to);
	if (!a || !b) return false;
	const int op = port_index(tangle_modules()[a->type].outputs, out);
	const int ip = port_index(tangle_modules()[b->type].inputs, in);
	if (op < 0 || ip < 0) return false;
	for (Cable &c : cables)
		if (c.to == to && c.in == ip) {
			c.from = from;
			c.out = op;
			push_routing();
			return true;
		}
	cables.push_back({ from, op, to, ip });
	push_routing();
	return true;
}

bool TangleModel::disconnect(int to, const std::string &in) {
	const Mod *b = get(to);
	if (!b) return false;
	const int ip = port_index(tangle_modules()[b->type].inputs, in);
	for (size_t i = 0; i < cables.size(); i++)
		if (cables[i].to == to && cables[i].in == ip) {
			cables.erase(cables.begin() + i);
			push_routing();
			return true;
		}
	return false;
}

bool TangleModel::set_param(int id, const std::string &param, float v) {
	Mod *m = (id >= 0 && id < TANGLE_MAX_MODULES && mods[id].id >= 0) ? &mods[id] : nullptr;
	if (!m) return false;
	const auto &ps = tangle_modules()[m->type].params;
	for (size_t i = 0; i < ps.size(); i++)
		if (ps[i].id == param) {
			v = clampf(v, ps[i].min, ps[i].max);
			if (ps[i].type != P_FLOAT) v = (float)(int)(v + (v >= 0 ? 0.5f : -0.5f));
			m->params[i] = v;
			return send(TOP_PARAM, id | ((int)i << 8), 0, v, nullptr);
		}
	return false;
}

float TangleModel::get_param(int id, const std::string &param) const {
	const Mod *m = get(id);
	if (!m) return 0.0f;
	const auto &ps = tangle_modules()[m->type].params;
	for (size_t i = 0; i < ps.size(); i++)
		if (ps[i].id == param) return m->params[i];
	return 0.0f;
}

void TangleModel::clear() {
	cables.clear();
	push_routing();
	for (int i = 0; i < TANGLE_MAX_MODULES; i++)
		if (mods[i].id >= 0) {
			mods[i] = Mod();
			send(TOP_REMOVE, i, 0, 0.0f, nullptr);
		}
}

const TangleModel::Mod *TangleModel::get(int id) const {
	if (id < 0 || id >= TANGLE_MAX_MODULES || mods[id].id < 0) return nullptr;
	return &mods[id];
}

void TangleModel::push_routing() {
	TangleRouting *r = new TangleRouting();
	for (const Cable &c : cables) {
		r->src_slot[c.to][c.in] = c.from;
		r->src_port[c.to][c.in] = c.out;
	}
	// Order: depth-first from sources so most cables see this block's data;
	// modules in a loop fall back to last block's output.
	int state[TANGLE_MAX_MODULES] = {}; // 0 new, 1 visiting, 2 done
	std::function<void(int)> visit = [&](int s) {
		if (state[s]) return;
		state[s] = 1;
		for (int i = 0; i < TANGLE_MAX_PORTS; i++) {
			const int src = r->src_slot[s][i];
			if (src >= 0 && mods[src].id >= 0 && state[src] == 0) visit(src);
		}
		state[s] = 2;
		r->order[r->count++] = s;
	};
	for (int s = 0; s < TANGLE_MAX_MODULES; s++)
		if (mods[s].id >= 0) visit(s);
	if (!send(TOP_ROUTING, 0, 0, 0.0f, r)) delete r;
}

void TangleModel::collect(TangleInstrument *inst) {
	if (!inst) return;
	TangleGarbage g;
	while (inst->garbage.pop(g)) {
		delete g.module;
		delete g.routing;
	}
}

void TangleModel::build_default() {
	clear();
	const int midi = add("midi", 0, 0);
	const int vco = add("vco", 1, 0);
	const int vco2 = add("vco", 1, 1);
	const int mix = add("util", 2, 1);
	const int vcf = add("vcf", 2, 0);
	const int env = add("adsr", 3, 1);
	const int vca = add("vca", 3, 0);
	const int out = add("output", 4, 0);
	set_param(vco2, "fine", 7.0f);
	set_param(vco2, "octave", -1.0f);
	connect(midi, "pitch", vco, "pitch");
	connect(midi, "pitch", vco2, "pitch");
	connect(vco, "saw", mix, "a");
	connect(vco2, "pulse", mix, "b");
	set_param(mix, "a", 0.6f);
	set_param(mix, "b", 0.45f);
	connect(mix, "mix", vcf, "in");
	connect(midi, "gate", env, "gate");
	connect(env, "env", vcf, "cutoff");
	connect(vcf, "lp24", vca, "a");
	connect(env, "env", vca, "a_cv");
	connect(vca, "a", out, "l");
	set_param(vcf, "cutoff", 500.0f);
	set_param(vcf, "cv", 4.0f);
	set_param(vcf, "res", 0.35f);
}

Instrument *make_tangle() { return new TangleInstrument(); }

} // namespace jam
