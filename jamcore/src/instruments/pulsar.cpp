// Pulsar: synthesized analog-style drum machine. Eight voices, each with
// tune, decay, tone, snap, level and pan. Notes follow General MIDI drums.
#include "dsp/env.h"
#include "dsp/filters.h"
#include "dsp/fx.h"
#include "engine/instrument.h"

namespace jam {

class Pulsar : public Instrument {
public:
	enum Voice { KICK = 0, SNARE, CLAP, CHAT, OHAT, LTOM, HTOM, CYMBAL, NV };
	enum Field { TUNE = 0, DECAY, TONE, SNAP, LEVEL, PAN, NF };
	enum Master { M_DRIVE = NV * NF, M_SWEEP, M_CHOKE, M_VOLUME, COUNT };

private:
	struct Drum {
		float t = 0.0f; // seconds since trigger
		float vel = 0.0f;
		bool on = false;
		float phase = 0.0f, phase2 = 0.0f;
		DecayEnv amp, amp2, pitch, noise;
		Svf f1, f2;
		OnePole hp;
		float metal_phase[6] = { 0, 0, 0, 0, 0, 0 };
	};
	Drum d[NV];
	Rng rng;
	DcBlocker dc_l, dc_r;

	int pidx(int voice, int field) const { return voice * NF + field; }
	float vp(int voice, int field) const { return p(pidx(voice, field)); }

public:
	Pulsar() {
		static const char *names[NV] = { "Kick", "Snare", "Clap", "Closed Hat", "Open Hat", "Low Tom", "High Tom", "Cymbal" };
		static const char *keys[NV] = { "kick", "snare", "clap", "chat", "ohat", "ltom", "htom", "cymbal" };
		static const float levels[NV] = { 9, 7.5f, 6.5f, 5.5f, 5, 7, 7, 4.5f };
		static const float pans[NV] = { 0, 0, 0.1f, 0.25f, 0.3f, -0.3f, 0.2f, -0.2f };
		info.resize(COUNT);
		for (int v = 0; v < NV; v++) {
			std::string k = keys[v];
			std::string g = names[v];
			// ParamInfo keeps its own copies of these strings.
			info[pidx(v, TUNE)] = pf((k + ".tune").c_str(), "Tune", g.c_str(), -12, 12, 0, "st");
			info[pidx(v, DECAY)] = pf((k + ".decay").c_str(), "Decay", g.c_str(), 0, 10, 5);
			info[pidx(v, TONE)] = pf((k + ".tone").c_str(), "Tone", g.c_str(), 0, 10, 5);
			info[pidx(v, SNAP)] = pf((k + ".snap").c_str(), v == KICK ? "Click" : (v == CLAP ? "Spread" : "Snap"), g.c_str(), 0, 10, 5);
			info[pidx(v, LEVEL)] = pf((k + ".level").c_str(), "Level", g.c_str(), 0, 10, levels[v]);
			info[pidx(v, PAN)] = pf((k + ".pan").c_str(), "Pan", g.c_str(), -1, 1, pans[v]);
		}
		info[M_DRIVE] = pf("master.drive", "Drive", "Master", 0, 10, 2);
		info[M_SWEEP] = pf("master.kick_sweep", "Kick Pitch Sweep", "Master", 0, 10, 5);
		info[M_CHOKE] = pb("master.hat_choke", "Closed Hat Chokes Open", "Master", true);
		info[M_VOLUME] = pf("master.volume", "Volume", "Master", 0, 10, 7);
		finish_params();
	}
	const char *type_name() const override { return "Pulsar"; }

	void prepare(float p_sr) override {
		sr = p_sr;
		for (Drum &x : d) {
			x.amp.init(sr);
			x.amp2.init(sr);
			x.pitch.init(sr);
			x.noise.init(sr);
			x.f1.init(sr);
			x.f2.init(sr);
		}
		dc_l.init(sr);
		dc_r.init(sr);
	}

	static int voice_for_note(int note) {
		switch (note) {
			case 35: case 36: return KICK;
			case 37: case 38: case 40: return SNARE;
			case 39: return CLAP;
			case 42: case 44: return CHAT;
			case 46: return OHAT;
			case 41: case 43: case 45: return LTOM;
			case 47: case 48: case 50: return HTOM;
			case 49: case 51: case 52: case 55: case 57: case 59: return CYMBAL;
			default: break;
		}
		// Anything else: map by pitch class so a plain keyboard plays all voices from C.
		return ((note % 12) + 12) % 12 < NV ? ((note % 12) + 12) % 12 : -1;
	}

	void note_on(int note, float vel) override {
		const int v = voice_for_note(note);
		if (v < 0) return;
		trigger(v, vel);
	}
	void note_off(int) override {}
	void all_notes_off() override {
		for (Drum &x : d) x.on = false;
	}

	void trigger(int v, float vel) {
		Drum &x = d[v];
		x.on = true;
		x.t = 0.0f;
		x.vel = vel;
		const float dec = std::pow(2.0f, (vp(v, DECAY) - 5.0f) * 0.4f); // 0.25x..4x
		switch (v) {
			case KICK:
				x.phase = 0.25f; // start at a peak for punch
				x.amp.trigger(1.0f, 0.45f * dec);
				x.pitch.trigger(1.0f, 0.045f + 0.03f * (vp(v, TONE) * 0.1f));
				x.noise.trigger(1.0f, 0.004f);
				break;
			case SNARE:
				x.amp.trigger(1.0f, 0.12f * dec);
				x.noise.trigger(1.0f, 0.22f * dec);
				x.pitch.trigger(1.0f, 0.02f);
				break;
			case CLAP:
				x.amp.trigger(1.0f, 0.18f * dec);
				x.noise.trigger(1.0f, 0.012f);
				break;
			case CHAT:
				x.amp.trigger(1.0f, 0.06f * dec);
				if (p(M_CHOKE) > 0.5f) d[OHAT].on = false;
				break;
			case OHAT:
				x.amp.trigger(1.0f, 0.5f * dec);
				break;
			case LTOM:
			case HTOM:
				x.amp.trigger(1.0f, 0.4f * dec);
				x.pitch.trigger(1.0f, 0.08f);
				x.noise.trigger(1.0f, 0.01f);
				break;
			case CYMBAL:
				x.amp.trigger(1.0f, 1.8f * dec);
				x.amp2.trigger(1.0f, 0.15f * dec);
				break;
		}
	}

	// Six detuned square waves at inharmonic ratios: the classic metallic source.
	inline float metal(Drum &x, float base) {
		static const float ratios[6] = { 1.0f, 1.4471f, 1.6170f, 1.9265f, 2.5028f, 2.6637f };
		float s = 0.0f;
		for (int k = 0; k < 6; k++) {
			x.metal_phase[k] += base * ratios[k] / sr;
			if (x.metal_phase[k] >= 1.0f) x.metal_phase[k] -= 1.0f;
			s += x.metal_phase[k] < 0.5f ? 1.0f : -1.0f;
		}
		return s * (1.0f / 6.0f);
	}

	inline float render_voice(int v) {
		Drum &x = d[v];
		const float tune = std::exp2(vp(v, TUNE) / 12.0f);
		const float tone = vp(v, TONE) * 0.1f;
		const float snap = vp(v, SNAP) * 0.1f;
		float out = 0.0f;
		switch (v) {
			case KICK: {
				const float sweep = p(M_SWEEP) * 0.1f;
				const float f = 48.0f * tune * (1.0f + sweep * 5.0f * x.pitch.process());
				x.phase += f / sr;
				if (x.phase >= 1.0f) x.phase -= 1.0f;
				float body = std::sin(TWO_PI * x.phase) * x.amp.process();
				body = fast_tanh(body * (1.0f + tone * 3.0f)) * 0.9f;
				const float click = rng.white() * x.noise.process() * snap * 0.8f;
				out = body + click;
				if (!x.amp.active()) x.on = false;
			} break;
			case SNARE: {
				const float pe = x.pitch.process();
				const float f1 = 185.0f * tune * (1.0f + 0.5f * pe), f2 = 330.0f * tune * (1.0f + 0.3f * pe);
				x.phase += f1 / sr;
				x.phase2 += f2 / sr;
				if (x.phase >= 1.0f) x.phase -= 1.0f;
				if (x.phase2 >= 1.0f) x.phase2 -= 1.0f;
				const float body = (std::sin(TWO_PI * x.phase) + 0.6f * std::sin(TWO_PI * x.phase2)) * 0.5f * x.amp.process();
				x.f1.process(rng.white(), 1500.0f + tone * 7000.0f, 0.1f);
				const float nz = (x.f1.hp + 0.4f * x.f1.bp) * x.noise.process();
				out = body * (1.0f - 0.5f * snap) + nz * (0.3f + snap * 0.9f);
				if (!x.amp.active() && !x.noise.active()) x.on = false;
			} break;
			case CLAP: {
				// Three quick bursts, then the tail. Spread widens the gaps.
				const float gap = 0.008f + snap * 0.008f;
				float burst = 0.0f;
				for (int k = 0; k < 3; k++) {
					const float tk = x.t - k * gap;
					if (tk >= 0.0f && tk < gap) burst = std::max(burst, std::exp(-tk / 0.0025f));
				}
				const float tail_t = x.t - 3.0f * gap;
				const float tail = tail_t > 0.0f ? x.amp.process() : 0.0f;
				x.f1.process(rng.white(), 900.0f + tone * 1600.0f, 0.45f);
				out = x.f1.bp * (burst + tail * 0.8f) * 1.6f;
				if (tail_t > 0.0f && !x.amp.active()) x.on = false;
			} break;
			case CHAT:
			case OHAT: {
				const float m = metal(x, 400.0f * tune) * 0.7f + rng.white() * 0.3f * (0.5f + snap);
				x.f1.process(m, 9000.0f + tone * 4000.0f, 0.3f);
				x.f2.process(x.f1.bp, 6000.0f + tone * 4000.0f, 0.0f);
				out = x.f2.hp * x.amp.process() * 1.4f;
				if (!x.amp.active()) x.on = false;
			} break;
			case LTOM:
			case HTOM: {
				const float base = (v == LTOM ? 95.0f : 150.0f) * tune;
				const float f = base * (1.0f + 0.35f * x.pitch.process());
				x.phase += f / sr;
				if (x.phase >= 1.0f) x.phase -= 1.0f;
				const float body = std::sin(TWO_PI * x.phase) * x.amp.process();
				x.f1.process(rng.white(), 400.0f + tone * 3000.0f, 0.2f);
				out = fast_tanh(body * (1.0f + tone)) * 0.9f + x.f1.bp * x.noise.process() * snap;
				if (!x.amp.active()) x.on = false;
			} break;
			case CYMBAL: {
				const float m = metal(x, 300.0f * tune) * 0.6f + rng.white() * 0.4f;
				x.f1.process(m, 6500.0f + tone * 5000.0f, 0.15f);
				x.f2.process(x.f1.bp, 4000.0f + tone * 3000.0f, 0.0f);
				out = x.f2.hp * (x.amp.process() * 0.7f + x.amp2.process() * 0.5f * snap) * 1.4f;
				if (!x.amp.active()) x.on = false;
			} break;
		}
		x.t += 1.0f / sr;
		return out * x.vel * vp(v, LEVEL) * 0.1f;
	}

	void render(float *l, float *r, int n) override {
		float gl[NV], gr[NV];
		bool any = false;
		for (int v = 0; v < NV; v++) {
			const float a = (vp(v, PAN) + 1.0f) * 0.25f * PI;
			gl[v] = std::cos(a) * 1.414f;
			gr[v] = std::sin(a) * 1.414f;
			any = any || d[v].on;
		}
		if (!any) return;
		const float drv = p(M_DRIVE) * 0.1f;
		const float vol = p(M_VOLUME) * 0.1f * 0.7f;
		for (int i = 0; i < n; i++) {
			float sl = 0.0f, srr = 0.0f;
			for (int v = 0; v < NV; v++) {
				if (!d[v].on) continue;
				const float s = render_voice(v);
				sl += s * gl[v];
				srr += s * gr[v];
			}
			l[i] += drive(dc_l.process(sl * vol), drv);
			r[i] += drive(dc_r.process(srr * vol), drv);
		}
	}
};

Instrument *make_pulsar() { return new Pulsar(); }

} // namespace jam
