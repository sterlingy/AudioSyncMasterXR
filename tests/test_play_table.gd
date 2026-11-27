extends GutTest
## The play table (MusicInputKit objects in XR) and KitBridge: kit notes, bends
## and knob moves reach your instrument the way the app's other inputs do.

var root: Node3D
var rig: InstrumentRig
var ons := [] # [note, velocity] from Midi.note_on
var offs := [] # notes from Midi.note_off
var bends := [] # values from Midi.pitch_bend


func before_each() -> void:
	root = Node3D.new()
	add_child_autofree(root)
	rig = InstrumentRig.new()
	rig.local_input = false # only what the bridge sets directly
	rig.instrument = "Lumen"
	root.add_child(rig)
	Midi.release_all()
	ons.clear(); offs.clear(); bends.clear()
	Midi.note_on.connect(_on)
	Midi.note_off.connect(_off)
	Midi.pitch_bend.connect(_bend)


func after_each() -> void:
	Midi.note_on.disconnect(_on)
	Midi.note_off.disconnect(_off)
	Midi.pitch_bend.disconnect(_bend)
	Midi.release_all()


func _on(n: int, v: int) -> void: ons.append([n, v])
func _off(n: int) -> void: offs.append(n)
func _bend(v: float) -> void: bends.append(v)


func _bridge() -> Array:
	var kit := MusicInput.new()
	root.add_child(kit)
	var b := KitBridge.new(kit)
	b.rig = rig
	root.add_child(b)
	return [kit, b]


func test_generic_knob_names_find_each_instruments_own() -> void:
	var prism := {"f1.cutoff": {}, "f1.resonance": {}, "send.space": {}, "send.echo": {}, "lfo1.vibrato": {}}
	assert_eq(KitBridge.resolve(prism, "filter.cutoff"), "f1.cutoff")
	assert_eq(KitBridge.resolve(prism, "filter.resonance"), "f1.resonance")
	assert_eq(KitBridge.resolve(prism, "reverb.mix"), "send.space")
	assert_eq(KitBridge.resolve(prism, "vibrato.depth"), "lfo1.vibrato")
	var undertow := {"filter.cutoff": {}, "filter.emphasis": {}}
	assert_eq(KitBridge.resolve(undertow, "filter.resonance"), "filter.emphasis")
	assert_eq(KitBridge.resolve(undertow, "reverb.mix"), "", "a knob the instrument lacks is skipped")
	assert_eq(KitBridge.resolve({"master.volume": {}}, "master.volume"), "master.volume", "own ids pass through")


func test_notes_reach_midi_and_two_hands_share_a_note() -> void:
	var kb := _bridge()
	var kit: MusicInput = kb[0]
	var a := kit.start_note("keys", 64.0, 1.0, false)
	var b := kit.start_note("lead", 64.0, 0.5, false) # the other hand, same note
	assert_eq(ons, [[64, 127], [64, 64]], "both hits play, velocity 0..1 -> 1..127")
	kit.end_note(a)
	assert_eq(offs, [], "still held by the other hand")
	kit.end_note(b)
	assert_eq(offs, [64])


func test_bend_uses_the_instruments_range_and_resets() -> void:
	rig.set_instrument("Comet")
	var kb := _bridge()
	var kit: MusicInput = kb[0]
	var bridge: KitBridge = kb[1]
	var range := bridge.bend_range()
	assert_gt(range, 0.0)
	kit.scale.enabled = false # chromatic: a slide bends instead of snapping to the scale
	var v := kit.start_note("lead", 60.0, 0.8, false)
	kit.move_note(v, 61.0)
	assert_gt(bends.size(), 0, "a slide bends")
	if bends.size() > 0:
		assert_almost_eq(bends[-1], clampf(1.0 / range, -1, 1), 0.02)
	kit.end_note(v)
	assert_eq(bends.back() if bends.size() > 0 else -1.0, 0.0, "back to no bend when the note ends")


func test_knobs_set_real_values_on_the_instrument() -> void:
	rig.set_instrument("Prism")
	var kb := _bridge()
	var kit: MusicInput = kb[0]
	var info := {}
	for p in rig.synth.get_param_list():
		info[p.id] = p
	kit.control.emit("keys", "filter.cutoff", 1.0)
	assert_almost_eq(float(rig.synth.get_param("f1.cutoff")), float(info["f1.cutoff"].max), 0.5, "top of the knob")
	kit.control.emit("keys", "filter.cutoff", 0.0)
	assert_almost_eq(float(rig.synth.get_param("f1.cutoff")), float(info["f1.cutoff"].min), 0.5, "bottom of the knob")
	rig.set_instrument("Pulsar")
	kit.control.emit("keys", "filter.cutoff", 0.5) # Pulsar has no filter: nothing happens
	assert_true(true)


func _table() -> PlayTable:
	var t := PlayTable.new()
	t.save_patches = false
	t.rig = rig
	root.add_child(t)
	return t


func test_table_has_every_object_and_leaves_the_sound_alone() -> void:
	var before: Dictionary = rig.synth.get_params()
	var t := _table()
	assert_eq(t.objects.size(), 14, "7 note objects, 6 shaping objects and the scale buttons")
	for n in ["Strings", "Orb", "MusicBox", "Bars", "Blocks", "Pads", "Ribbon", "Dial", "Fader", "Whammy", "XY", "Flywheel", "Tilt", "Scale"]:
		assert_true(t.objects.has(n), n)
	assert_eq(rig.synth.get_params(), before, "building the table doesn't change your instrument's knobs")
	assert_eq(ons, [], "and plays nothing")


func _hand(t: PlayTable) -> XRController3D:
	var c := XRController3D.new()
	c.name = "FakeHand"
	root.add_child(c)
	t.use_controllers([c])
	return c


## Moves a hand's touching tip to `world`, one frame.
func _tip_to(t: PlayTable, c: XRController3D, world: Vector3) -> void:
	c.global_position = world - t.hands.tip_offset
	t.hands.tick(1.0 / 60.0)


func test_hitting_a_chime_bar_plays_your_instrument() -> void:
	var t := _table()
	var c := _hand(t)
	var bars: Playable = t.objects["Bars"]
	var at := bars.to_global(bars.box.get_center())
	_tip_to(t, c, at + Vector3(0, 0.15, 0)) # above the table
	_tip_to(t, c, at + Vector3(0, 0.07, 0))
	_tip_to(t, c, at) # down onto a bar
	assert_eq(ons.size(), 1, "one hit, one note")
	_tip_to(t, c, at + Vector3(0, 0.2, 0))
	await get_tree().create_timer(0.9).timeout # a bar rings for note_length (0.6 s)
	assert_gt(offs.size(), 0, "the struck note ends")


func test_hidden_table_does_not_play() -> void:
	var t := _table()
	var c := _hand(t)
	t.set_shown(false)
	var bars: Playable = t.objects["Bars"]
	var at := bars.to_global(bars.box.get_center())
	_tip_to(t, c, at + Vector3(0, 0.15, 0))
	_tip_to(t, c, at)
	assert_eq(ons, [])
	t.set_shown(true)
	_tip_to(t, c, at + Vector3(0, 0.15, 0))
	_tip_to(t, c, at)
	assert_eq(ons.size(), 1, "shown again, it plays")
