extends Node
## The shared master looper. Autoloaded as `MasterLooper`.
##
## Every player can push a finished personal loop here. Each layer keeps the
## instrument and the exact sound (parameter snapshot) it was recorded with and
## gets its own synth, so it keeps sounding the same even if its owner changes
## patch. Layers start on bar 1 and repeat every `bars`, so loops of different
## lengths stay lined up. In M4 the layers are shared with every client.
##
## Listening (per headset): MASTER_AND_LIVE, OWN_AND_LIVE, OWN_ONLY. Muting a
## layer only affects this headset; deleting needs the owner or the host.

signal changed

enum Listen { MASTER_AND_LIVE, OWN_AND_LIVE, OWN_ONLY }

var layers: Array[Dictionary] = []
var listen := Listen.MASTER_AND_LIVE
var local_owner := "me"
var audio_out := true # false in tests: layers render offline instead of playing
var is_host := true
var _next_id := 1


func _ready() -> void:
	Transport.register(self)
	Transport.tempo_changed.connect(func(bpm):
		for l in layers:
			l.synth.tempo = bpm)


func add_layer(data: Dictionary, owner := "") -> int:
	if data.get("events", []).is_empty():
		return -1
	var synth := JamSynth.new()
	synth.instrument = data.instrument
	synth.set_params(data.get("params", {}))
	synth.tempo = Transport.bpm
	var player: AudioStreamPlayer = null
	if audio_out:
		player = AudioStreamPlayer.new()
		player.stream = synth
		add_child(player)
		player.play()
	var layer := {"id": _next_id, "owner": owner if owner != "" else local_owner, "instrument": data.instrument,
		"bars": int(data.bars), "events": data.events, "params": data.get("params", {}),
		"muted": false, "synth": synth, "player": player, "sounding": {}}
	_next_id += 1
	layers.append(layer)
	changed.emit()
	return layer.id


func can_delete(layer: Dictionary) -> bool:
	return is_host or layer.owner == local_owner


func remove_layer(id: int) -> bool:
	for i in layers.size():
		if layers[i].id == id:
			if not can_delete(layers[i]):
				return false
			layers[i].synth.all_notes_off()
			if layers[i].player:
				layers[i].player.queue_free()
			layers.remove_at(i)
			changed.emit()
			return true
	return false


func toggle_mute(id: int) -> void:
	for l in layers:
		if l.id == id:
			l.muted = not l.muted
			if l.muted:
				_release(l)
	changed.emit()


func set_listen(mode: int) -> void:
	listen = mode
	for l in layers:
		if not _audible(l):
			_release(l)
	changed.emit()


func _audible(l: Dictionary) -> bool:
	if l.muted:
		return false
	return listen == Listen.MASTER_AND_LIVE or l.owner == local_owner


func schedule(from_beat: float, to_beat: float) -> void:
	for l in layers:
		if not _audible(l):
			continue
		var L := float(l.bars * Transport.beats_per_bar)
		var k := int(floorf(from_beat / L))
		while k * L < to_beat:
			for e in l.events:
				var b: float = k * L + e.b
				if b < from_beat or b >= to_beat:
					continue
				var f := Transport.frame_for(l.synth, b)
				if e.on:
					l.synth.note_on(e.note, e.v, f)
					l.sounding[e.note] = true
				else:
					l.synth.note_off(e.note, f)
			k += 1


func transport_stopped() -> void:
	for l in layers:
		_release(l)


func _release(l: Dictionary) -> void:
	for n in l.sounding:
		l.synth.note_off(n)
	l.sounding.clear()


func clear_all() -> void:
	for l in layers.duplicate():
		remove_layer(l.id)
