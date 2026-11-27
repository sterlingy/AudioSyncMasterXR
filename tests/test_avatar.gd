extends GutTest
## Avatar poses: packing, interpolation and the delay that lines them up with sound.


func _pose(x: float, yaw := 0.0) -> Dictionary:
	return {"head": Transform3D(Basis(Vector3.UP, yaw), Vector3(x, 1.6, 0)),
		"left": Transform3D(Basis.IDENTITY, Vector3(x - 0.3, 1.0, -0.3)),
		"right": Transform3D(Basis.IDENTITY, Vector3(x + 0.3, 1.0, -0.3))}


func test_pack_round_trip() -> void:
	var p := _pose(0.5, 0.7)
	var f := PoseBuffer.pack(p)
	assert_eq(f.size(), PoseBuffer.FLOATS)
	var back := PoseBuffer.unpack(f)
	for part in PoseBuffer.PARTS:
		assert_true((back[part] as Transform3D).is_equal_approx(p[part]), part)
	assert_eq(PoseBuffer.unpack(PackedFloat32Array([1, 2, 3])), {}, "wrong size is ignored")


func test_sample_interpolates_and_holds_at_the_ends() -> void:
	var b := PoseBuffer.new()
	assert_eq(b.sample(1.0), {})
	b.add(10.0, PoseBuffer.pack(_pose(0.0, 0.0)))
	b.add(10.1, PoseBuffer.pack(_pose(1.0, 1.0)))
	var mid := b.sample(10.05)
	assert_almost_eq(mid.head.origin.x, 0.5, 1e-4)
	assert_almost_eq(mid.head.basis.get_euler().y, 0.5, 1e-3, "rotation interpolates too")
	assert_almost_eq(b.sample(5.0).head.origin.x, 0.0, 1e-6, "before the first pose: held")
	assert_almost_eq(b.sample(10.15).head.origin.x, 1.5, 1e-3, "just past the last pose: carries on")
	assert_almost_eq(b.sample(20.0).head.origin.x, 2.0, 1e-3, "then holds after %.0f ms" % (PoseBuffer.MAX_AHEAD * 1000.0))


func test_out_of_order_and_old_poses() -> void:
	var b := PoseBuffer.new()
	b.add(1.0, PoseBuffer.pack(_pose(1.0)))
	b.add(3.0, PoseBuffer.pack(_pose(3.0)))
	b.add(2.0, PoseBuffer.pack(_pose(2.0))) # arrived late
	b.add(2.0, PoseBuffer.pack(_pose(9.0))) # duplicate stamp: ignored
	assert_eq(b.size(), 3)
	assert_almost_eq(b.sample(2.5).head.origin.x, 2.5, 1e-4)
	b.add(30.0, PoseBuffer.pack(_pose(30.0)))
	assert_lt(b.size(), 4, "history beyond %.0f s is dropped" % PoseBuffer.KEEP)


func test_avatar_delay_follows_what_you_hear() -> void:
	var out_lat := AudioServer.get_output_latency()
	var was_interval := Session.interval_bars
	var notes_only := {"rig": null, "delay": 0.009, "last_late": 0.004, "native": {"note_delay_ms": 9.0, "last_late_ms": 4.0}}
	assert_almost_eq(Session.avatar_delay(notes_only), 0.009 + out_lat, 1e-9, "virtual instrument: note delay")
	var streaming := {"rig": null, "native": {"streaming": true, "audio_delay_ms": 24.0, "note_delay_ms": 9.0}}
	assert_almost_eq(Session.avatar_delay(streaming), 0.024 + out_lat, 1e-9, "voice / real instrument: audio delay")
	Session.interval_bars = 1
	assert_almost_eq(Session.avatar_delay(notes_only), Session.interval_seconds(), 1e-9, "interval mode: one interval")
	Session.interval_bars = was_interval


func test_every_instrument_has_a_3d_model() -> void:
	for t in JamSynth.get_instrument_types():
		if t == "Metronome" or t == "Clips" or t == "Sampler": # Sampler isn't offered here yet (see main.gd)
			continue
		var m := InstrumentModels.instantiate(t)
		assert_not_null(m, "%s has a model" % t)
		if m:
			assert_gt(m.find_children("*", "MeshInstance3D", true, false).size(), 3, "%s model has meshes" % t)
			m.free()


func test_wrist_button_shows_when_palm_faces_you() -> void:
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)) # looking down -Z
	# Wrist in front of you and below, palm (+Z) turned up toward your eyes.
	var at := Vector3(0, 1.2, -0.35)
	var to_eyes := (head.origin - at).normalized()
	var palm_up := Basis.looking_at(-to_eyes, Vector3.FORWARD) # +Z toward the eyes
	assert_true(WristButton.palm_faces(Transform3D(palm_up, at), head))
	var palm_down := Basis.looking_at(to_eyes, Vector3.FORWARD) # back of the hand toward you
	assert_false(WristButton.palm_faces(Transform3D(palm_down, at), head))
	# Palm toward you, but the wrist is behind you: not shown.
	assert_false(WristButton.palm_faces(Transform3D(palm_up, Vector3(0, 1.2, 0.5)), head))
