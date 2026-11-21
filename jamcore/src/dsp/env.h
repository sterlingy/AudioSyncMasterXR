// Analog-style envelopes. Our own implementation.
#pragma once
#include "dsp.h"

namespace jam {

// ADSR with exponential segments. The attack aims past 1.0 so it has the
// curved, punchy shape of an analog contour generator.
struct Adsr {
	enum Stage { IDLE = 0, ATTACK, DECAY, SUSTAIN, RELEASE };
	Stage stage = IDLE;
	float value = 0.0f;
	float sr = 48000.0f;
	float a_coef = 0, d_coef = 0, r_coef = 0;
	float sustain = 1.0f;

	void init(float p_sr) { sr = p_sr; }
	static float coef(float seconds, float sr, float k) {
		seconds = seconds < 0.0005f ? 0.0005f : seconds;
		return std::exp(-k / (seconds * sr));
	}
	// Times in seconds; sustain 0..1.
	void set(float attack, float decay, float p_sustain, float release) {
		a_coef = coef(attack, sr, 1.79f);
		d_coef = coef(decay, sr, 4.6f);
		r_coef = coef(release, sr, 4.6f);
		sustain = clampf(p_sustain, 0.0f, 1.0f);
	}
	void gate_on(bool retrigger = true) {
		if (retrigger || stage == IDLE || stage == RELEASE) stage = ATTACK;
	}
	void gate_off() {
		if (stage != IDLE) stage = RELEASE;
	}
	void kill() {
		stage = IDLE;
		value = 0.0f;
	}
	bool active() const { return stage != IDLE; }
	inline float process() {
		switch (stage) {
			case ATTACK:
				value = 1.2f + (value - 1.2f) * a_coef;
				if (value >= 1.0f) {
					value = 1.0f;
					stage = DECAY;
				}
				break;
			case DECAY:
				value = sustain + (value - sustain) * d_coef;
				if (std::fabs(value - sustain) < 1e-4f) {
					value = sustain;
					stage = SUSTAIN;
				}
				break;
			case SUSTAIN:
				value = sustain;
				break;
			case RELEASE:
				value = -0.001f + (value + 0.001f) * r_coef;
				if (value <= 0.0f) {
					value = 0.0f;
					stage = IDLE;
				}
				break;
			default:
				break;
		}
		return value;
	}
};

// One-shot decay envelope with optional short attack, for drums and plucks.
struct DecayEnv {
	float value = 0.0f;
	float coef = 0.0f;
	float sr = 48000.0f;
	void init(float p_sr) { sr = p_sr; }
	void trigger(float level, float decay_s) {
		value = level;
		coef = std::exp(-4.6f / (std::max(decay_s, 0.001f) * sr));
	}
	inline float process() {
		const float v = value;
		value = undenormal(value * coef);
		return v;
	}
	bool active() const { return value > 1e-4f; }
};

// Glide (portamento) on a pitch value in semitones.
struct Glide {
	float value = 60.0f;
	float coef = 0.0f;
	void set(float seconds, float sr) { coef = seconds <= 0.001f ? 0.0f : std::exp(-4.6f / (seconds * sr)); }
	void jump(float v) { value = v; }
	inline float process(float target) {
		value = target + coef * (value - target);
		return value;
	}
};

} // namespace jam
