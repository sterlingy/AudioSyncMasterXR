class_name PlayTable
extends Node3D
## The play table (XR only): every MusicInputKit object on one table, played with
## your hands and heard on your own instrument through KitBridge. Notes:
## strings, theremin orb, music box, chime bars, chord blocks, drum pads and the
## pitch ribbon. Shaping (front row, nearest your hands): tone dial, space fader,
## bend lever, filter XY pad, wobble flywheel and tilt cube. The scale buttons
## set the key and scale the bars, strings, blocks, orb and ribbon follow.
##
## Reach in and hit or touch an object; grip to hold on (twist the dial, tilt the
## cube); point and pull the trigger to play one out of reach. Patches (which
## moving part sets which knob) are saved to user://music_input_patches.json.

const PATCH_FILE := "user://music_input_patches.json"
const SIZE := Vector3(2.0, 0.04, 1.0)
const COLOR_TOP := Color("1a2430")
const COLOR_TAG := Color(0.07, 0.075, 0.09)

var kit: MusicInput
var bridge: KitBridge
var hands: PlayXRHands
var objects := {} # name -> Playable
var controllers: Array[XRController3D] = []
var save_patches := true # off in tests
var rig: InstrumentRig # null = the local player's (Session.local_rig); tests set one
var _tips: Array[Node3D] = []


func _ready() -> void:
	kit = MusicInput.new()
	kit.name = "MusicInput"
	add_child(kit)
	if save_patches:
		var saved := _load_patches()
		if not saved.is_empty():
			kit.patches.from_array(saved)
		kit.patches.changed.connect(_save_patches)
	_build_top()
	_build_objects()
	# Connected after the objects exist: they announce their starting values when
	# made, and those mustn't overwrite the sound you already have.
	bridge = KitBridge.new(kit)
	bridge.name = "KitBridge"
	bridge.rig = rig
	add_child(bridge)
	hands = PlayXRHands.new()
	hands.name = "PlayXRHands"
	add_child(hands)
	for c in controllers:
		_add_controller(c)


## Hands to play with (the XR rig's LeftHand / RightHand); before or after _ready.
func use_controllers(list: Array) -> void:
	for c in list:
		if c is XRController3D and not c in controllers:
			controllers.append(c)
			if hands:
				_add_controller(c)


func _add_controller(c: XRController3D) -> void:
	hands.add_controller(c)
	# A small glowing dot where your hand touches the objects.
	var tip := MeshInstance3D.new()
	tip.name = "PlayTip"
	var s := SphereMesh.new()
	s.radius = 0.01
	s.height = 0.02
	tip.mesh = s
	tip.material_override = Playable.mat(Color("ffb547"), 1.5)
	tip.position = hands.tip_offset
	tip.visible = visible
	c.add_child(tip)
	_tips.append(tip)


## Show or hide the table; hidden, it doesn't play and lets go of held notes.
func set_shown(on: bool) -> void:
	visible = on
	if hands:
		hands.enabled = on
	for t in _tips:
		if is_instance_valid(t):
			t.visible = on
	if not on and bridge:
		bridge.release_all()


func _exit_tree() -> void:
	if bridge:
		bridge.release_all()


func _build_top() -> void:
	var top := MeshInstance3D.new()
	top.name = "Top"
	var bm := BoxMesh.new()
	bm.size = SIZE
	top.mesh = bm
	top.material_override = Playable.mat(COLOR_TOP, 0.0, 0.85)
	top.position = Vector3(0, -SIZE.y / 2.0, 0)
	add_child(top)


func _build_objects() -> void:
	# Notes: back and middle rows. Shaping: the front row, nearest your hands.
	_add("Strings", LightStrings.new(), Vector3(-0.55, 0, -0.36), "Light strings")
	_add("Orb", ThereminOrb.new(), Vector3(0.0, 0, -0.32), "Theremin orb")
	_add("MusicBox", MusicBoxWheel.new(), Vector3(0.52, 0, -0.3), "Music box")
	_add("Scale", ScaleSwitch.new(), Vector3(0.83, 0, -0.33))
	_add("Bars", ChimeBars.new(), Vector3(-0.55, 0, -0.02), "Chime bars", true)
	_add("Blocks", ChordBlocks.new(), Vector3(0.08, 0, -0.02), "Chord blocks", true)
	_add("Pads", DrumPads.new(), Vector3(0.69, 0, -0.02), "Drum pads", true)
	var ribbon := PitchRibbon.new()
	ribbon.length = 0.55
	_add("Ribbon", ribbon, Vector3(-0.64, 0, 0.3), "Pitch ribbon")
	var dial := TwistDial.new()
	dial.label = "Tone"
	dial.default_param = "filter.cutoff"
	dial.start_value = 0.6
	_add("Dial", dial, Vector3(-0.22, 0, 0.3))
	var fader := SlideFader.new()
	fader.label = "Space"
	fader.default_param = "reverb.mix"
	fader.start_value = 0.3
	_add("Fader", fader, Vector3(-0.04, 0, 0.3))
	var lever := SlideFader.new()
	lever.label = "Bend"
	lever.spring_back = true
	lever.default_param = "@bend"
	lever.tint = Color("ff4f9a")
	_add("Whammy", lever, Vector3(0.1, 0, 0.3))
	var xy := XYPad.new()
	xy.label = "Filter"
	xy.x_param = "filter.cutoff"
	xy.y_param = "filter.resonance"
	_add("XY", xy, Vector3(0.32, 0, 0.3))
	var fw := Flywheel.new()
	fw.label = "Wobble"
	fw.default_param = "vibrato.depth"
	_add("Flywheel", fw, Vector3(0.58, 0, 0.3))
	var tc := TiltCube.new()
	tc.label = "Tilt"
	_add("Tilt", tc, Vector3(0.83, 0, 0.3))


func _add(n: String, p: Playable, pos: Vector3, title := "", front_tag := false) -> void:
	p.name = n
	p.kit = kit
	p.position = pos
	add_child(p)
	objects[n] = p
	if title == "":
		return # the shaping objects label themselves
	var tag := Label3D.new()
	tag.name = "Tag"
	tag.text = title
	tag.font_size = 32
	tag.outline_size = 10
	tag.outline_modulate = COLOR_TAG
	tag.modulate = Color(p.tint, 0.95)
	if front_tag:
		# Middle row: the name lies on the table in front, clear of the back row.
		tag.pixel_size = 0.0006
		tag.rotation_degrees = Vector3(-90, 0, 0)
		tag.position = Vector3(0, 0.002, p.box.end.z + 0.022)
	else:
		tag.pixel_size = 0.0008
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.no_depth_test = true
		tag.position = Vector3(0, p.box.end.y + 0.045, p.box.position.z)
	p.add_child(tag)


func _load_patches() -> Array:
	if not FileAccess.file_exists(PATCH_FILE):
		return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATCH_FILE))
	return data if data is Array else []


func _save_patches() -> void:
	if not save_patches:
		return
	var f := FileAccess.open(PATCH_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(kit.patches.to_array()))
