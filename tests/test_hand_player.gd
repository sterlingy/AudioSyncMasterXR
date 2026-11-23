extends GutTest
## Playing the 3D instruments with fingertips (simulated tips, no headset).

var root: Node3D
var hp: HandPlayer
var t := 0.0
var heard := [] # [note, velocity] from Midi.note_on
var cur := {} # fingertips currently reported (all of them go in every frame, like the headset)


func before_each() -> void:
	root = Node3D.new()
	add_child_autofree(root)
	hp = HandPlayer.new()
	root.add_child(hp)
	Midi.release_all()
	heard.clear()
	cur.clear()
	Midi.note_on.connect(_on_note)


func after_each() -> void:
	Midi.note_on.disconnect(_on_note)
	hp.release_all()
	Midi.release_all()


func _on_note(n: int, v: int) -> void:
	heard.append([n, v])


func _load(type: String) -> Node3D:
	var m := InstrumentModels.instantiate(type)
	m.position = Vector3(0.3, 0.8, -0.4) # anywhere: zones are in the model's own space
	m.rotation_degrees.y = 20
	root.add_child(m)
	hp.setup(m, type)
	return m


func _zone(note: int) -> Dictionary:
	for z in hp.zones:
		if z.note == note:
			return z
	return {}


## Moves one fingertip down onto the zone of `note` at `speed` m/s, in a few frames.
func _press(m: Node3D, note: int, id := "tip", speed := 0.5) -> void:
	var z := _zone(note)
	assert_false(z.is_empty(), "zone for note %d" % note)
	var c: Vector3 = (z.min + z.max) * 0.5
	for dy in [0.02, 0.01, 0.0, -0.01]:
		var local := Vector3(c.x, z.max.y + dy + HandPlayer.TIP_RADIUS, c.z)
		t += 0.01 / speed
		cur[id] = m.global_transform * local
		hp.update_tips(cur, t)


func _lift(m: Node3D, note: int, id := "tip") -> void:
	var z := _zone(note)
	var c: Vector3 = (z.min + z.max) * 0.5
	t += 0.02
	cur[id] = m.global_transform * Vector3(c.x, z.max.y + 0.03, c.z)
	hp.update_tips(cur, t)


func test_keyboard_zones_and_notes() -> void:
	var m := _load("Undertow")
	assert_eq(hp.zone_count(), 25, "2 octaves: 15 white + 10 black keys")
	_press(m, 36)
	assert_true(Midi.held.has(36), "first white key is C2 on Undertow")
	_lift(m, 36)
	assert_false(Midi.held.has(36), "lifting releases it")
	_press(m, 37)
	assert_true(Midi.held.has(37) and not Midi.held.has(36), "a black key wins over the white key under it")
	_lift(m, 37)


func test_chord_with_several_fingers() -> void:
	var m := _load("Lumen")
	for n in [60, 64, 67]:
		_press(m, n, "f%d" % n)
	assert_true(Midi.held.has(60) and Midi.held.has(64) and Midi.held.has(67), "three fingers, three notes")


func test_faster_is_louder() -> void:
	var m := _load("Comet")
	_press(m, 60, "a", 0.1)
	_lift(m, 60, "a")
	_press(m, 62, "a", 1.5)
	assert_eq(heard.size(), 2)
	assert_lt(heard[0][1], heard[1][1], "slow press quieter than fast press")


func test_resting_hand_below_does_not_play() -> void:
	var m := _load("Undertow")
	var z := _zone(40)
	var c: Vector3 = (z.min + z.max) * 0.5
	for dy in [-0.06, -0.07, -0.08]: # under the key, never crossing its top
		t += 0.02
		hp.update_tips({"x": m.global_transform * Vector3(c.x, z.max.y + dy, c.z)}, t)
	assert_true(heard.is_empty())


func test_pads_bars_and_strip() -> void:
	var m := _load("Pulsar")
	assert_eq(hp.zone_count(), 8)
	_press(m, 36)
	assert_true(Midi.held.has(36), "kick pad")
	hp.release_all()
	cur.clear()
	m = _load("Driftwood")
	assert_eq(hp.zone_count(), 16, "9 bars + 7 tines")
	_press(m, 60)
	assert_true(Midi.held.has(60), "lowest bar")
	hp.release_all()
	cur.clear()
	m = _load("Tangle")
	assert_eq(hp.zone_count(), 25, "Tangle gets a 2-octave key strip")
	_press(m, 48)
	assert_true(Midi.held.has(48))


func test_pressed_part_sinks_and_returns() -> void:
	var m := _load("Undertow")
	var z := _zone(36)
	var rest: Vector3 = z.node.position
	_press(m, 36)
	assert_lt(z.node.position.y, rest.y)
	_lift(m, 36)
	assert_eq(z.node.position, rest)


func test_pinch_and_turn_a_knob() -> void:
	var rig := InstrumentRig.new()
	rig.instrument = "Undertow"
	rig.local_input = false
	add_child_autofree(rig)
	hp.rig = rig
	var m := _load("Undertow")
	assert_eq(hp.knobs.size(), 18, "all 18 Undertow knobs control something")
	var k: Dictionary = hp.knobs[0]
	assert_eq(k.id, "filter.cutoff")
	var before := rig.synth.get_param("filter.cutoff")
	var at: Vector3 = m.global_transform * k.center
	hp.update_pinches({1: at})
	hp.update_pinches({1: at + m.global_basis.y * 0.05}) # moving up or down does nothing now
	assert_almost_eq(rig.synth.get_param("filter.cutoff"), before, 0.01)
	hp.update_pinches({1: at + m.global_basis.x * 0.06}) # half the travel to the right
	var after := rig.synth.get_param("filter.cutoff")
	assert_gt(after, before, "moving the pinch right turns cutoff up (%.0f -> %.0f)" % [before, after])
	assert_true(k.label.text.begins_with("Cutoff"), "label under the knob: " + k.label.text)
	assert_true(k.label.text.contains("Hz"), "label shows the value with its unit")
	hp.update_pinches({1: at + m.global_basis.x * -0.2}) # far left: bottom of the range
	assert_almost_eq(rig.synth.get_param("filter.cutoff"), float(k.min), 0.01)
	assert_ne(k.node.basis, k.rest, "the knob turned")
	hp.update_pinches({}) # let go
	var low := rig.synth.get_param("filter.cutoff")
	hp.update_pinches({1: at + Vector3(0.5, 0, 0)}) # a pinch far from any knob grabs nothing
	assert_eq(rig.synth.get_param("filter.cutoff"), low)
	assert_eq(model_labels(m), 18, "every knob has a label")


func model_labels(m: Node3D) -> int:
	return m.find_children("*_label", "Label3D", true, false).size()
