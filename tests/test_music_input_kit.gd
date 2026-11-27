extends GutTest
## MusicInputKit (addons/music_input_kit submodule) loads here and sends notes.
## It isn't wired into the app yet; this only checks the submodule works.

func test_kit_sends_notes() -> void:
	var kit := MusicInput.new()
	add_child_autofree(kit)
	var got := []
	kit.note_on.connect(func(part, _voice, note, vel): got.append([part, note, vel]))
	var voice := kit.start_note("keys", 60.0, 0.8, false)
	assert_eq(got.size(), 1, "note_on sent")
	if got.size() == 1:
		assert_eq(got[0][0], "keys")
		assert_eq(got[0][1], 60)
	var offs := []
	kit.note_off.connect(func(_part, _voice, note): offs.append(note))
	kit.end_note(voice)
	assert_eq(offs, [60], "note_off sent")


func test_objects_load() -> void:
	for cls in [ChimeBars, LightStrings, ThereminOrb, PitchRibbon, DrumPads, ChordBlocks, MusicBoxWheel,
			TwistDial, SlideFader, XYPad, Flywheel, TiltCube, ScaleSwitch, PlayPointer, PlayXRHands]:
		var o: Node = cls.new()
		assert_not_null(o)
		o.free()
