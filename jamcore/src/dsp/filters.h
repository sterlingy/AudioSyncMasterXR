// Filters: zero-delay-feedback ladder (Model D style) and TPT state-variable filter.
// Our own implementations, after Zavalishin, "The Art of VA Filter Design".
#pragma once
#include "dsp.h"

namespace jam {

// 24 dB/oct four-pole ladder with saturating feedback. resonance 0..1 maps to
// k 0..4.2 so the top of the range self-oscillates, like the original.
// Runs 2x oversampled internally.
struct LadderFilter {
	float s[4] = { 0, 0, 0, 0 };
	float sr2 = 96000.0f;
	float last_in = 0.0f;
	void init(float sr) {
		sr2 = sr * 2.0f;
		reset();
	}
	void reset() {
		s[0] = s[1] = s[2] = s[3] = 0.0f;
		last_in = 0.0f;
	}
	inline float tick(float x, float G, float beta, float k, float drive) {
		const float G2 = G * G;
		const float G4 = G2 * G2;
		const float S = G2 * G * beta * s[0] + G2 * beta * s[1] + G * beta * s[2] + beta * s[3];
		const float y4 = (G4 * x + S) / (1.0f + k * G4);
		float u = fast_tanh((x - k * y4) * drive) / drive;
		for (int i = 0; i < 4; i++) {
			const float v = (u - s[i]) * G;
			const float y = v + s[i];
			s[i] = undenormal(y + v);
			u = y;
		}
		return u;
	}
	// cutoff in Hz, resonance 0..1, drive >= 1 (input saturation).
	inline float process(float x, float cutoff, float resonance, float drive = 1.0f) {
		cutoff = clampf(cutoff, 10.0f, sr2 * 0.24f);
		const float g = std::tan(PI * cutoff / sr2);
		const float G = g / (1.0f + g);
		const float beta = 1.0f / (1.0f + g);
		const float k = clampf(resonance, 0.0f, 1.0f) * 4.2f;
		// Mild bass compensation so high emphasis doesn't hollow out the sound completely.
		const float comp = 1.0f + 0.35f * k;
		const float xin = x * comp;
		const float mid = 0.5f * (last_in + xin);
		last_in = xin;
		float a = tick(mid, G, beta, k, drive);
		float b = tick(xin, G, beta, k, drive);
		return 0.5f * (a + b);
	}
};

// TPT state-variable filter (12 dB/oct). Outputs low, band, high.
struct Svf {
	float ic1 = 0, ic2 = 0;
	float lp = 0, bp = 0, hp = 0;
	float sr = 48000.0f;
	void init(float p_sr) {
		sr = p_sr;
		reset();
	}
	void reset() { ic1 = ic2 = lp = bp = hp = 0.0f; }
	// resonance 0..1 (1 = near self-oscillation).
	inline void process(float x, float cutoff, float resonance) {
		cutoff = clampf(cutoff, 10.0f, sr * 0.45f);
		const float g = std::tan(PI * cutoff / sr);
		const float k = 2.0f - 1.98f * clampf(resonance, 0.0f, 1.0f);
		const float a1 = 1.0f / (1.0f + g * (g + k));
		const float a2 = g * a1;
		const float a3 = g * a2;
		const float v3 = x - ic2;
		const float v1 = a1 * ic1 + a2 * v3;
		const float v2 = ic2 + a2 * ic1 + a3 * v3;
		ic1 = undenormal(2.0f * v1 - ic1);
		ic2 = undenormal(2.0f * v2 - ic2);
		lp = v2;
		bp = v1;
		hp = x - k * v1 - v2;
	}
};

// Multimode filter: 12/24 dB low-pass, band-pass, high-pass from two SVFs.
struct MultiFilter {
	Svf a, b;
	enum Mode { LP24 = 0, LP12, BP, HP, MODE_COUNT };
	void init(float sr) {
		a.init(sr);
		b.init(sr);
	}
	void reset() {
		a.reset();
		b.reset();
	}
	inline float process(float x, float cutoff, float resonance, int mode) {
		switch (mode) {
			case LP24:
				a.process(x, cutoff, resonance * 0.6f);
				b.process(a.lp, cutoff, resonance);
				return b.lp;
			case LP12:
				a.process(x, cutoff, resonance);
				return a.lp;
			case BP:
				a.process(x, cutoff, resonance);
				return a.bp;
			default:
				a.process(x, cutoff, resonance);
				return a.hp;
		}
	}
};

// One-pole low-pass / high-pass for tone controls and damping.
struct OnePole {
	float y = 0.0f;
	float a = 0.0f;
	void set(float cutoff, float sr) { a = std::exp(-TWO_PI * clampf(cutoff, 1.0f, sr * 0.49f) / sr); }
	inline float lp(float x) {
		y = undenormal(x + a * (y - x));
		return y;
	}
	inline float hp(float x) { return x - lp(x); }
};

// Two-pole resonator (band-pass), used by drums and modal synthesis.
struct Resonator {
	float b1 = 0, b2 = 0, gain = 0, y1 = 0, y2 = 0;
	void set(float freq, float decay_s, float sr) {
		freq = clampf(freq, 10.0f, sr * 0.45f);
		const float r = std::exp(-1.0f / (decay_s * sr));
		b1 = 2.0f * r * std::cos(TWO_PI * freq / sr);
		b2 = -r * r;
		gain = (1.0f - r * r) * 0.5f;
	}
	// Same, but a unit impulse rings at roughly unit amplitude whatever the decay
	// (used for modal synthesis, where decays are long).
	void set_normalized(float freq, float decay_s, float sr) {
		set(freq, decay_s, sr);
		gain = std::sin(TWO_PI * clampf(freq, 10.0f, sr * 0.45f) / sr);
	}
	// Same, but a sine at the resonant frequency comes out at unit gain
	// (used as a body/formant resonance).
	void set_peak_unity(float freq, float decay_s, float sr) {
		set(freq, decay_s, sr);
		const float r = std::sqrt(-b2);
		gain = (1.0f - r) * 2.0f * std::sin(TWO_PI * clampf(freq, 10.0f, sr * 0.45f) / sr);
	}
	void reset() { y1 = y2 = 0.0f; }
	inline float process(float x) {
		const float y = gain * x + b1 * y1 + b2 * y2;
		y2 = y1;
		y1 = undenormal(y);
		return y;
	}
};

} // namespace jam
