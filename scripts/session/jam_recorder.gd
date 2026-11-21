class_name JamRecorder
extends Node
## Records a jam as it's heard on this machine, then saves it:
##
## - `stem_<player>.wav` per player (instrument + audio loops + voice/input)
##   and `mixdown.wav`, streamed to disk while playing (JamStemRecorder);
## - `jam.mid`: every note that actually played, one track per player
##   (logged on the audio thread, so sequencers, loops and remote notes are
##   exact), with the tempo map;
## - `session.json` (+ `clip_*.wav`): tempo, every player's sound, sequencer
##   and loops, and the master looper, to load back later (load_session()).
##
## Everything starts at the bar line at or before the moment Record was
## pressed, so the stems and the MIDI line up on bars in a DAW. The metronome
## is not recorded.

signal state_changed(recording: bool)
signal saved(dir: String)

const PPQ := 480

var recording := false
var dir := ""
var last_dir := ""

var _stems: Object # JamStemRecorder
var _t0 := 0.0 # local time of the timeline start
var _tracks := {} # player name -> {"synth": JamSynth, "events": PackedFloat64Array, "instrument": String}
var _tempo_log: Array = [] # [local time, bpm]
var _meter := 4
var _sources := {} # source key -> true (added already)
var _log_only: Array = [] # synths recorded for their notes only (players in audio mode)


func _process(_d: float) -> void:
	if recording:
		_collect()
		_add_new_sources()


static func supported() -> bool:
	return ClassDB.class_exists("JamStemRecorder")


func start() -> Error:
	if recording or not supported():
		return ERR_UNAVAILABLE
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	dir = "user://jams/%s/" % stamp
	DirAccess.make_dir_recursive_absolute(dir)
	# Start on the bar line at or before now, so bars line up in a DAW.
	_t0 = JamSynth.get_time()
	if Transport.running:
		var b := Transport.beat_at(Transport.now())
		var bar := floorf(b / Transport.beats_per_bar) * Transport.beats_per_bar
		_t0 = Transport.time_at(bar) - Transport.clock_offset
	_stems = ClassDB.instantiate("JamStemRecorder")
	if _stems.start(dir, _t0, int(AudioServer.get_mix_rate())) != OK:
		return ERR_CANT_CREATE
	_tracks.clear()
	_sources.clear()
	_tempo_log = [[_t0, Transport.bpm]]
	_meter = Transport.beats_per_bar
	if not Transport.tempo_changed.is_connected(_on_tempo):
		Transport.tempo_changed.connect(_on_tempo)
	_add_new_sources()
	recording = true
	state_changed.emit(true)
	return OK


func _on_tempo(bpm: float) -> void:
	if recording:
		_tempo_log.append([JamSynth.get_time(), bpm])


func _player_name(id: int) -> String:
	var p: Dictionary = Session.players.get(id, {})
	return str(p.get("name", Session.player_name if id == Session.my_id() else "Player %d" % id))


## Adds whatever is playing that isn't recorded yet (players and master
## layers can appear mid-jam).
func _add_new_sources() -> void:
	var out_lat := AudioServer.get_output_latency()
	var me := Session.player_name
	var rig := Session.local_rig
	if rig:
		_add_synth("local", me, rig.synth, out_lat, true)
		_add_synth("local_clips", me, rig.clip_synth(), out_lat, false)
		if Session.audio and Session.audio.get_input_time() >= 0.0 and not _sources.has("input"):
			_sources["input"] = true
			_stems.add_input(me, Session.audio, 0.0) # stamped when played: no shift
	for id in Session.players:
		var p: Dictionary = Session.players[id]
		if not p.has("rig"):
			continue
		var who := _player_name(id)
		# A player in audio mode: their sound is in their voice stream; keep only their notes.
		_add_synth("rig%d" % id, who, p.rig.synth, out_lat, true, "", not p.get("audio_mode", false))
		_add_synth("clips%d" % id, who, p.rig.clip_synth(), out_lat, false)
		if Session.audio and p.get("voice") and not _sources.has("voice%d" % id):
			_sources["voice%d" % id] = true
			# Put their voice back where they played it: minus buffer and network.
			var st: Dictionary = Session.audio.get_peer_stats(id)
			var lat: float = float(st.get("audio_delay_ms", -1.0)) / 1000.0
			if lat <= 0.0:
				lat = (float(st.get("latency_ms", 15.0)) + maxf(float(st.get("rtt_ms", 0.0)), 0.0) * 0.5) / 1000.0
			_stems.add_peer_voice(who, Session.audio, id, out_lat - lat)
	for l in MasterLooper.layers:
		_add_synth("master%d" % l.id, "Master looper", l.synth, out_lat, l.kind != "audio", "Master: %s by %s" % [l.instrument, l.owner_name])


func _add_synth(key: String, player: String, synth: JamSynth, shift: float, notes: bool, track := "", audio := true) -> void:
	if _sources.has(key) or synth == null:
		return
	_sources[key] = true
	if audio:
		_stems.add_synth(player, synth, shift)
	else:
		synth.set_recording(true) # notes only (the stem recorder turns this off for its own sources)
		_log_only.append(synth)
	if notes:
		var name := track if track != "" else player
		_tracks[key] = {"name": name, "synth": synth, "events": PackedFloat64Array(), "instrument": synth.instrument}


func _collect() -> void:
	_stems.pump()
	for key in _tracks:
		var t: Dictionary = _tracks[key]
		t.events.append_array(t.synth.take_events())


func length() -> float:
	return _stems.get_length() if recording else 0.0


## Stops, writes MIDI and the session, and returns the folder.
func stop() -> String:
	if not recording:
		return ""
	_collect()
	_stems.stop()
	for synth in _log_only:
		if is_instance_valid(synth):
			synth.set_recording(false)
	_log_only.clear()
	recording = false
	write_midi(dir + "jam.mid")
	save_session(dir + "session.json")
	last_dir = dir
	state_changed.emit(false)
	saved.emit(dir)
	return dir


# ---- MIDI

func _ticks(t: float) -> int:
	# Seconds -> ticks through the tempo log.
	var ticks := 0.0
	for i in _tempo_log.size():
		var seg_t: float = _tempo_log[i][0]
		var bpm: float = _tempo_log[i][1]
		var seg_end: float = _tempo_log[i + 1][0] if i + 1 < _tempo_log.size() else INF
		if t <= seg_t:
			break
		ticks += (minf(t, seg_end) - maxf(seg_t, _t0)) * bpm / 60.0 * PPQ
	return maxi(0, int(roundf(ticks)))


static func _vlq(n: int) -> PackedByteArray:
	var bytes := [n & 0x7f]
	n >>= 7
	while n > 0:
		bytes.push_front((n & 0x7f) | 0x80)
		n >>= 7
	return PackedByteArray(bytes)


static func _chunk(id: String, data: PackedByteArray) -> PackedByteArray:
	var b := id.to_ascii_buffer()
	var size_bytes := PackedByteArray([0, 0, 0, 0])
	size_bytes.encode_u32(0, data.size())
	size_bytes.reverse() # big-endian
	b.append_array(size_bytes)
	b.append_array(data)
	return b


static func _track(events: Array, name: String) -> PackedByteArray:
	# events: [tick, bytes]; sorted here. Ends with End of Track.
	events.sort_custom(func(a, b): return a[0] < b[0])
	var d := PackedByteArray()
	var nm := name.to_utf8_buffer()
	d.append_array(PackedByteArray([0, 0xff, 0x03]))
	d.append_array(_vlq(nm.size()))
	d.append_array(nm)
	var last := 0
	for e in events:
		d.append_array(_vlq(e[0] - last))
		d.append_array(e[1])
		last = e[0]
	d.append_array(PackedByteArray([0, 0xff, 0x2f, 0]))
	return d


func write_midi(path: String) -> void:
	var tracks := []
	# Track 0: tempo map and meter.
	var meta := []
	for tl in _tempo_log:
		var us := int(roundf(60_000_000.0 / float(tl[1])))
		meta.append([_ticks(tl[0]), PackedByteArray([0xff, 0x51, 3, (us >> 16) & 0xff, (us >> 8) & 0xff, us & 0xff])])
	meta.append([0, PackedByteArray([0xff, 0x58, 4, _meter, 2, 24, 8])])
	tracks.append(_track(meta, "Tempo"))
	var ch := 0
	for key in _tracks:
		var t: Dictionary = _tracks[key]
		var ev: PackedFloat64Array = t.events
		var out := []
		var is_drum: bool = t.instrument == "Pulsar"
		var c := 9 if is_drum else ch
		if not is_drum:
			ch = (ch + 1) % 16
			if ch == 9:
				ch = 10
		for i in range(0, ev.size(), 4):
			var tick := _ticks(ev[i])
			var type := int(ev[i + 1])
			var a := clampi(int(ev[i + 2]), 0, 127)
			var v := float(ev[i + 3])
			match type:
				0:
					out.append([tick, PackedByteArray([0x90 | c, a, clampi(int(roundf(v * 127.0)), 1, 127)])])
				1:
					out.append([tick, PackedByteArray([0x80 | c, a, 64])])
				2:
					out.append([tick, PackedByteArray([0xb0 | c, 123, 0])])
				4:
					if int(ev[i + 2]) < 128:
						out.append([tick, PackedByteArray([0xb0 | c, a, clampi(int(roundf(v * 127.0)), 0, 127)])])
					else:
						out.append([tick, PackedByteArray([0xd0 | c, clampi(int(roundf(v * 127.0)), 0, 127)])])
				5:
					var bend := clampi(int(roundf((v + 1.0) * 8191.5)), 0, 16383)
					out.append([tick, PackedByteArray([0xe0 | c, bend & 0x7f, bend >> 7])])
		tracks.append(_track(out, "%s (%s)" % [t.name, t.instrument]))
	var header := PackedByteArray([0, 1, 0, 0, 0, 0])
	header[3] = tracks.size() & 0xff
	header[2] = tracks.size() >> 8
	header[4] = PPQ >> 8
	header[5] = PPQ & 0xff
	var bytes := _chunk("MThd", header)
	for tr in tracks:
		bytes.append_array(_chunk("MTrk", tr))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_buffer(bytes)


# ---- Session file

static func write_wav_mono(path: String, samples: PackedFloat32Array, rate: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	var data := samples.to_byte_array()
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(3) # float
	f.store_16(1)
	f.store_32(rate)
	f.store_32(rate * 4)
	f.store_16(4)
	f.store_16(32)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)


## Reads the float mono WAVs this file writes: {samples, rate}, or {}.
static func read_wav_mono(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_buffer(4).get_string_from_ascii() != "RIFF":
		return {}
	f.get_32()
	if f.get_buffer(4).get_string_from_ascii() != "WAVE":
		return {}
	var rate := 48000
	var fmt := 0
	var chans := 1
	while f.get_position() + 8 <= f.get_length():
		var id := f.get_buffer(4).get_string_from_ascii()
		var size := f.get_32()
		if id == "fmt ":
			fmt = f.get_16()
			chans = f.get_16()
			rate = f.get_32()
			f.get_buffer(size - 8)
		elif id == "data":
			if fmt != 3 or chans != 1:
				return {}
			return {"samples": f.get_buffer(size).to_float32_array(), "rate": rate}
		else:
			f.get_buffer(size)
	return {}


func _player_state(rig: InstrumentRig, name: String, key: String, base: String) -> Dictionary:
	var loops := rig.looper.to_net()
	var clip_files := {}
	for id in rig.looper.used_clips():
		var c: Dictionary = rig.looper.clips.get(id, {})
		if c.is_empty():
			continue
		var file := "clip_%s_%d.wav" % [key, id]
		write_wav_mono(base + file, c.samples, int(c.rate))
		clip_files[str(id)] = file
	return {"name": name, "instrument": rig.instrument, "sound": PresetLibrary.capture(rig.synth, name),
		"sequencer": rig.sequencer.to_dict(), "loops": loops, "clips": clip_files}


func save_session(path: String) -> void:
	var base := path.get_base_dir() + "/"
	var players := []
	if Session.local_rig:
		players.append(_player_state(Session.local_rig, Session.player_name, "me", base))
	for id in Session.players:
		var p: Dictionary = Session.players[id]
		if p.has("rig"):
			players.append(_player_state(p.rig, str(p.name), "p%d" % id, base))
	var master := []
	for l in MasterLooper.layers:
		var d := {"owner_name": l.owner_name, "instrument": l.instrument, "kind": l.kind, "bars": l.bars,
			"events": l.events, "params": l.params, "clips": []}
		for i in l.clips.size():
			var file := "clip_master%d_%d.wav" % [l.id, i]
			write_wav_mono(base + file, l.clips[i].samples, int(l.clips[i].rate))
			d.clips.append({"file": file, "at": l.clips[i].get("at", 0.0)})
		master.append(d)
	var data := {"format": 1, "app": "AudioSyncMaster", "saved": Time.get_datetime_string_from_system(),
		"bpm": Transport.bpm, "beats_per_bar": Transport.beats_per_bar,
		"quantize": {"enabled": Transport.quantize_enabled, "grid": Transport.quantize_grid},
		"players": players, "master": master}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "  "))


## Loads a saved session into this machine: tempo (if we may set it), our
## instrument, sound, sequencer and loops from `player_index` (0 = whoever
## saved it), and the master looper's layers. Returns "" or an error.
static func load_session(path: String, player_index := 0) -> String:
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or data.get("app", "") != "AudioSyncMaster":
		return "That isn't an AudioSyncMaster session file."
	var base := path.get_base_dir() + "/"
	Transport.set_tempo(float(data.get("bpm", Transport.bpm)))
	Transport.set_beats_per_bar(int(data.get("beats_per_bar", Transport.beats_per_bar)))
	var players: Array = data.get("players", [])
	var rig := Session.local_rig
	if rig and player_index < players.size():
		var p: Dictionary = players[player_index]
		var inst := str(p.get("instrument", rig.instrument))
		if inst in JamSynth.get_instrument_types():
			rig.set_instrument(inst)
		var sound: Dictionary = p.get("sound", {})
		if not sound.is_empty():
			rig.load_preset(sound)
		rig.sequencer.from_dict(p.get("sequencer", {}))
		var clip_files: Dictionary = p.get("clips", {})
		for id in clip_files:
			var w := read_wav_mono(base + str(clip_files[id]))
			if not w.is_empty():
				rig.looper.add_clip(w.samples, int(w.rate), int(id))
		rig.looper.apply_net(_fix_loops(p.get("loops", [])))
	for m in data.get("master", []):
		var d: Dictionary = m.duplicate()
		if d.get("kind", "notes") == "audio":
			var clips := []
			for c in d.get("clips", []):
				var w := read_wav_mono(base + str(c.file))
				if not w.is_empty():
					clips.append({"samples": w.samples, "rate": w.rate, "at": float(c.get("at", 0.0))})
			d.clips = clips
			d.instrument = "Clips"
		MasterLooper.push(_fix_master(d))
	return ""


## JSON turns ints into floats; put loop data back in shape.
static func _fix_loops(loops: Array) -> Array:
	for s in loops:
		s.state = int(s.get("state", 0))
		s.bars = int(s.get("bars", 2))
		if s.get("kind", "notes") == "audio":
			for layer in s.layers:
				layer.clip = int(layer.clip)
		else:
			for layer in s.layers:
				for e in layer:
					e.note = int(e.note)
	return loops


static func _fix_master(d: Dictionary) -> Dictionary:
	d.bars = int(d.get("bars", 1))
	for e in d.get("events", []):
		e.note = int(e.note)
	return d
