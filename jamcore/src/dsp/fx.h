// Effects: delay line, stereo delay, chorus, FDN reverb, drive. Our own implementations.
// Buffers are allocated in init() (main thread), never on the audio thread.
#pragma once
#include "dsp.h"
#include "filters.h"
#include <vector>

namespace jam {

struct DelayLine {
	std::vector<float> buf;
	int mask = 0;
	int w = 0;
	void init(int max_samples) {
		int n = 1;
		while (n < max_samples + 4) n <<= 1;
		buf.assign(n, 0.0f);
		mask = n - 1;
		w = 0;
	}
	void clear() { std::fill(buf.begin(), buf.end(), 0.0f); }
	inline void write(float x) {
		buf[w] = x;
		w = (w + 1) & mask;
	}
	// Read `d` samples back (fractional, linear interpolation). d >= 1.
	inline float read(float d) const {
		float pos = (float)w - d;
		while (pos < 0.0f) pos += (float)(mask + 1);
		const int i0 = (int)pos;
		const float f = pos - (float)i0;
		const float a = buf[i0 & mask];
		const float b = buf[(i0 + 1) & mask];
		return a + (b - a) * f;
	}
	inline float read_int(int d) const { return buf[(w - d) & mask]; }
};

// Stereo (optionally ping-pong) delay with a tone filter in the feedback path.
struct StereoDelay {
	DelayLine l, r;
	OnePole tone_l, tone_r;
	Smoother time_s;
	float sr = 48000.0f;
	void init(float p_sr, float max_seconds) {
		sr = p_sr;
		l.init((int)(max_seconds * sr));
		r.init((int)(max_seconds * sr));
		time_s.init(sr, 80.0f);
		time_s.reset(0.25f * sr);
	}
	void clear() {
		l.clear();
		r.clear();
	}
	// time in seconds, feedback 0..0.95, tone in Hz, mix 0..1.
	inline void process(float &inout_l, float &inout_r, float time, float feedback, float tone_hz, float mix, bool ping_pong) {
		const float d = time_s.process(clampf(time * sr, 1.0f, (float)l.mask - 2.0f));
		tone_l.set(tone_hz, sr);
		tone_r.set(tone_hz, sr);
		const float dl = l.read(d);
		const float dr = r.read(d);
		const float in_l = inout_l, in_r = inout_r;
		if (ping_pong) {
			l.write(undenormal(tone_l.lp(0.5f * (in_l + in_r) + dr * feedback)));
			r.write(undenormal(tone_r.lp(dl * feedback)));
		} else {
			l.write(undenormal(tone_l.lp(in_l + dl * feedback)));
			r.write(undenormal(tone_r.lp(in_r + dr * feedback)));
		}
		inout_l = in_l + dl * mix;
		inout_r = in_r + dr * mix;
	}
};

// Stereo chorus: two modulated taps with opposite LFO phases.
struct Chorus {
	DelayLine l, r;
	float phase = 0.0f;
	float sr = 48000.0f;
	void init(float p_sr) {
		sr = p_sr;
		l.init((int)(0.05f * sr));
		r.init((int)(0.05f * sr));
	}
	inline void process(float &io_l, float &io_r, float rate_hz, float depth, float mix) {
		phase += rate_hz / sr;
		if (phase >= 1.0f) phase -= 1.0f;
		const float base = 0.012f * sr;
		const float mod = depth * 0.006f * sr;
		const float m1 = std::sin(TWO_PI * phase);
		const float m2 = std::sin(TWO_PI * (phase + 0.5f));
		l.write(io_l);
		r.write(io_r);
		const float wl = l.read(base + mod * m1);
		const float wr = r.read(base + mod * m2);
		io_l = io_l * (1.0f - 0.5f * mix) + wl * mix;
		io_r = io_r * (1.0f - 0.5f * mix) + wr * mix;
	}
};

// Allpass diffuser for the reverb input.
struct Allpass {
	DelayLine d;
	int len = 1;
	void init(int samples) {
		d.init(samples + 2);
		len = samples;
	}
	inline float process(float x, float g) {
		const float z = d.read_int(len);
		const float v = x + g * z;
		d.write(undenormal(v));
		return z - g * v;
	}
};

// 8-line feedback delay network reverb with Householder mixing,
// damping in the loop, slow modulation and pre-delay.
struct Reverb {
	static constexpr int N = 8;
	DelayLine lines[N];
	OnePole damp[N];
	Allpass diff[4];
	DelayLine pre;
	float base_len[N];
	float sr = 48000.0f;
	float lfo = 0.0f;
	float size = -1.0f, decay = -1.0f, damping = -1.0f;
	float fb_gain[N];

	void init(float p_sr) {
		sr = p_sr;
		static const float ms[N] = { 29.7f, 37.1f, 41.1f, 43.7f, 53.3f, 59.9f, 67.1f, 73.3f };
		for (int i = 0; i < N; i++) {
			base_len[i] = ms[i] * 0.001f * sr;
			lines[i].init((int)(base_len[i] * 2.2f) + 64);
			fb_gain[i] = 0.0f;
		}
		static const float ap_ms[4] = { 4.77f, 3.59f, 12.73f, 9.31f };
		for (int i = 0; i < 4; i++) diff[i].init((int)(ap_ms[i] * 0.001f * sr));
		pre.init((int)(0.2f * sr));
	}
	void clear() {
		for (auto &l : lines) l.clear();
		pre.clear();
	}
	// size 0..1, decay seconds (RT60), damping 0..1, predelay seconds, mix 0..1
	inline void process(float &io_l, float &io_r, float p_size, float p_decay, float p_damping, float predelay, float mix) {
		if (p_size != size || p_decay != decay || p_damping != damping) {
			size = p_size;
			decay = p_decay;
			damping = p_damping;
			const float scale = 0.4f + 1.6f * clampf(size, 0.0f, 1.0f);
			for (int i = 0; i < N; i++) {
				const float len_s = base_len[i] * scale / sr;
				fb_gain[i] = std::pow(10.0f, -3.0f * len_s / std::max(decay, 0.1f));
				damp[i].set(exp_map(1.0f - clampf(damping, 0.0f, 1.0f), 1500.0f, 18000.0f), sr);
			}
		}
		const float scale = 0.4f + 1.6f * clampf(size, 0.0f, 1.0f);
		lfo += 0.3f / sr;
		if (lfo >= 1.0f) lfo -= 1.0f;

		pre.write(0.5f * (io_l + io_r));
		float x = pre.read(std::max(1.0f, predelay * sr));
		for (int i = 0; i < 4; i++) x = diff[i].process(x, 0.6f);

		float o[N];
		float sum = 0.0f;
		for (int i = 0; i < N; i++) {
			const float mod = (i & 1 ? 1.0f : -1.0f) * 8.0f * std::sin(TWO_PI * (lfo + i * 0.125f));
			o[i] = lines[i].read(base_len[i] * scale + mod + 2.0f);
			sum += o[i];
		}
		const float h = sum * (2.0f / N);
		for (int i = 0; i < N; i++) {
			float v = (o[i] - h) * fb_gain[i];
			v = damp[i].lp(v);
			lines[i].write(undenormal(v + x * ((i & 1) ? -0.35f : 0.35f)));
		}
		const float wl = o[0] + o[2] + o[4] + o[6];
		const float wr = o[1] + o[3] + o[5] + o[7];
		io_l = io_l * (1.0f - mix) + wl * 0.5f * mix;
		io_r = io_r * (1.0f - mix) + wr * 0.5f * mix;
	}
};

// Soft-clip drive with makeup gain. amount 0..1.
inline float drive(float x, float amount) {
	if (amount <= 0.001f) return x;
	const float g = 1.0f + amount * 9.0f;
	return fast_tanh(x * g) / fast_tanh(g);
}

} // namespace jam
