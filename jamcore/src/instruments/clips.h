// Clips: plays recorded audio clips (audio loops of real instruments, mics).
// Internal instrument, not offered to players. note_on(slot, gain) starts the
// clip in that slot from its first sample at the event's exact frame;
// note_off fades it out. EV_CUSTOM events carry the rest: value < 0 sets the
// clip in slot a (ptr = Clip*, or null to clear); value >= 0 plays slot a
// with that gain starting b samples in (a clip that arrives mid-pass).
// Replaced clips go back to the main thread on `dead` to be freed there.
#pragma once
#include "../engine/event_queue.h"
#include "../engine/instrument.h"
#include <vector>

namespace jam {

struct Clip {
	std::vector<float> data; // mono, at the engine's sample rate
};

class ClipPlayer : public Instrument {
public:
	static constexpr int SLOTS = 64;
	static constexpr int VOICES = 24;

	ClipPlayer();
	~ClipPlayer() override;
	const char *type_name() const override { return "Clips"; }
	void prepare(float p_sr) override { sr = p_sr; }
	void note_on(int slot, float velocity) override;
	void note_off(int slot) override;
	void all_notes_off() override;
	void custom_event(const Event &e) override;
	void render(float *l, float *r, int n) override;

	// Main thread: frees clips the audio thread replaced.
	void collect();
	void play(int slot, float gain, size_t offset);
	SpscQueue<Clip *, 128> dead;

private:
	struct Voice {
		int slot = -1;
		size_t pos = 0;
		float gain = 0.0f;
		float env = 1.0f;
		float step = 0.0f; // per-sample fade-out step while releasing
	};
	Clip *clips[SLOTS] = {};
	Voice voices[VOICES];
	int p_level = 0;
};

} // namespace jam
