extends GutTest
## Transport, metronome and sequencer timing, rendered offline with a fixed
## clock anchor (time 100 s = frame 0) so beat positions map to exact frames.

const SR := 48000
const T0 := 100.0


func before_each() -> void:
	Transport.stop()
	Transport.bpm = 120.0
	Transport.beats_per_bar = 4
	Transport.clock_offset = 0.0
	Transport.metronome_on = true
	Transport.set_quantize(true, 0.25, false)


func _run_transport(beat := 0.0) -> void:
	# Pretend the transport started at T0 with beat 0 there.
	Transport.running = true
	Transport.anchor_time = T0
	Transport.anchor_beat = beat
	Transport._scheduled_until = beat
	Transport._pending_bpm = 0.0


func onsets(buf: PackedVector2Array, threshold := 0.02, gap := 2000) -> Array:
	var out := []
	var last := -gap
	for i in buf.size():
		if absf(buf[i].x) > threshold and i - last >= gap:
			out.append(i)
			last = i
		if absf(buf[i].x) > threshold:
			last = i
	return out


func latency_frames() -> int:
	return int(round(AudioServer.get_output_latency() * SR))


func test_beat_time_conversion() -> void:
	_run_transport()
	assert_almost_eq(Transport.time_at(4.0), T0 + 2.0, 1e-9)
	assert_almost_eq(Transport.beat_at(T0 + 1.5), 3.0, 1e-9)


func test_metronome_clicks_on_beats() -> void:
	_run_transport()
	var click: JamSynth = Transport.click
	# The transport's own click player isn't rendered here; use a copy.
	var s := JamSynth.new()
	s.instrument = "Metronome"
	s.set_clock_anchor(T0, 0)
	Transport.click = s
	Transport.pump(T0 + 2.0) # 4 beats at 120 BPM
	Transport.click = click
	var b := s.render_offline(SR * 2)
	var on := onsets(b, 0.005)
	assert_eq(on.size(), 4, "four clicks in two seconds: %s" % [on])
	for k in on.size():
		assert_almost_eq(float(on[k]), k * SR / 2.0 - latency_frames(), 3.0)
	# Downbeat is the accented click (louder).
	var first: float = AudioUtil.stats(b.slice(on[0], on[0] + 2000)).peak
	var second: float = AudioUtil.stats(b.slice(on[1], on[1] + 2000)).peak
	assert_gt(first, second)


func test_sequencer_plays_steps_at_exact_frames() -> void:
	# A rig that isn't in the tree: no player, so the synth can render offline.
	var rig := InstrumentRig.new()
	rig.synth.instrument = "Pulsar"
	rig.synth.set_clock_anchor(T0, 0)
	var seq := StepSequencer.new(rig)
	seq.clear()
	seq.steps = 16
	seq.division = 0.25
	for i in [0, 4, 8, 12]:
		seq.set_note(i, 36, true, 1.0)
	_run_transport()
	seq.schedule(0.0, 4.0)
	var b := rig.synth.render_offline(SR * 2)
	var on := onsets(b, 0.05)
	assert_eq(on.size(), 4, "kicks: %s" % [on])
	for k in on.size():
		assert_almost_eq(float(on[k]), k * SR / 2.0 - latency_frames(), 3.0)
	rig.free()


func test_swing_delays_odd_steps() -> void:
	var seq := StepSequencer.new(null)
	seq.division = 0.25
	seq.swing = 0.5
	assert_almost_eq(seq.step_beat(0, 1), 0.25 + 0.125, 1e-9)
	assert_almost_eq(seq.step_beat(0, 2), 0.5, 1e-9)
	assert_almost_eq(seq.step_beat(1, 0), 4.0, 1e-9)


func test_tempo_change_waits_for_bar_line() -> void:
	_run_transport()
	Transport.pump(T0 + 0.5) # through beat 1
	Transport.set_tempo(60.0)
	assert_eq(Transport.bpm, 120.0, "not yet")
	Transport.pump(T0 + 2.5) # past beat 4 at the old tempo
	assert_eq(Transport.bpm, 60.0)
	assert_almost_eq(Transport.anchor_beat, 4.0, 1e-9)
	assert_almost_eq(Transport.anchor_time, T0 + 2.0, 1e-9)
	assert_almost_eq(Transport.time_at(5.0), T0 + 3.0, 1e-9)


func test_record_quantize() -> void:
	var seq := StepSequencer.new(null)
	seq.recording = true
	seq.record_note(60, 0.9, 1.11) # just after beat 1.0 + 1/16 (1.0 + 0.25*0 ...)
	assert_true(seq.has_note(4, 60), "1.11 beats rounds to step 4 (beat 1.0)")
	seq.record_note(62, 0.9, 1.2)
	assert_true(seq.has_note(5, 62), "1.2 beats rounds to step 5 (beat 1.25)")
	seq.record_note(64, 0.9, 3.97)
	assert_true(seq.has_note(0, 64), "end of the bar wraps to step 0")


func test_pattern_dict_roundtrip() -> void:
	var seq := StepSequencer.new(null)
	seq.from_dict(DefaultPatterns.for_instrument("Undertow"))
	var d := seq.to_dict()
	var seq2 := StepSequencer.new(null)
	seq2.from_dict(JSON.parse_string(JSON.stringify(d)))
	assert_eq(seq2.to_dict(), d)
	assert_true(seq2.pattern[11].slide)


func test_tangle_clock_follows_transport() -> void:
	var s := JamSynth.new()
	s.instrument = "Tangle"
	s.tangle_clear()
	var clk := s.tangle_add_module("clock")
	var out := s.tangle_add_module("output")
	s.tangle_connect(clk, "bar", out, "l")
	s.tangle_set_param(out, "mix", 0.0)
	s.tempo = 120.0
	# Say we're at beat 3 now: the bar pulse should rise one beat (24000 frames) later.
	s.set_clock_anchor(T0, 0)
	s.sync_transport(3.0, 0)
	var b := s.render_offline(SR)
	var first := -1
	for i in b.size():
		if b[i].x > 0.1:
			first = i
			break
	assert_almost_eq(float(first), 24000.0, 64.0)


func test_tap_tempo() -> void:
	Transport._taps.clear()
	assert_eq(Transport.tap(10.0), 0.0, "one tap sets nothing")
	Transport.tap(10.5)
	Transport.tap(11.0)
	assert_eq(Transport.tap(11.5), 120.0)
	assert_eq(Transport.bpm, 120.0)
	# A long pause starts over.
	assert_eq(Transport.tap(20.0), 0.0)
	assert_eq(Transport.tap(20.6), 100.0)
	Transport._taps.clear()


func test_tap_as_follower_asks_the_host() -> void:
	Transport._taps.clear()
	Transport.follower = true
	var asked := []
	var cb := func(action, value): asked.append([action, value])
	Transport.request.connect(cb)
	Transport.tap(5.0)
	Transport.tap(5.75)
	Transport.request.disconnect(cb)
	Transport.follower = false
	Transport._taps.clear()
	assert_eq(asked, [["tempo", 80.0]])
	assert_eq(Transport.bpm, 120.0, "a follower doesn't change tempo itself")


func test_click_volume() -> void:
	var was := Transport.click_volume_db
	Transport.click_volume_db = -12.0
	assert_eq(Transport.click_player.volume_db, -12.0)
	Transport.click_volume_db = was
