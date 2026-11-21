class_name Looper
extends RefCounted
## Personal looper for a virtual instrument: records the player's note events
## (not audio) into loop slots, quantized like the sequencer, and plays them
## back sample-accurately through the Transport. Real-instrument (audio) loops
## arrive with the audio path in M4.
##
## A slot: start bar, length in bars, and layers (each overdub is a layer, so
## Undo removes the last one). Recording always starts and stops on bar lines.

signal changed

enum State { EMPTY, ARMED, RECORDING, PLAYING, OVERDUB_ARMED, OVERDUBBING, STOPPED }

const SLOTS := 4

var rig: InstrumentRig
var length_bars := 2
var slots: Array[Dictionary] = []
var current := 0

var _sounding := {} # note -> true


func _init(p_rig: InstrumentRig = null) -> void:
	rig = p_rig
	for i in SLOTS:
		slots.append(_empty_slot())


static func _empty_slot() -> Dictionary:
	return {"state": State.EMPTY, "start": 0.0, "bars": 2, "layers": [], "muted": false,
		"rec_start": 0.0, "rec_layer": [], "open": {}}


func slot() -> Dictionary:
	return slots[current]


func loop_beats(s: Dictionary) -> float:
	return s.bars * Transport.beats_per_bar


func state_name(s: Dictionary) -> String:
	return ["Empty", "Armed", "Recording", "Playing", "Overdub armed", "Overdubbing", "Stopped"][s.state]


## The main button: record -> (auto-stops after length) play; while playing -> overdub.
func press_record() -> void:
	var s := slot()
	if not Transport.running:
		Transport.start()
	var now := rig.heard_beat()
	var next_bar := ceilf(maxf(now, 0.0) / Transport.beats_per_bar - 1e-6) * Transport.beats_per_bar
	match s.state:
		State.EMPTY:
			s.bars = length_bars
			s.start = next_bar
			s.rec_start = next_bar
			s.state = State.ARMED
		State.PLAYING, State.STOPPED:
			# Overdub from the next bar line, for one pass of the loop.
			s.rec_start = next_bar
			s.state = State.OVERDUB_ARMED
		State.ARMED, State.OVERDUB_ARMED:
			s.state = State.EMPTY if s.layers.is_empty() else State.PLAYING
		State.RECORDING, State.OVERDUBBING:
			_finish_layer(s)
	changed.emit()


func toggle_play() -> void:
	var s := slot()
	if s.layers.is_empty():
		return
	s.state = State.STOPPED if s.state in [State.PLAYING, State.OVERDUBBING, State.OVERDUB_ARMED] else State.PLAYING
	if s.state == State.STOPPED:
		_release_all()
	changed.emit()


func undo() -> void:
	var s := slot()
	if s.state in [State.RECORDING, State.OVERDUBBING]:
		s.rec_layer = []
		s.open = {}
		s.state = State.PLAYING if not s.layers.is_empty() else State.EMPTY
	elif not s.layers.is_empty():
		s.layers.pop_back()
		if s.layers.is_empty():
			s.state = State.EMPTY
	_release_all()
	changed.emit()


func clear() -> void:
	slots[current] = _empty_slot()
	_release_all()
	changed.emit()


func toggle_mute() -> void:
	slot().muted = not slot().muted
	if slot().muted:
		_release_all()
	changed.emit()


## Called with every event the player makes (InstrumentRig.played).
func capture(event: Dictionary) -> void:
	for s in slots:
		if s.state != State.RECORDING and s.state != State.OVERDUBBING:
			continue
		var beat: float = event.get("beat", rig.heard_beat())
		var L := loop_beats(s)
		var rel: float = beat - s.rec_start
		if rel < -0.25 or rel >= L:
			continue
		match event.type:
			"on":
				var q := Transport.quantize(rel)
				s.open[event.note] = q - rel # remember the shift so the note keeps its length
				s.rec_layer.append({"b": fposmod(q, L), "on": true, "note": event.note, "v": event.velocity})
			"off":
				var shift: float = s.open.get(event.note, 0.0)
				s.open.erase(event.note)
				s.rec_layer.append({"b": fposmod(rel + shift, L), "on": false, "note": event.note})


func _finish_layer(s: Dictionary) -> void:
	# Close notes still held at the end of the pass.
	var L := loop_beats(s)
	for note in s.open:
		s.rec_layer.append({"b": L - 0.01, "on": false, "note": note})
	s.open = {}
	if not s.rec_layer.is_empty():
		s.layers.append(s.rec_layer)
	s.rec_layer = []
	s.state = State.PLAYING if not s.layers.is_empty() else State.EMPTY
	changed.emit()


## Transport client.
func schedule(from_beat: float, to_beat: float) -> void:
	for s in slots:
		_advance_state(s, to_beat)
		if s.muted or s.layers.is_empty():
			continue
		if not (s.state in [State.PLAYING, State.OVERDUB_ARMED, State.OVERDUBBING]):
			continue
		var L := loop_beats(s)
		var k := int(floorf((from_beat - s.start) / L))
		while s.start + k * L < to_beat:
			var base: float = s.start + k * L
			for layer in s.layers:
				for e in layer:
					var b: float = base + e.b
					if b < from_beat or b >= to_beat:
						continue
					var f := Transport.frame_for(rig.synth, b)
					if e.on:
						rig.synth.note_on(e.note, e.v, f)
						_sounding[e.note] = true
					else:
						rig.synth.note_off(e.note, f)
			k += 1


func _advance_state(s: Dictionary, to_beat: float) -> void:
	# Bar-line transitions, decided as the transport schedules past them.
	var heard := rig.heard_beat()
	match s.state:
		State.ARMED:
			if heard >= s.rec_start:
				s.state = State.RECORDING
				changed.emit()
		State.OVERDUB_ARMED:
			if heard >= s.rec_start:
				s.state = State.OVERDUBBING
				changed.emit()
		State.RECORDING, State.OVERDUBBING:
			if heard >= s.rec_start + loop_beats(s):
				_finish_layer(s)


func transport_stopped() -> void:
	_release_all()
	for s in slots:
		if s.state in [State.RECORDING, State.OVERDUBBING]:
			_finish_layer(s)
		if s.state in [State.ARMED]:
			s.state = State.EMPTY
		if s.state == State.OVERDUB_ARMED:
			s.state = State.PLAYING
		if not s.layers.is_empty():
			s.start = 0.0 # restart in sync from bar 1 next time
	changed.emit()


func _release_all() -> void:
	if rig:
		for note in _sounding:
			rig.synth.note_off(note)
	_sounding.clear()


## A finished loop as a portable layer for the master looper.
func export_slot(i := -1) -> Dictionary:
	var s: Dictionary = slots[current if i < 0 else i]
	var events := []
	for layer in s.layers:
		events.append_array(layer)
	return {"bars": s.bars, "events": events, "instrument": rig.synth.instrument,
		"params": PresetLibrary.capture(rig.synth, "loop").params}
