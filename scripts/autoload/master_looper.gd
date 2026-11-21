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
##
## In a session the host keeps the authoritative list: push() and
## request_remove() go to the host (through `net`, the Session), which
## checks permissions and sends the result to everyone. Joiners get the
## whole list. `owner` is the owner's peer id as a string.

signal changed

enum Listen { MASTER_AND_LIVE, OWN_AND_LIVE, OWN_ONLY }

var layers: Array[Dictionary] = []
var listen := Listen.MASTER_AND_LIVE
var local_owner := "me"
var audio_out := true # false in tests: layers render offline instead of playing
var is_host := true
var net: Object = null # Session: is_online(), master_push(data), master_remove(id)
var _next_id := 1


func _ready() -> void:
	Transport.register(self)
	Transport.tempo_changed.connect(func(bpm):
		for l in layers:
			l.synth.tempo = bpm)


func _online() -> bool:
	return net != null and net.is_online()


## UI entry point: add a finished loop (through the host when in a session).
func push(data: Dictionary) -> bool:
	if data.get("events", []).is_empty() and data.get("clips", []).is_empty():
		return false
	if _online():
		net.master_push(data)
		return true
	return add_layer(data) > 0


## UI entry point: delete a layer (the host checks permission in a session).
func request_remove(id: int) -> void:
	if _online():
		net.master_remove(id)
	else:
		remove_layer(id)


func add_layer(data: Dictionary, owner := "", id := -1, owner_name := "") -> int:
	var audio: bool = data.get("kind", "notes") == "audio"
	if (data.get("clips", []).is_empty() if audio else data.get("events", []).is_empty()):
		return -1
	if not data.get("instrument", "") in JamSynth.get_instrument_types():
		return -1
	if id < 0:
		id = _next_id
	_next_id = maxi(_next_id, id + 1)
	var synth := JamSynth.new()
	synth.instrument = "Clips" if audio else data.instrument
	synth.set_params(data.get("params", {}))
	var clips: Array = data.get("clips", []) if audio else []
	for i in mini(clips.size(), 64):
		synth.clip_set(i, clips[i].samples, int(clips[i].rate))
	synth.tempo = Transport.bpm
	var player: AudioStreamPlayer = null
	if audio_out:
		player = AudioStreamPlayer.new()
		player.stream = synth
		add_child(player)
		player.play()
	var own := owner if owner != "" else local_owner
	var layer := {"id": id, "owner": own, "owner_name": owner_name if owner_name != "" else own,
		"instrument": "Audio" if audio else data.instrument, "kind": "audio" if audio else "notes",
		"bars": maxi(1, int(data.bars)), "events": data.get("events", []), "clips": clips,
		"params": data.get("params", {}), "muted": false, "synth": synth, "player": player, "sounding": {}}
	layers.append(layer)
	changed.emit()
	return id


## Layers in a form that can go over the network.
func export_layer(l: Dictionary) -> Dictionary:
	return {"id": l.id, "owner": l.owner, "owner_name": l.owner_name,
		"instrument": "Clips" if l.kind == "audio" else l.instrument, "kind": l.kind,
		"bars": l.bars, "events": l.events, "params": l.params, "clips": l.clips}


func export_layers() -> Array:
	return layers.map(export_layer)


func find(id: int) -> Dictionary:
	for l in layers:
		if l.id == id:
			return l
	return {}


func import_layer(d: Dictionary) -> void:
	if not find(int(d.get("id", -1))).is_empty():
		return
	add_layer(d, str(d.get("owner", "")), int(d.get("id", -1)), str(d.get("owner_name", "")))


func import_layers(list: Array) -> void:
	for l in layers.duplicate():
		force_remove(l.id)
	for d in list:
		import_layer(d)


func can_delete(layer: Dictionary) -> bool:
	return is_host or layer.owner == local_owner


func remove_layer(id: int) -> bool:
	var l := find(id)
	if l.is_empty() or not can_delete(l):
		return false
	return force_remove(id)


## Removes without a permission check (the host already decided).
func force_remove(id: int) -> bool:
	for i in layers.size():
		if layers[i].id == id:
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
		var k := int(floorf(from_beat / L)) - 1
		while k * L < to_beat:
			if l.kind == "audio":
				for i in l.clips.size():
					var cb: float = k * L + float(l.clips[i].get("at", 0.0))
					if cb >= from_beat and cb < to_beat:
						l.synth.clip_play(i, 1.0, Transport.frame_for(l.synth, cb), 0)
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
		force_remove(l.id)
	_next_id = 1
