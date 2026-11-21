// Band-limited oscillators (PolyBLEP). Our own implementation.
#pragma once
#include "dsp.h"

namespace jam {

inline float poly_blep(float t, float dt) {
	if (t < dt) {
		t /= dt;
		return t + t - t * t - 1.0f;
	}
	if (t > 1.0f - dt) {
		t = (t - 1.0f) / dt;
		return t * t + t + t + 1.0f;
	}
	return 0.0f;
}

enum Wave {
	WAVE_SINE = 0,
	WAVE_TRIANGLE,
	WAVE_SHARK, // triangle/saw hybrid
	WAVE_SAW,
	WAVE_SQUARE,
	WAVE_PULSE_WIDE, // 30%
	WAVE_PULSE_NARROW, // 12%
	WAVE_REVERSE_SAW,
	WAVE_PULSE, // variable width
	WAVE_COUNT
};

struct Osc {
	float phase = 0.0f; // 0..1
	bool wrapped = false; // true on the sample the phase wrapped (for hard sync)
	float wrap_frac = 0.0f; // fractional position of the wrap within the sample

	void reset(float p = 0.0f) { phase = p; }

	// dt = freq / sample_rate. pw used by WAVE_PULSE.
	inline float process(float dt, int wave, float pw = 0.5f) {
		dt = clampf(dt, 0.0f, 0.49f);
		float out = 0.0f;
		const float t = phase;
		switch (wave) {
			case WAVE_SINE:
				out = std::sin(TWO_PI * t);
				break;
			case WAVE_TRIANGLE:
				out = 1.0f - 4.0f * std::fabs(t - 0.5f);
				out = -out; // start at -1 rising, like the saw
				break;
			case WAVE_SHARK: {
				float tri = -(1.0f - 4.0f * std::fabs(t - 0.5f));
				float saw = 2.0f * t - 1.0f - poly_blep(t, dt);
				out = 0.5f * (tri + saw);
			} break;
			case WAVE_SAW:
				out = 2.0f * t - 1.0f - poly_blep(t, dt);
				break;
			case WAVE_REVERSE_SAW:
				out = -(2.0f * t - 1.0f - poly_blep(t, dt));
				break;
			case WAVE_SQUARE:
			case WAVE_PULSE_WIDE:
			case WAVE_PULSE_NARROW:
			case WAVE_PULSE: {
				float w = 0.5f;
				if (wave == WAVE_PULSE_WIDE) w = 0.3f;
				else if (wave == WAVE_PULSE_NARROW) w = 0.12f;
				else if (wave == WAVE_PULSE) w = clampf(pw, 0.03f, 0.97f);
				out = t < w ? 1.0f : -1.0f;
				out += poly_blep(t, dt);
				float t2 = t - w;
				if (t2 < 0.0f) t2 += 1.0f;
				out -= poly_blep(t2, dt);
				// keep DC near zero for narrow pulses
				out -= (2.0f * w - 1.0f);
			} break;
			default:
				break;
		}
		phase += dt;
		wrapped = false;
		if (phase >= 1.0f) {
			phase -= 1.0f;
			wrapped = true;
			wrap_frac = dt > 0.0f ? phase / dt : 0.0f;
		}
		return out;
	}

	// Hard sync: restart phase at the master's wrap point.
	inline void sync_to(float master_frac, float dt) { phase = master_frac * dt; }
};

// Simple LFO with several shapes, output -1..1.
struct Lfo {
	float phase = 0.0f;
	float held = 0.0f;
	Rng rng;
	enum Shape { SINE = 0, TRIANGLE, SAW, SQUARE, RANDOM, SHAPE_COUNT };
	inline float process(float hz, float sr, int shape) {
		float out;
		switch (shape) {
			case SINE: out = std::sin(TWO_PI * phase); break;
			case TRIANGLE: out = 1.0f - 4.0f * std::fabs(phase - 0.5f); break;
			case SAW: out = 2.0f * phase - 1.0f; break;
			case SQUARE: out = phase < 0.5f ? 1.0f : -1.0f; break;
			default: out = held; break;
		}
		phase += hz / sr;
		if (phase >= 1.0f) {
			phase -= std::floor(phase);
			held = rng.white();
		}
		return out;
	}
};

} // namespace jam
