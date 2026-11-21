extends GutTest
## Engine tests for the jamcore GDExtension (JamSynth and all instruments).
## Run: godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit

const SR := 48000
const ALL := ["Pulsar", "Undertow", "Comet", "Lumen", "Driftwood", "Tangle"]


func make(type: String, params := {}) -> JamSynth:
	var s := JamSynth.new()
	s.instrument = type
	if not params.is_empty():
		s.set_params(params)
	return s


func expected_hz(note: int) -> float:
	return 440.0 * pow(2.0, (note - 69) / 12.0)


func test_all_instruments_registered() -> void:
	var types := JamSynth.get_instrument_types()
	for t in ALL:
		assert_has(types, t)


func test_param_tables_are_well_formed() -> void:
	for t in ALL:
		var s := make(t)
		var seen := {}
		for p in s.get_param_list():
			assert_false(seen.has(p.id), "%s: duplicate param id %s" % [t, p.id])
			seen[p.id] = true
			assert_true(p.min <= p.default and p.default <= p.max, "%s.%s default out of range" % [t, p.id])
			if p.type == "enum":
				assert_eq(p.options.size(), int(p.max) + 1, "%s.%s enum size" % [t, p.id])
			assert_ne(p.group, "", "%s.%s has no panel group" % [t, p.id])


func test_set_param_clamps_and_rounds() -> void:
	var s := make("Undertow")
	s.set_param("filter.emphasis", 99.0)
	assert_eq(s.get_param("filter.emphasis"), 10.0)
	s.set_param("osc1.range", 2.6)
	assert_eq(s.get_param("osc1.range"), 3.0)
	s.set_param("osc1.wave", -4.0)
	assert_eq(s.get_param("osc1.wave"), 0.0)


func test_silent_when_idle() -> void:
	for t in ALL:
		var st := AudioUtil.stats(make(t).render_offline(4800))
		assert_almost_eq(st.peak, 0.0, 1e-6, "%s should be silent with no notes" % t)


func test_every_instrument_sounds_and_stays_finite() -> void:
	for t in ALL:
		var s := make(t)
		var note := 36 if t == "Pulsar" else 60
		s.note_on(note, 1.0)
		var b := s.render_offline(SR / 2)
		s.note_off(note)
		b.append_array(s.render_offline(SR))
		var st := AudioUtil.stats(b)
		assert_eq(st.bad, 0, "%s produced NaN/inf" % t)
		assert_gt(st.peak, 0.05, "%s too quiet (peak %.3f)" % [t, st.peak])
		assert_lt(st.peak, 1.0, "%s clips (peak %.3f)" % [t, st.peak])


func test_pitch_accuracy() -> void:
	var cases := [
		["Undertow", {"osc1.range": 3, "mix.osc2_on": 0, "mix.osc3_on": 0, "filter.cutoff": 18000, "filter.emphasis": 0, "filter.contour": 0}],
		["Comet", {"delay.on": 0, "osc2.level": 0}],
		["Lumen", {"osc2.level": 0, "chorus.on": 0, "reverb.mix": 0, "mix.drift": 0}],
		["Driftwood", {"model.type": 0, "reverb.mix": 0, "body.amount": 0}],
		["Driftwood", {"model.type": 1, "reverb.mix": 0, "body.amount": 0}],
	]
	for c in cases:
		for note in [45, 57, 69]:
			var s := make(c[0], c[1])
			s.note_on(note, 1.0)
			var hz := AudioUtil.pitch_hz(s.render_offline(SR / 2), SR, 2400, 8192, 60, 2000)
			var want := expected_hz(note)
			assert_almost_eq(hz, want, want * 0.015, "%s %s note %d" % [c[0], c[1], note])


func test_undertow_ladder_self_oscillates() -> void:
	var s := make("Undertow", {"mix.osc1_on": 0, "mix.osc2_on": 0, "mix.osc3_on": 0, "filter.emphasis": 10,
		"filter.cutoff": 440, "filter.contour": 0, "filter.velocity": 0, "filter.keytrack": 0})
	s.note_on(57, 1.0)
	var b := s.render_offline(SR)
	var st := AudioUtil.stats(b)
	assert_gt(st.rms, 0.01, "full emphasis should ring with no oscillators")
	assert_almost_eq(AudioUtil.pitch_hz(b, SR, SR / 2, 8192, 60, 2000), 440.0, 25.0)


func test_events_are_sample_accurate() -> void:
	var s := make("Pulsar")
	s.note_on(36, 1.0, 1000)
	var b := s.render_offline(2000)
	var first := -1
	for i in b.size():
		if absf(b[i].x) > 1e-5:
			first = i
			break
	assert_between(first, 1000, 1002, "kick should start exactly at frame 1000 (got %d)" % first)


func test_lumen_is_polyphonic_and_sustain_holds() -> void:
	var s := make("Lumen", {"aenv.release": 0.01, "reverb.mix": 0, "chorus.on": 0})
	s.control_change(64, 1.0)
	for n in [60, 64, 67]:
		s.note_on(n, 1.0)
	s.render_offline(SR / 4)
	for n in [60, 64, 67]:
		s.note_off(n)
	var held := AudioUtil.stats(s.render_offline(SR / 4))
	assert_gt(held.rms, 0.01, "sustain pedal should keep notes sounding")
	s.control_change(64, 0.0)
	s.render_offline(SR / 4)
	var after := AudioUtil.stats(s.render_offline(SR / 4))
	assert_lt(after.rms, 0.001, "releasing the pedal should end the notes")


func test_all_notes_off_silences() -> void:
	for t in ["Undertow", "Comet", "Lumen", "Tangle"]:
		var s := make(t, {"delay.on": 0, "reverb.mix": 0})
		s.note_on(60, 1.0)
		s.render_offline(SR / 4)
		s.all_notes_off()
		s.render_offline(SR * 2)
		var st := AudioUtil.stats(s.render_offline(SR / 4))
		assert_lt(st.peak, 0.01, "%s should go quiet after all_notes_off" % t)


func test_pulsar_voices_all_audible() -> void:
	for note in [36, 38, 39, 42, 46, 45, 50, 49]:
		var s := make("Pulsar")
		s.note_on(note, 1.0)
		var st := AudioUtil.stats(s.render_offline(SR / 2))
		assert_gt(st.peak, 0.02, "drum note %d" % note)


func test_tangle_rejects_bad_connections() -> void:
	var s := make("Tangle")
	s.tangle_clear()
	var vco := s.tangle_add_module("vco")
	var out := s.tangle_add_module("output")
	assert_false(s.tangle_connect(vco, "nope", out, "l"))
	assert_false(s.tangle_connect(vco, "saw", out, "nope"))
	assert_false(s.tangle_connect(vco, "saw", 31, "l"))
	assert_true(s.tangle_connect(vco, "saw", out, "l"))
	assert_eq(s.tangle_add_module("not_a_module"), -1)


func test_tangle_patch_roundtrip_is_deterministic() -> void:
	var a := make("Tangle")
	a.tangle_clear()
	var clk := a.tangle_add_module("clock")
	var seq := a.tangle_add_module("seq")
	var vco := a.tangle_add_module("vco")
	var out := a.tangle_add_module("output")
	a.tangle_connect(clk, "8", seq, "clock")
	a.tangle_connect(seq, "pitch", vco, "pitch")
	a.tangle_connect(vco, "saw", out, "l")
	var saved := a.get_params()
	var b1 := make("Tangle", saved).render_offline(SR)
	var b2 := make("Tangle", saved).render_offline(SR)
	var d := 0.0
	for i in b1.size():
		d = maxf(d, absf(b1[i].x - b2[i].x))
	assert_eq(d, 0.0)
	assert_gt(AudioUtil.stats(b1).rms, 0.05)


func test_tangle_module_cap() -> void:
	var s := make("Tangle")
	s.tangle_clear()
	var ok := 0
	for i in 40:
		if s.tangle_add_module("util") >= 0:
			ok += 1
	assert_eq(ok, 32)


func test_tempo_changes_synced_delay() -> void:
	# Comet's delay follows tempo: at 60 BPM a 1/4 echo lands 1 s after the note.
	var s := make("Comet", {"delay.division": 1, "delay.mix": 10, "delay.feedback": 0, "delay.pingpong": 0,
		"aenv.attack": 0.001, "aenv.decay": 0.02, "aenv.sustain": 0, "aenv.release": 0.01})
	s.tempo = 60.0
	s.note_on(60, 1.0)
	s.render_offline(480)
	s.note_off(60)
	var b := s.render_offline(SR * 2)
	var early := AudioUtil.stats(b.slice(SR / 2, SR - 2000))
	var echo := AudioUtil.stats(b.slice(SR - 2000, SR + 4000))
	assert_lt(early.peak, 0.01)
	assert_gt(echo.peak, 0.05)


func test_cpu_cost_is_small() -> void:
	# Release-mode targets are tighter; this just guards against regressions.
	for t in ALL:
		var s := make(t)
		for n in [48, 52, 55, 59, 62, 64, 67, 71]:
			s.note_on(n, 0.8)
		var t0 := Time.get_ticks_usec()
		s.render_offline(SR)
		var secs := float(Time.get_ticks_usec() - t0) / 1e6
		assert_lt(secs, 0.1, "%s takes %.1f%% of a core" % [t, secs * 100.0])
