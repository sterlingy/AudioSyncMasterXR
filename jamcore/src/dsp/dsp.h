// Core DSP helpers for jamcore. Our own code (no GPL sources).
#pragma once
#include <cmath>
#include <cstdint>
#include <algorithm>

namespace jam {

constexpr float PI = 3.14159265358979f;
constexpr float TWO_PI = 6.28318530717959f;

inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
inline float lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float midi_to_hz(float note) { return 440.0f * std::exp2((note - 69.0f) / 12.0f); }
inline float db_to_gain(float db) { return std::pow(10.0f, db * 0.05f); }
inline float gain_to_db(float g) { return g > 1e-9f ? 20.0f * std::log10(g) : -180.0f; }

// Pade-style tanh, accurate to a few percent, clamps outside +-3.
inline float fast_tanh(float x) {
	if (x > 3.0f) return 1.0f;
	if (x < -3.0f) return -1.0f;
	const float x2 = x * x;
	return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

// Flush tiny values so feedback loops never go denormal.
inline float undenormal(float x) { return (std::fabs(x) < 1e-15f) ? 0.0f : x; }

// One-pole smoother for parameters (no zipper noise).
struct Smoother {
	float y = 0.0f;
	float a = 0.0f;
	void init(float sr, float ms) { a = std::exp(-1.0f / (sr * ms * 0.001f)); }
	void reset(float v) { y = v; }
	inline float process(float target) {
		y = target + a * (y - target);
		return y;
	}
};

// xorshift noise; deterministic per instance.
struct Rng {
	uint32_t s = 0x9E3779B9u;
	void seed(uint32_t v) { s = v ? v : 0x9E3779B9u; }
	inline uint32_t next() {
		s ^= s << 13;
		s ^= s >> 17;
		s ^= s << 5;
		return s;
	}
	inline float white() { return (float)(next() >> 8) * (2.0f / 16777216.0f) - 1.0f; }
	inline float uni() { return (float)(next() >> 8) * (1.0f / 16777216.0f); }
};

// Pink noise (Paul Kellet's economy filter), output roughly +-1.
struct PinkNoise {
	float b0 = 0, b1 = 0, b2 = 0;
	inline float process(float white) {
		b0 = 0.99765f * b0 + white * 0.0990460f;
		b1 = 0.96300f * b1 + white * 0.2965164f;
		b2 = 0.57000f * b2 + white * 1.0526913f;
		return (b0 + b1 + b2 + white * 0.1848f) * 0.25f;
	}
};

struct DcBlocker {
	float x1 = 0, y1 = 0, r = 0.995f;
	void init(float sr) { r = 1.0f - (TWO_PI * 20.0f / sr); }
	inline float process(float x) {
		float y = x - x1 + r * y1;
		x1 = x;
		y1 = undenormal(y);
		return y;
	}
};

// Exponential knob mapping: t in [0,1] -> [lo,hi] geometrically.
inline float exp_map(float t, float lo, float hi) { return lo * std::pow(hi / lo, clampf(t, 0.0f, 1.0f)); }

} // namespace jam
