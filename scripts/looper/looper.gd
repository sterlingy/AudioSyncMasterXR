class_name Looper
extends RefCounted
## Personal looper. Records into loop slots and plays them back
## sample-accurately through the Transport.
##
## - **Note slots** (virtual instruments) record the player's note events,
##   quantized like the sequencer, and replay them on the instrument.
## - **Audio slots** (real instruments, voice) record the player's audio
##   input. The audio link keeps a timestamped recording of the input, so when
##   a pass ends the looper cuts out exactly the bars that were played, as
##   heard (shared clock), and plays that clip on the rig's Clips synth at the
##   start of every pass. Clips go to the other players once; they play them
##   from the clock too, never as a live stream.
##
## A slot: start bar, length in bars, and layers (each overdub is a layer, so
## Undo removes the last one). Recording always starts and stops on bar lines.

signal changed
signal clip_added(id: int) ## a new clip of ours (the Session sends it to the others)

enum State { EMPTY, ARMED, RECORDING, PLAYING, OVERDUB_ARMED, OVERDUBBING, STOPPED }

const SLOTS := 4
const MAX_AUDIO_LAYERS := 8
const FETCH_MARGIN := 0.12 # seconds after a pass ends before its audio is surely recorded

var rig: InstrumentRig
var length_bars := 2
var slots: Array[Dictionary] = []
var current := 0
## New recordings capture audio input instead of notes.
var audio_input := false
## Set on other players' loopers when this headset listens to its own loops only.
var silenced := false:
	set(v):
		silenced = v
		if v:
			_release_all()
var last_error := ""
var clips := {} # clip id -> {"samples": PackedFloat32Array, "rate": int, "slot": int}

var _sounding := {} # note -> true
var _next_clip := 1
var _pending: Array = [] # audio passes waiting to be cut: {"s", "t0", "t1", "due", "at"}


func _init(p_rig: InstrumentRig = null) -> void:
	rig = p_rig
	for i in SLOTS:
		slots.append(_empty_slot())


static func _empty_slot() -> Dictionary:
	return {"state": State.EMPTY, "kind": "notes", "start": 0.0, "bars": 2, "layers": [], "muted": false,
		"rec_start": 0.0, "rec_layer": [], "open": {}}


func slot() -> Dictionary:
	return slots[current]


func loop_beats(s: Dictionary) -> float:
	return s.bars * Transport.beats_per_bar


func state_name(s: Dictionary) -> String:
	return ["Empty", "Armed", "Recording", "Playing", "Overdub armed", "Overdubbing", "Stopped"][s.state]


## The audio input recorder (the Session's audio link), or null.
static func recorder() -> Object:
	var a: Object = Session.audio
	return a if a and a.get_input_time() >= 0.0 else null


## The main button: record -> (auto-stops after length) play; while playing -> overdub.
func press_record() -> void:
	var s := slot()
	last_error = ""
	if s.state == State.EMPTY and audio_input and recorder() == null:
		last_error = "Turn on your audio input (Jam tab) to record audio loops."
		changed.emit()
		return
	if s.kind == "audio" and s.state in [State.PLAYING, State.STOPPED] and s.layers.size() >= MAX_AUDIO_LAYERS:
		last_error = "This slot has %d audio layers already." % MAX_AUDIO_LAYERS
		changed.emit()
		return
	if not Transport.running:
		Transport.start()
	var now := rig.heard_beat()
	var next_bar := ceilf(maxf(now, 0.0) / Transport.beats_per_bar - 1e-6) * Transport.beats_per_bar
	match s.state:
		State.EMPTY:
			s.kind = "audio" if audio_input else "notes"
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
		var layer: Variant = s.layers.pop_back()
		if s.kind == "audio":
			remove_clip(int(layer.clip))
		if s.layers.is_empty():
			s.state = State.EMPTY
	_release_all()
	changed.emit()


func clear() -> void:
	var s := slot()
	if s.kind == "audio":
		for layer in s.layers:
			remove_clip(int(layer.clip))
	_pending = _pending.filter(func(p): return p.s != s)
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
		if s.kind != "notes":
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


func _finish_layer(s: Dictionary, keep_audio := true) -> void:
	var L := loop_beats(s)
	if s.kind == "audio":
		# Cut the pass out of the input recording once it has surely arrived.
		if keep_audio:
			var t0 := Transport.time_at(s.rec_start) - Transport.clock_offset
			var t1 := Transport.time_at(s.rec_start + L) - Transport.clock_offset
			_pending.append({"s": s, "t0": t0, "t1": t1, "due": t1 + FETCH_MARGIN, "at": fposmod(s.rec_start - s.start, L)})
		s.state = State.PLAYING if (keep_audio or not s.layers.is_empty()) else State.EMPTY
		changed.emit()
		return
	# Close notes still held at the end of the pass.
	for note in s.open:
		s.rec_layer.append({"b": L - 0.01, "on": false, "note": note})
	s.open = {}
	if not s.rec_layer.is_empty():
		s.layers.append(s.rec_layer)
	s.rec_layer = []
	s.state = State.PLAYING if not s.layers.is_empty() else State.EMPTY
	changed.emit()


## Every frame (InstrumentRig._process): turns finished audio passes into clips.
func poll() -> void:
	if _pending.is_empty():
		return
	var now := JamSynth.get_time()
	for p in _pending.duplicate():
		if now < p.due:
			continue
		_pending.erase(p)
		var s: Dictionary = p.s
		var rec := recorder()
		var d: Dictionary = rec.get_input_audio(p.t0, p.t1) if rec else {}
		var samples: PackedFloat32Array = d.get("samples", PackedFloat32Array())
		if samples.is_empty():
			last_error = "No audio was recorded (is your input on?)."
			if s.layers.is_empty():
				s.state = State.EMPTY
			changed.emit()
			continue
		var id := add_clip(samples, int(d.rate))
		s.layers.append({"clip": id, "at": p.at})
		clip_added.emit(id)
		_start_late(s, id, p.at)
		changed.emit()


## A clip that arrived after its pass began joins in at the right sample.
func _start_late(s: Dictionary, id: int, at: float) -> void:
	if not Transport.running or silenced or s.muted or not s.state in [State.PLAYING, State.OVERDUB_ARMED, State.OVERDUBBING]:
		return
	var c: Dictionary = clips[id]
	var L := loop_beats(s)
	var heard := Transport.beat_at(Transport.now() + AudioServer.get_output_latency() + 0.01)
	var base: float = s.start + floorf((heard - s.start - at) / L) * L + at
	var offset := int(roundf((Transport.time_at(heard) - Transport.time_at(base)) * AudioServer.get_mix_rate()))
	var synth := rig.clip_synth()
	synth.clip_play(c.slot, 1.0, -1, offset)
	# The next pass may already be inside the scheduled window.
	if base + L < Transport._scheduled_until:
		synth.clip_play(c.slot, 1.0, Transport.frame_for(synth, base + L), 0)


## Transport client.
func schedule(from_beat: float, to_beat: float) -> void:
	for s in slots:
		_advance_state(s, to_beat)
		if silenced or s.muted or s.layers.is_empty():
			continue
		if not (s.state in [State.PLAYING, State.OVERDUB_ARMED, State.OVERDUBBING]):
			continue
		var L := loop_beats(s)
		var k := int(floorf((from_beat - s.start) / L)) - 1
		while s.start + k * L < to_beat:
			var base: float = s.start + k * L
			if s.kind == "audio":
				for layer in s.layers:
					var b: float = base + float(layer.at)
					var c: Dictionary = clips.get(int(layer.clip), {})
					if b >= from_beat and b < to_beat and not c.is_empty():
						var synth := rig.clip_synth()
						synth.clip_play(c.slot, 1.0, Transport.frame_for(synth, b), 0)
			else:
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
			_finish_layer(s, false) # an unfinished audio pass is dropped
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
		if rig.has_clips():
			rig.clip_synth().all_notes_off()
	_sounding.clear()


# ---- Clips

func add_clip(samples: PackedFloat32Array, rate: int, id := -1) -> int:
	if id < 0:
		id = _next_clip
	_next_clip = maxi(_next_clip, id + 1)
	if clips.has(id):
		remove_clip(id)
	var used := {}
	for c in clips.values():
		used[c.slot] = true
	var slot_index := 0
	while used.has(slot_index) and slot_index < 63:
		slot_index += 1
	clips[id] = {"samples": samples, "rate": rate, "slot": slot_index}
	rig.clip_synth().clip_set(slot_index, samples, rate)
	return id


func remove_clip(id: int) -> void:
	if clips.has(id):
		rig.clip_synth().clip_clear(clips[id].slot)
		clips.erase(id)


## Clip ids the slots still use (mirrors drop the rest).
func used_clips() -> Dictionary:
	var used := {}
	for s in slots:
		if s.kind == "audio":
			for layer in s.layers:
				used[int(layer.clip)] = true
	return used


# ---- Sharing

## What other players need to play this looper in sync: finished layers and
## whether each slot is playing. Recording in progress isn't shared; notes
## arrive live and the layer follows when the pass ends. Audio layers only
## name their clip; the clip itself is sent once (clip_added).
func to_net() -> Array:
	var out := []
	for s in slots:
		var st := State.EMPTY
		if not s.layers.is_empty():
			st = State.STOPPED if s.state == State.STOPPED else State.PLAYING
		out.append({"state": st, "kind": s.kind, "start": s.start, "bars": s.bars, "layers": s.layers, "muted": s.muted})
	return out


## Mirrors another player's looper (see to_net()).
func apply_net(data: Array) -> void:
	for i in mini(data.size(), SLOTS):
		var d: Dictionary = data[i]
		var s := _empty_slot()
		s.state = int(d.get("state", State.EMPTY))
		s.kind = "audio" if d.get("kind", "notes") == "audio" else "notes"
		s.start = float(d.get("start", 0.0))
		s.bars = maxi(1, int(d.get("bars", 2)))
		s.layers = d.get("layers", [])
		s.muted = bool(d.get("muted", false))
		slots[i] = s
	var used := used_clips()
	for id in clips.keys():
		if not used.has(id):
			remove_clip(id)
	_release_all()
	changed.emit()


## A finished loop as a portable layer for the master looper.
func export_slot(i := -1) -> Dictionary:
	var s: Dictionary = slots[current if i < 0 else i]
	if s.kind == "audio":
		var list := []
		for layer in s.layers:
			var c: Dictionary = clips.get(int(layer.clip), {})
			if not c.is_empty():
				list.append({"samples": c.samples, "rate": c.rate, "at": layer.at})
		return {"bars": s.bars, "kind": "audio", "instrument": "Clips", "params": {}, "events": [], "clips": list}
	var events := []
	for layer in s.layers:
		events.append_array(layer)
	return {"bars": s.bars, "events": events, "instrument": rig.synth.instrument,
		"params": PresetLibrary.capture(rig.synth, "loop").params}
