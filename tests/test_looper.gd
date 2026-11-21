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
