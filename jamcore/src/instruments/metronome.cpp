// Metronome click. Notes: 0 = beat, 1 = accent (downbeat), 2 = subdivision.
// Scheduled by the Transport against the shared clock, so every client clicks together.
#include "dsp/env.h"
#include "dsp/filters.h"
#include "engine/instrument.h"

namespace jam {

class Metronome : public Instrument {
	enum P { SOUND, ACCENT, SUBDIV_LEVEL, PITCH, VOLUME, COUNT };
	struct Click {
		DecayEnv env;
		float phase = 0.0f, freq = 1000.0f, level = 0.0f;
		Resonator body;
		int kind = 0;
	};
	Click clicks[4];
	int next = 0;
	Rng rng;

public:
	Metronome() {
		info.resize(COUNT);
		info[SOUND] = pe("click.sound", "Sound", "Metronome", { "Beep", "Woodblock", "Stick" }, 1);
		info[ACCENT] = pf("click.accent", "Accent Level", "Metronome", 0, 10, 10);
		info[SUBDIV_LEVEL] = pf("click.subdiv", "Subdivision Level", "Metronome", 0, 10, 4);
		info[PITCH] = pf("click.pitch", "Pitch", "Metronome", -12, 12, 0, "st");
		info[VOLUME] = pf("click.volume", "Volume", "Metronome", 0, 10, 7);
		finish_params();
	}
	const char *type_name() const override { return "Metronome"; }
	void prepare(float p_sr) override {
		sr = p_sr;
		for (Click &c : clicks) c.env.init(sr);
	}
	void note_on(int note, float vel) override {
		Click &c = clicks[next];
		next = (next + 1) & 3;
		const int sound = pi_(SOUND);
		const float pitch = std::exp2(p(PITCH) / 12.0f);
		const float base = sound == 0 ? 1000.0f : (sound == 1 ? 1700.0f : 2600.0f);
		c.kind = sound;
		c.freq = base * pitch * (note == 1 ? 1.5f : (note == 2 ? 0.8f : 1.0f));
		c.level = vel * (note == 1 ? p(ACCENT) * 0.1f : (note == 2 ? p(SUBDIV_LEVEL) * 0.1f : 0.7f));
		c.phase = 0.0f;
		c.env.trigger(1.0f, sound == 0 ? 0.06f : (sound == 1 ? 0.05f : 0.025f));
		c.body.reset();
		c.body.set_normalized(c.freq, sound == 2 ? 0.01f : 0.03f, sr);
	}
	void note_off(int) override {}
	void all_notes_off() override {
		for (Click &c : clicks) c.env.value = 0.0f;
	}
	void render(float *l, float *r, int n) override {
		const float vol = p(VOLUME) * 0.1f * 0.6f;
		for (Click &c : clicks) {
			if (!c.env.active()) continue;
			for (int i = 0; i < n; i++) {
				const float e = c.env.process();
				float s;
				if (c.kind == 0) {
					c.phase += c.freq / sr;
					if (c.phase >= 1.0f) c.phase -= 1.0f;
					s = std::sin(TWO_PI * c.phase) * e;
				} else {
					// Woodblock / stick: a struck resonator excited by a short noise burst.
					const float ex = (e > 0.6f ? rng.white() : 0.0f) * 0.3f;
					s = c.body.process(ex) * 4.0f * e;
				}
				const float out = s * c.level * vol;
				l[i] += out;
				r[i] += out;
			}
		}
	}
};

Instrument *make_metronome() { return new Metronome(); }

} // namespace jam
