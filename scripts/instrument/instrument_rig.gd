class_name InstrumentRig
extends Node
## One playable instrument: a JamSynth, the player that sounds it, and the
## wiring from MIDI / keyboard / on-screen input. Every note or control the
## player makes goes out through `played`, which the sequencer, looper and
## network layers listen to.
##
## MIDI learn: call learn(param_id), then move a knob on the controller.

signal played(event: Dictionary) # {type: "on"/"off"/"cc"/"bend", ...}
signal instrument_changed(type: String)
signal preset_changed(preset: Dictionary)
signal learn_changed(param_id: String) # "" when learning finished
signal param_changed(id: String, value: float) # from MIDI learn mappings

const COLORS := {
	"Pulsar": Color("ff8a3d"),
	"Undertow": Color("2ec4b6"),
	"Comet": Color("ff4f9a"),
	"Lumen": Color("ffd166"),
	"Driftwood": Color("9ccc65"),
	"Tangle": Color("9b7bff"),
}
const MAP_PATH := "user://midi_map.cfg"

@export var instrument := "Undertow":
	set = set_instrument
## Listen to the Midi autoload (the local player's own instrument).
@export var local_input := true
## Play through an AudioStreamPlayer3D at this node's parent (XR), or flat.
@export var spatial := false

var synth := JamSynth.new()
var player: Node
var current_preset: Dictionary = {}
var learning := ""

var _map := ConfigFile.new() # [instrument] cc -> param id


func _ready() -> void:
	_map.load(MAP_PATH)
	if spatial:
		var p := AudioStreamPlayer3D.new()
		p.stream = synth
		p.unit_size = 4.0
		player = p
	else:
		var p := AudioStreamPlayer.new()
		p.stream = synth
		player = p
	add_child(player)
	set_instrument(instrument)
	player.play()
	if local_input:
		Midi.note_on.connect(func(n, v): play_note(n, v / 127.0))
		Midi.note_off.connect(func(n): release_note(n))
		Midi.control_change.connect(_on_cc)
		Midi.pitch_bend.connect(func(v): bend(v))
		Midi.pressure.connect(func(v): synth.control_change(128, v))


func set_instrument(type: String) -> void:
	instrument = type
	if not is_inside_tree():
		return
	synth.all_notes_off()
	# JamSynth swaps instruments while playing; no need to restart the player.
	synth.instrument = type
	instrument_changed.emit(type)
	var presets := PresetLibrary.list(type)
	if presets.size() > 0:
		load_preset(presets[0])


func load_preset(preset: Dictionary) -> void:
	if PresetLibrary.apply(synth, preset):
		current_preset = preset
		preset_changed.emit(preset)


func color() -> Color:
	return COLORS.get(instrument, Color.WHITE)


func play_note(note: int, velocity: float, frame := -1) -> void:
	synth.note_on(note, velocity, frame)
	played.emit({"type": "on", "note": note, "velocity": velocity})


func release_note(note: int, frame := -1) -> void:
	synth.note_off(note, frame)
	played.emit({"type": "off", "note": note})


func bend(value: float) -> void:
	synth.pitch_bend(value)
	played.emit({"type": "bend", "value": value})


func set_param(id: String, value: float) -> void:
	if instrument == "Tangle" and id.contains("/"):
		var parts := id.split("/")
		synth.tangle_set_param(int(parts[0]), parts[1], value)
	else:
		synth.set_param(id, value)
	played.emit({"type": "param", "id": id, "value": value})


func _on_cc(cc: int, value: int) -> void:
	if learning != "":
		if cc != 64 and cc != 1: # keep the pedal and mod wheel for their usual jobs
			_map.set_value(instrument, str(cc), learning)
			_map.save(MAP_PATH)
			learning = ""
			learn_changed.emit("")
			return
	var target: String = _map.get_value(instrument, str(cc), "")
	if target != "":
		var info := _param_info(target)
		if not info.is_empty():
			var t := value / 127.0
			var v: float = info.min + (info.max - info.min) * t
			if info.log and info.min > 0.0:
				v = info.min * pow(info.max / info.min, t)
			set_param(target, v)
			param_changed.emit(target, synth.get_param(target))
		return
	synth.control_change(cc, value / 127.0)
	played.emit({"type": "cc", "cc": cc, "value": value / 127.0})


func learn(param_id: String) -> void:
	learning = param_id
	learn_changed.emit(param_id)


func forget(param_id: String) -> void:
	if not _map.has_section(instrument):
		return
	for cc in _map.get_section_keys(instrument):
		if _map.get_value(instrument, cc) == param_id:
			_map.erase_section_key(instrument, cc)
	_map.save(MAP_PATH)


func mapped_cc(param_id: String) -> int:
	if _map.has_section(instrument):
		for cc in _map.get_section_keys(instrument):
			if _map.get_value(instrument, cc) == param_id:
				return int(cc)
	return -1


func _param_info(id: String) -> Dictionary:
	for p in synth.get_param_list():
		if p.id == id:
			return p
	return {}
