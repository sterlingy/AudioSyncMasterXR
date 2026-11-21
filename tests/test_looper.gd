extends GutTest
## Personal and master looper: recording, quantize, playback timing, undo.

const SR := 48000
const T0 := 100.0


func before_each() -> void:
	Transport.stop()
	Transport.bpm = 120.0
	Transport.beats_per_bar = 4
	Transport.set_quantize(true, 0.25, false)
	Transport.running = true
	Transport.anchor_time = T0
	Transport.anchor_beat = 0.0
	Transport._scheduled_until = 0.0


func after_each() -> void:
	Transport.running = false
	MasterLooper.clear_all()


func make_rig(type := "Pulsar") -> InstrumentRig:
	var rig := InstrumentRig.new()
	rig.synth.instrument = type
	rig.synth.set_clock_anchor(T0, 0)
	return rig


func recorded_looper(rig: InstrumentRig) -> Looper:
	var lp := Looper.new(rig)
	var s := lp.slot()
	s.bars = 1
	s.start = 0.0
	s.rec_start = 0.0
	s.state = Looper.State.RECORDING
	# Played slightly off the grid; should snap to beats 0, 1, 2, 3.
	for b in [0.03, 0.98, 2.04, 2.97]:
		lp.capture({"type": "on", "note": 36, "velocity": 1.0, "beat": b})
		lp.capture({"type": "off", "note": 36, "beat": b + 0.1})
	lp._finish_layer(s)
	return lp


func onsets(buf: PackedVector2Array, threshold := 0.05, gap := 2000) -> Array:
	var out := []
	var last := -gap
	for i in buf.size():
		if absf(buf[i].x) > threshold:
			if i - last >= gap:
				out.append(i)
			last = i
	return out


func test_recording_quantizes_and_keeps_lengths() -> void:
	var rig := make_rig()
	var lp := recorded_looper(rig)
	var layer: Array = lp.slot().layers[0]
	var ons := layer.filter(func(e): return e.on).map(func(e): return e.b)
	assert_eq(ons, [0.0, 1.0, 2.0, 3.0])
	# Note-offs move with their note-ons, so the 0.1-beat length is kept.
	var offs := layer.filter(func(e): return not e.on).map(func(e): return snappedf(e.b, 0.001))
	assert_eq(offs, [0.1, 1.1, 2.1, 3.1])
	assert_eq(lp.slot().state, Looper.State.PLAYING)
	rig.free()


func test_loop_repeats_at_exact_frames() -> void:
	var rig := make_rig()
	var lp := recorded_looper(rig)
	lp.schedule(0.0, 8.0) # two passes of a 1-bar loop
	var b := rig.synth.render_offline(SR * 4)
	var on := onsets(b)
	assert_eq(on.size(), 8, "%s" % [on])
	var lat := int(round(AudioServer.get_output_latency() * SR))
	for k in on.size():
		assert_almost_eq(float(on[k]), k * SR / 2.0 - lat, 3.0)
	rig.free()


func test_overdub_layers_and_undo() -> void:
	var rig := make_rig()
	var lp := recorded_looper(rig)
	var s := lp.slot()
	s.rec_start = 4.0
	s.state = Looper.State.OVERDUBBING
	lp.capture({"type": "on", "note": 38, "velocity": 1.0, "beat": 5.0})
	lp.capture({"type": "off", "note": 38, "beat": 5.2})
	lp._finish_layer(s)
	assert_eq(s.layers.size(), 2)
	lp.undo()
	assert_eq(s.layers.size(), 1)
	lp.undo()
	assert_eq(s.state, Looper.State.EMPTY)
	rig.free()


func test_held_note_is_closed_at_loop_end() -> void:
	var rig := make_rig("Lumen")
	var lp := Looper.new(rig)
	var s := lp.slot()
	s.bars = 1
	s.state = Looper.State.RECORDING
	lp.capture({"type": "on", "note": 60, "velocity": 1.0, "beat": 2.0})
	lp._finish_layer(s)
	var offs: Array = s.layers[0].filter(func(e): return not e.on)
	assert_eq(offs.size(), 1)
	assert_almost_eq(float(offs[0].b), 3.99, 0.001)
	rig.free()


func test_master_layer_plays_with_its_own_sound() -> void:
	var rig := make_rig()
	var lp := recorded_looper(rig)
	MasterLooper.audio_out = false
	var id := MasterLooper.add_layer(lp.export_slot(), "me")
	MasterLooper.audio_out = true
	assert_gt(id, 0)
	var layer: Dictionary = MasterLooper.layers[0]
	assert_eq(layer.instrument, "Pulsar")
	layer.synth.set_clock_anchor(T0, 0)
	MasterLooper.schedule(0.0, 4.0)
	var on := onsets(layer.synth.render_offline(SR * 2))
	assert_eq(on.size(), 4)
	rig.free()


func test_master_permissions_and_listen_modes() -> void:
	var rig := make_rig()
	var lp := recorded_looper(rig)
	var mine := MasterLooper.add_layer(lp.export_slot(), "me")
	var theirs := MasterLooper.add_layer(lp.export_slot(), "sam")
	MasterLooper.is_host = false
	assert_false(MasterLooper.remove_layer(theirs), "can't delete someone else's layer")
	assert_true(MasterLooper.remove_layer(mine))
	MasterLooper.is_host = true
	MasterLooper.set_listen(MasterLooper.Listen.OWN_ONLY)
	assert_false(MasterLooper._audible(MasterLooper.layers[0]), "other players' layers are silent in Own Only")
	MasterLooper.set_listen(MasterLooper.Listen.MASTER_AND_LIVE)
	assert_true(MasterLooper._audible(MasterLooper.layers[0]))
	rig.free()


func click_clip(n := 24000, at := 0) -> PackedFloat32Array:
	var c := PackedFloat32Array()
	c.resize(n)
	for i in 64:
		c[at + i] = 0.8
	return c


func test_clip_plays_at_its_frame_and_offset() -> void:
	var s := JamSynth.new()
	s.instrument = "Clips"
	s.set_clock_anchor(T0, 0)
	assert_true(s.clip_set(3, click_clip(4800, 1000), SR))
	s.clip_play(3, 1.0, 10000, 0)
	s.clip_play(3, 1.0, 30000, 500) # starts 500 samples in: click 500 earlier
	var on := onsets(s.render_offline(SR))
	assert_eq(on.size(), 2, "%s" % [on])
	assert_almost_eq(float(on[0]), 11000.0, 1.0)
	assert_almost_eq(float(on[1]), 30500.0, 1.0)


func test_audio_loop_repeats_at_exact_frames() -> void:
	var rig := make_rig()
	var lp := Looper.new(rig)
	rig.clip_synth().set_clock_anchor(T0, 0)
	var s := lp.slot()
	s.kind = "audio"
	s.bars = 1
	s.start = 0.0
	s.state = Looper.State.PLAYING
	var id := lp.add_clip(click_clip(SR * 2, 200), SR)
	s.layers = [{"clip": id, "at": 0.0}, {"clip": lp.add_clip(click_clip(SR * 2, 200), SR), "at": 2.0}]
	lp.schedule(0.0, 8.0)
	var on := onsets(rig.clip_synth().render_offline(SR * 4))
	var lat := int(round(AudioServer.get_output_latency() * SR))
	# Layer 1 at every bar (0 s, 2 s), layer 2 recorded from beat 2 (1 s, 3 s).
	assert_eq(on.size(), 4, "%s" % [on])
	for k in on.size():
		assert_almost_eq(float(on[k]), k * SR - lat + 200.0, 2.0)
	var net := lp.to_net()
	assert_eq(net[0].kind, "audio")
	assert_eq(net[0].layers[0].clip, id)
	rig.free()


func test_recorder_cuts_input_at_the_right_time() -> void:
	if not ClassDB.class_exists("JamAudioLink"):
		pass_test("jamcore built without AOO")
		return
	var a: Object = ClassDB.instantiate("JamAudioLink")
	assert_eq(a.start(0, 1), OK)
	# 0.5 s of input with a click 0.2 s before the newest sample.
	var buf := PackedVector2Array()
	buf.resize(SR / 2)
	for i in 64:
		buf[SR / 2 - SR / 5 + i] = Vector2(0.9, 0.9)
	a.push_input(buf, SR)
	var t_click: float = a.get_input_time() - 0.2
	var d: Dictionary = a.get_input_audio(t_click - 0.05, t_click + 0.05)
	assert_true(d.complete)
	var samples: PackedFloat32Array = d.samples
	var first := -1
	for i in samples.size():
		if samples[i] > 0.5:
			first = i
			break
	assert_almost_eq(float(first), 0.05 * SR, 2.0)
	a.stop()


func test_master_audio_layer_plays_clips() -> void:
	MasterLooper.audio_out = false
	var id := MasterLooper.add_layer({"bars": 1, "kind": "audio", "instrument": "Clips", "params": {}, "events": [],
		"clips": [{"samples": click_clip(SR, 200), "rate": SR, "at": 1.0}]}, "me")
	MasterLooper.audio_out = true
	assert_gt(id, 0)
	var l: Dictionary = MasterLooper.layers[0]
	assert_eq(l.kind, "audio")
	l.synth.set_clock_anchor(T0, 0)
	MasterLooper.schedule(0.0, 8.0)
	var on := onsets(l.synth.render_offline(SR * 4))
	var lat := int(round(AudioServer.get_output_latency() * SR))
	assert_eq(on.size(), 2, "%s" % [on])
	assert_almost_eq(float(on[0]), SR / 2.0 - lat + 200.0, 2.0)
