class_name KitBridge
extends Node
## Plays MusicInputKit's objects (addons/music_input_kit) on your instrument.
## This is the only place the kit meets the app: the objects never see SynthKit
## or the session, and the app never sees the objects.
##
## Every object plays the local player's instrument (Session.local_rig), whatever
## its kit "part" says, because each player has one instrument here. So it
## follows instrument changes by itself.
## - Notes go through Midi.inject_*, like the on-screen keys and fingertip play,
##   so looping, recording, quantize and the session all work unchanged.
## - Bends go through Midi.pitch_bend, like a MIDI keyboard's wheel.
## - Knob moves (0..1) become the knob's real value on the rig. The kit's generic
##   knob names are matched to each instrument's own ids (ALIASES); a knob the
##   instrument doesn't have is skipped. "@bend" and "@volume" work everywhere.

## Generic knob name -> the ids to try, in order, on whatever instrument is playing.
const ALIASES := {
	"filter.cutoff": ["filter.cutoff", "f1.cutoff"],
	"filter.resonance": ["filter.resonance", "filter.emphasis", "f1.resonance"],
	"filter.emphasis": ["filter.emphasis", "filter.resonance", "f1.resonance"],
	"reverb.mix": ["reverb.mix", "send.space"],
	"delay.mix": ["delay.mix", "send.echo", "reverb.mix", "send.space"],
	"chorus.mix": ["chorus.mix", "fx1.amount"],
	"vibrato.depth": ["vibrato.depth", "lfo1.vibrato", "lfo.pitch"],
	"perf.tremolo": ["perf.tremolo", "vibrato.depth", "lfo1.vibrato", "lfo.pitch"],
	"model.brightness": ["model.brightness", "filter.cutoff", "f1.cutoff"],
}
const BEND_RANGE_PARAMS := ["perf.bend_range", "ctrl.bend_range", "voice.bend_range"]

var kit: MusicInput
## The rig to play; null = Session.local_rig (looked up on each event, so a new
## rig after an instrument change or a session join is picked up).
var rig: InstrumentRig
var _voices := {} # kit voice -> note
var _bending := {} # kit voice -> semitones
var _info := {} # instrument -> {param id -> info}


func _init(k: MusicInput = null) -> void:
	kit = k


func _ready() -> void:
	kit.note_on.connect(_on_note_on)
	kit.note_off.connect(_on_note_off)
	kit.note_bend.connect(_on_bend)
	kit.control.connect(_on_control)


func _rig() -> InstrumentRig:
	return rig if rig else Session.local_rig


static func velocity_of(v: float) -> int:
	return clampi(roundi(v * 127.0), 1, 127)


func _on_note_on(_part: String, voice: int, note: int, velocity: float) -> void:
	_voices[voice] = note
	Midi.inject_note_on(note, velocity_of(velocity))


func _on_note_off(_part: String, voice: int, note: int) -> void:
	_voices.erase(voice)
	if _bending.erase(voice) and _bending.is_empty():
		Midi.pitch_bend.emit(0.0)
	# Another voice (the other hand) may still hold the same note: keep it.
	if not note in _voices.values():
		Midi.inject_note_off(note)


func _on_bend(_part: String, voice: int, semitones: float) -> void:
	_bending[voice] = semitones
	Midi.pitch_bend.emit(clampf(semitones / bend_range(), -1.0, 1.0))


## Semitones the instrument bends at full wheel (2 if it doesn't say).
func bend_range() -> float:
	var r := _rig()
	if r:
		var info := _params(r)
		for id in BEND_RANGE_PARAMS:
			if info.has(id):
				return maxf(float(r.synth.get_param(id)), 0.5)
	return 2.0


func _on_control(_part: String, param: String, value: float) -> void:
	var r := _rig()
	if r == null:
		return
	match param:
		"@bend":
			Midi.pitch_bend.emit(clampf(value * 2.0 - 1.0, -1.0, 1.0))
		"@volume":
			r.set_volume_db(linear_to_db(maxf(value, 0.0001)))
		_:
			var info := _params(r)
			var id := resolve(info, param)
			if id != "":
				r.set_param(id, real_value(info[id], value))


func _params(r: InstrumentRig) -> Dictionary:
	if not _info.has(r.instrument):
		var info := {}
		for p in r.synth.get_param_list():
			info[p.id] = p
		_info[r.instrument] = info
	return _info[r.instrument]


## The instrument's own id for a generic knob name, or "" if it has none.
static func resolve(info: Dictionary, param: String) -> String:
	for id in ALIASES.get(param, [param]):
		if info.has(id):
			return id
	return ""


## 0..1 -> the knob's own units (log knobs sweep evenly in octaves).
static func real_value(info: Dictionary, t: float) -> float:
	var lo: float = info.min
	var hi: float = info.max
	if info.get("log", false) and lo > 0.0:
		return lo * pow(hi / lo, t)
	return lerpf(lo, hi, t)


## Lets go of everything still sounding (the table hidden, the scene closing).
func release_all() -> void:
	for v in _voices.keys():
		var n: int = _voices[v]
		_voices.erase(v)
		if not n in _voices.values():
			Midi.inject_note_off(n)
	if not _bending.is_empty():
		_bending.clear()
		Midi.pitch_bend.emit(0.0)
