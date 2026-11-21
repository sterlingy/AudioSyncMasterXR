extends Node
## The jam session. Autoloaded as `Session`.
##
## One player hosts (ENet server, clock master, owner of tempo and the master
## looper); up to five more join. Two paths:
##
## - **State** over ENet through the host, reliable: who is in the session,
##   each player's instrument and sound (all parameters, Tangle patch), their
##   sequencer pattern and finished loops, the tempo map, master-looper layers.
##   Sequencers and loops are then played on every client from the shared
##   clock, sample-accurately, so they add no network delay at all.
## - **Live notes** straight from player to player over UDP (no relay hop),
##   30-byte packets stamped with the shared-clock time they were played
##   (and, for live-quantized notes, the shared-clock time they should sound).
##   With the audio link (jamcore built with AOO) they travel on its socket
##   and are scheduled on its network thread straight into the remote
##   player's synth, so game frames never delay them. Without it, this
##   script's own UDP socket and _process do the same job.
##   The receiver plays each note at stamp + that sender's delay, where the
##   delay covers the 95th percentile of how late notes have arrived (network
##   plus frame polling), so timing between notes stays steady. With
##   `steady_timing` off, notes play the moment they arrive. Peers that can't
##   reach each other directly fall back to sending notes through the host.
##
## Audio (voice, mics, real instruments): each player sends one AOO stream
## to every other player (JamAudioLink, peer to peer, nothing mixed on a
## server); each remote player's stream plays through its own player, so it
## can sit at their avatar later. Off until the player turns "send my audio"
## on; receiving is always ready.
##
## Clock sync: clients ping the host on a dedicated UDP port (PORT + 1)
## handled by a thread that stamps packets on arrival (ClockLink), plus
## occasional pings over ENet as a fallback. ClockSync turns the exchanges
## into an offset that becomes Transport.clock_offset, so Transport.now() is
## the host's clock everywhere.

signal players_changed
signal status_changed(text: String)
## Host: a player suggested a tempo (only when approve_tempo is on).
signal tempo_suggested(id: int, who: String, bpm: float)
signal interval_changed(bars: int)

enum Role { OFFLINE, HOST, CLIENT }
enum Ev { ON, OFF, CC, BEND, HELLO, ACK }

const PORT := 47830
const MAX_PLAYERS := 6
const MAGIC := 0x314E5341 # "ASN1"
const PKT_SIZE := 30
const SNAPSHOT_KINDS := ["sound", "seq", "loop"]
const CH_NOTES := 1
const CH_CLOCK := 2
const CH_POSE := 3
const POSE_RATE := 30.0 # avatar poses sent per second
const MAX_NOTE_DELAY := 0.08
## Above this (sound from a player reaching your ear), suggest interval mode.
const HIGH_LATENCY_MS := 40.0
const MAX_INTERVAL_S := 8.0 # what the audio link can hold back

var role := Role.OFFLINE
var player_name := "Player"
var local_rig: InstrumentRig
var players := {} # peer id -> Dictionary; remote players also have "rig" and stats
var steady_timing := true
## Host: players' tempo changes wait for Accept (tempo_suggested); off = apply at once.
var approve_tempo := true
var suggestion := {} # host: the latest tempo suggestion {id, who, bpm}
## Interval mode (host decides for everyone): others' live parts play exactly
## this many bars after they were played, so they land in time. 0 = live.
var interval_bars := 0
## Online sessions (players on different networks): the connection server
## (server/asm_server.py) gives the host a room code and tells players each
## other's public addresses; everything else still goes player to player.
var server := ""
var room_code := ""
var rendezvous: Rendezvous
var my_pub_audio: Array = [] # [ip, port] of our audio socket as the internet sees it
var _t_reg := 0.0
var _reg_count := 0
var _rv_next := "" # what to ask the server next, after a short wait
var _t_rv := 0.0
var _host_tries := 0
var _local_pose := {} # head/left/right Transform3D, set by the XR rig each frame
var _local_pose_t := 0.0 # shared time it was set
var _t_pose := 0.0
var clock := ClockSync.new()
var status := "Not in a session"
var notes_received := 0

var audio: Object = null # JamAudioLink while in a session (null if jamcore was built without AOO)
var send_audio := false
## Audio mode: my instrument goes out as audio in my stream (for players
## whose device can't render every instrument); the others mute their copy.
var instrument_audio := false
var input_device := -1 # -1 = system default
var input_channel := -1 # -1 = mix all channels
var audio_buffer_ms := 15.0 # receive jitter buffer
var audio_codec := "pcm16"
var input_exclusive := false # WASAPI exclusive: ~3 ms instead of ~10 ms, but locks the device
var audio_error := ""
var _udp := PacketPeerUDP.new()
var _mic: AudioStreamPlayer # Godot microphone fallback where there's no native capture (Android for now)
var _mic_capture: AudioEffectCapture
var _link: ClockLink
var _host_ip := ""
var _sent_hash := {}
var _t_ping := 0.0
var _t_hello := 0.0
var _t_snap := 0.0
var _t_delay := 0.0
var _pings := 0
var _clock_locked := false


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): _fail("Couldn't reach the host."))
	multiplayer.server_disconnected.connect(func(): _fail("The host left the session."))
	MasterLooper.net = self
	MasterLooper.changed.connect(_update_audibility)
	Transport.state_dirty.connect(_on_transport_dirty)
	Transport.request.connect(_on_transport_request)
	Transport.tempo_changed.connect(_apply_interval.unbind(1))
	Transport.meter_changed.connect(_apply_interval.unbind(1))
	var saved: Variant = Settings.get_value("player_name")
	player_name = str(saved) if saved else "Player"
	input_channel = int(Settings.get_value("audio_channel"))
	input_exclusive = bool(Settings.get_value("audio_exclusive"))
	audio_buffer_ms = float(Settings.get_value("audio_buffer_ms"))
	audio_codec = str(Settings.get_value("audio_codec"))
	approve_tempo = bool(Settings.get_value("approve_tempo"))
	instrument_audio = bool(Settings.get_value("instrument_audio"))
	server = str(Settings.get_value("server"))
	Transport.click_volume_db = float(Settings.get_value("click_volume_db"))
	var dev_name := str(Settings.get_value("audio_device"))
	if dev_name != "" and ClassDB.class_exists("JamAudioLink"):
		input_device = Array(ClassDB.class_call_static("JamAudioLink", "get_input_devices")).find(dev_name)


func is_online() -> bool:
	return role != Role.OFFLINE


func is_host() -> bool:
	return role == Role.HOST


func my_id() -> int:
	return multiplayer.get_unique_id() if is_online() else 1


func bind_rig(rig: InstrumentRig) -> void:
	local_rig = rig
	rig.played.connect(_on_local_played)
	rig.looper.clip_added.connect(func(id): _send_clip(0, id))
	rig.instrument_changed.connect(func(t):
		if players.has(my_id()):
			players[my_id()].instrument = t
			players_changed.emit())


# ---- Joining and leaving

func host(port := PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		_set_status("Couldn't host on port %d: %s" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	_open_udp()
	_link = ClockLink.new()
	if _link.start_host(port + 1) != OK:
		_link = null # clients fall back to ENet pings
	role = Role.HOST
	Transport.follower = false
	MasterLooper.is_host = true
	MasterLooper.local_owner = "1"
	if _ensure_audio():
		audio.set_my_id(1)
		_apply_audio_input()
	players = {1: _local_info()}
	_set_status("Hosting on port %d. Others join with this computer's IP: %s" % [port, ", ".join(local_addresses())])
	players_changed.emit()
	return OK


func join(ip: String, port := PORT, clock_ep: Array = [], online := false) -> Error:
	leave(online)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		_set_status("Couldn't connect to %s: %s" % [ip, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	_open_udp()
	_link = ClockLink.new()
	var clock_ip: String = clock_ep[0] if clock_ep.size() == 2 else ip
	var clock_port: int = clock_ep[1] if clock_ep.size() == 2 else port + 1
	if _link.start_client(clock_ip, clock_port) != OK:
		_link = null
	role = Role.CLIENT
	_host_ip = ip
	Transport.follower = true
	MasterLooper.is_host = false
	clock.reset()
	_clock_locked = false
	_pings = 0
	_set_status("Connecting to %s…" % ip)
	return OK


func leave(keep_rendezvous := false) -> void:
	if rendezvous and not keep_rendezvous:
		rendezvous.close()
		rendezvous = null
		room_code = ""
		my_pub_audio = []
	for id in players.keys():
		if id != my_id():
			_remove_player(id)
	players.clear()
	if multiplayer.multiplayer_peer and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_udp.close()
	if audio:
		# The link stays (local input and its recording keep working offline).
		audio.set_sending(false)
		audio.set_my_id(1)
	if _link:
		_link.stop()
		_link = null
	role = Role.OFFLINE
	Transport.follower = false
	Transport.clock_offset = 0.0
	MasterLooper.is_host = true
	MasterLooper.local_owner = "me"
	_sent_hash.clear()
	if interval_bars != 0:
		_set_interval(0)
	_set_status("Not in a session")
	players_changed.emit()


func _fail(text: String) -> void:
	leave()
	_set_status(text)


func _on_connected() -> void:
	MasterLooper.local_owner = str(my_id())
	if _ensure_audio():
		audio.set_my_id(my_id())
		_apply_audio_input()
	players = {my_id(): _local_info()}
	rpc_id(1, "_hello", _local_info())
	_set_status("Connected to %s, syncing clocks…" % _host_ip)


func _on_peer_disconnected(id: int) -> void:
	if not players.has(id):
		return
	var who: String = players[id].name
	_remove_player(id)
	if is_host():
		rpc("_player_left", id)
	_set_status("%s left." % who)


func _local_info() -> Dictionary:
	return {"id": my_id(), "name": player_name, "instrument": local_rig.instrument if local_rig else "Undertow",
		"udp_port": _udp.get_local_port() if _udp.is_bound() else 0, "ip": "",
		"audio_port": audio.get_port() if audio else 0, "pub_audio": my_pub_audio}


func _public(p: Dictionary) -> Dictionary:
	return {"id": p.id, "name": p.name, "instrument": p.instrument, "udp_port": p.udp_port, "ip": p.ip,
		"audio_port": p.get("audio_port", 0), "pub_audio": p.get("pub_audio", [])}


func _clean_info(info: Dictionary, id: int) -> Dictionary:
	var inst := str(info.get("instrument", "Undertow"))
	if not inst in JamSynth.get_instrument_types():
		inst = "Undertow"
	return {"id": id, "name": str(info.get("name", "Player")).left(24), "instrument": inst,
		"udp_port": clampi(int(info.get("udp_port", 0)), 0, 65535), "ip": str(info.get("ip", "")),
		"audio_port": clampi(int(info.get("audio_port", 0)), 0, 65535), "pub_audio": _clean_ep(info.get("pub_audio", []))}


static func _clean_ep(v: Variant) -> Array:
	if typeof(v) == TYPE_ARRAY and v.size() == 2 and str(v[0]).is_valid_ip_address():
		return [str(v[0]), clampi(int(v[1]), 1, 65535)]
	return []


@rpc("any_peer", "reliable")
func _hello(info: Dictionary) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if players.size() >= MAX_PLAYERS:
		rpc_id(id, "_refused", "The session is full (%d players)." % MAX_PLAYERS)
		return
	info = _clean_info(info, id)
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	info.ip = enet.get_peer(id).get_remote_address()
	var list := []
	for p in players.values():
		list.append(_public(p))
	rpc_id(id, "_welcome", list, Transport.get_state(), MasterLooper.export_layers())
	rpc_id(id, "_interval", interval_bars)
	for other in players:
		if other != 1:
			rpc_id(other, "_player_joined", info)
	_add_remote(info)
	_send_snapshots(id)
	_set_status("%s joined." % info.name)


@rpc("authority", "reliable")
func _refused(reason: String) -> void:
	_fail(reason)


@rpc("authority", "reliable")
func _welcome(list: Array, transport: Dictionary, master: Array) -> void:
	for info in list:
		var id := int(info.get("id", 0))
		if id == my_id() or id <= 0:
			continue
		var clean := _clean_info(info, id)
		if clean.ip == "" or (clean.ip == "127.0.0.1" and id != 1 and _host_ip != "127.0.0.1"):
			clean.ip = _host_ip
		_add_remote(clean)
	Transport.apply_state(transport)
	MasterLooper.import_layers(master)
	_send_snapshots(0)
	_set_status("In %s's session (%d players)." % [players.get(1, {}).get("name", "the host"), players.size()])


@rpc("authority", "reliable")
func _player_joined(info: Dictionary) -> void:
	var id := int(info.get("id", 0))
	if id <= 0 or id == my_id():
		return
	var clean := _clean_info(info, id)
	if clean.ip == "127.0.0.1" and _host_ip != "127.0.0.1":
		clean.ip = _host_ip
	_add_remote(clean)
	_send_snapshots(id)
	_set_status("%s joined." % clean.name)


@rpc("authority", "reliable")
func _player_left(id: int) -> void:
	if players.has(id):
		var who: String = players[id].name
		_remove_player(id)
		_set_status("%s left." % who)


func _add_remote(info: Dictionary) -> void:
	if players.has(info.id):
		return
	var rig := InstrumentRig.new()
	rig.local_input = false
	rig.remote = true
	rig.instrument = info.instrument
	rig.name = "Player%d" % info.id
	add_child(rig)
	var p := info.duplicate()
	p.merge({"rig": rig, "volume_db": 0.0, "muted": false, "rtt": -1.0, "lateness": [], "delay": 0.0,
		"direct_in": false, "direct_out": false, "shift": {}, "last_late": 0.0, "voice": null})
	players[info.id] = p
	_connect_audio(p)
	_update_audibility()
	players_changed.emit()


func _remove_player(id: int) -> void:
	var p: Dictionary = players.get(id, {})
	if p.has("rig"):
		p.rig.synth.all_notes_off()
		p.rig.queue_free()
	if p.get("voice"):
		p.voice.queue_free()
	if audio and p.has("rig"):
		audio.remove_peer(id)
	players.erase(id)
	players_changed.emit()


func _set_status(t: String) -> void:
	status = t
	status_changed.emit(t)


static func local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


# ---- Per-player mix

func set_volume(id: int, db: float) -> void:
	if players.has(id):
		players[id].volume_db = db
		_update_audibility()


func toggle_mute(id: int) -> void:
	if players.has(id):
		players[id].muted = not players[id].get("muted", false)
		_update_audibility()
		players_changed.emit()


func _update_audibility() -> void:
	for id in players:
		var p: Dictionary = players[id]
		if not p.has("rig"):
			continue
		var silent: bool = p.muted or MasterLooper.listen == MasterLooper.Listen.OWN_ONLY
		p.rig.set_volume_db(-80.0 if silent else p.volume_db)
		if p.get("audio_mode", false):
			p.rig.player.volume_db = -80.0 # their instrument arrives in their audio stream
		if p.voice:
			p.voice.volume_db = -80.0 if silent else p.volume_db
		p.rig.looper.silenced = MasterLooper.listen != MasterLooper.Listen.MASTER_AND_LIVE


# ---- Snapshots (sound, sequencer, loops)

func _snapshot_data(kind: String) -> Variant:
	match kind:
		"sound":
			return {"instrument": local_rig.instrument, "params": local_rig.synth.get_params(), "audio_mode": instrument_audio}
		"seq":
			return local_rig.sequencer.to_dict()
		"loop":
			return local_rig.looper.to_net()
	return null


## Sends this player's snapshots to one peer, or to everyone with id 0.
func _send_snapshots(id: int) -> void:
	if local_rig == null:
		return
	for clip_id in local_rig.looper.used_clips():
		_send_clip(id, clip_id)
	for kind in SNAPSHOT_KINDS:
		var d: Variant = _snapshot_data(kind)
		if id == 0:
			_sent_hash[kind] = hash(var_to_bytes(d))
			rpc("_snapshot", kind, d)
		else:
			rpc_id(id, "_snapshot", kind, d)


func _check_snapshots() -> void:
	if local_rig == null or players.size() < 2:
		return
	for kind in SNAPSHOT_KINDS:
		var d: Variant = _snapshot_data(kind)
		var h := hash(var_to_bytes(d))
		if _sent_hash.get(kind, 0) != h:
			_sent_hash[kind] = h
			rpc("_snapshot", kind, d)


@rpc("any_peer", "reliable")
func _snapshot(kind: String, data: Variant) -> void:
	var p: Dictionary = players.get(multiplayer.get_remote_sender_id(), {})
	if not p.has("rig"):
		return
	var rig: InstrumentRig = p.rig
	match kind:
		"sound":
			if typeof(data) != TYPE_DICTIONARY:
				return
			var inst := str(data.get("instrument", ""))
			if inst in JamSynth.get_instrument_types() and inst != rig.instrument:
				rig.set_instrument(inst)
				p.instrument = inst
				p.erase("patch_sig")
				players_changed.emit()
			if typeof(data.get("params")) == TYPE_DICTIONARY:
				apply_sound(rig, data.params, p)
			var am := bool(data.get("audio_mode", false))
			if am != p.get("audio_mode", false):
				p.audio_mode = am
				_update_audibility()
				players_changed.emit()
		"seq":
			if typeof(data) == TYPE_DICTIONARY:
				rig.sequencer.from_dict(data)
		"loop":
			if typeof(data) == TYPE_ARRAY:
				rig.looper.apply_net(data)


## Applies a sound snapshot. A Tangle patch is only rebuilt when its modules
## or cables changed; knob moves on modules are applied in place, so the
## remote synth keeps sounding (rebuilding would reset envelopes and delays).
static func apply_sound(rig: InstrumentRig, params: Dictionary, memo: Dictionary) -> void:
	var rest := params.duplicate()
	var patch: Variant = rest.get("patch")
	rest.erase("patch")
	rig.synth.set_params(rest)
	if typeof(patch) != TYPE_DICTIONARY or rig.instrument != "Tangle":
		return
	var shape := []
	for m in patch.get("modules", []):
		shape.append([int(m.get("id", -1)), str(m.get("type", ""))])
	var sig := hash([shape, patch.get("cables", [])])
	if memo.get("patch_sig", 0) != sig:
		memo.patch_sig = sig
		rig.synth.tangle_set_patch(patch)
		return
	for m in patch.get("modules", []):
		var ps: Dictionary = m.get("params", {})
		for k in ps:
			if not is_equal_approx(rig.synth.tangle_get_param(int(m.id), k), float(ps[k])):
				rig.synth.tangle_set_param(int(m.id), k, float(ps[k]))


## Sends one of our audio-loop clips (float samples, zstd) to one peer or all (0).
func _send_clip(to: int, clip_id: int) -> void:
	if not is_online() or players.size() < 2 or not local_rig.looper.clips.has(clip_id):
		return
	var c: Dictionary = local_rig.looper.clips[clip_id]
	var raw: PackedByteArray = c.samples.to_byte_array()
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	if to == 0:
		rpc("_clip", clip_id, packed, raw.size(), int(c.rate))
	else:
		rpc_id(to, "_clip", clip_id, packed, raw.size(), int(c.rate))


@rpc("any_peer", "reliable")
func _clip(clip_id: int, packed: PackedByteArray, size: int, rate: int) -> void:
	var p: Dictionary = players.get(multiplayer.get_remote_sender_id(), {})
	if not p.has("rig") or size <= 0 or size > 48000 * 4 * 120 or rate < 8000 or rate > 192000:
		return
	var samples := packed.decompress(size, FileAccess.COMPRESSION_ZSTD).to_float32_array()
	p.rig.looper.add_clip(samples, rate, clip_id)


@rpc("any_peer", "unreliable_ordered", "call_remote", CH_NOTES)
func _param(id: String, value: float) -> void:
	var p: Dictionary = players.get(multiplayer.get_remote_sender_id(), {})
	if p.has("rig"):
		p.rig.set_param(id, value)


# ---- Transport

func _on_transport_dirty() -> void:
	if is_host() and players.size() > 1:
		rpc("_transport", Transport.get_state())


func _on_transport_request(action: String, value: Variant) -> void:
	if role == Role.CLIENT:
		rpc_id(1, "_transport_request", action, value if value != null else 0)


@rpc("authority", "reliable")
func _transport(state: Dictionary) -> void:
	Transport.apply_state(state)


@rpc("any_peer", "reliable")
func _transport_request(action: String, value: Variant) -> void:
	if not is_host():
		return
	match action:
		"start":
			Transport.start()
		"stop":
			Transport.stop()
		"tempo":
			var id := multiplayer.get_remote_sender_id()
			var b := clampf(float(value), 30.0, 300.0)
			if approve_tempo:
				var who: String = players.get(id, {}).get("name", "A player")
				suggestion = {"id": id, "who": who, "bpm": b}
				tempo_suggested.emit(id, who, b)
			else:
				Transport.set_tempo(b)
		"meter":
			Transport.set_beats_per_bar(int(value))


# ---- Online (connection server)

## Hosts as usual (LAN players can still join by IP) and gets a room code
## from the connection server for players elsewhere.
func host_online(port := PORT) -> Error:
	var err := host(port)
	if err != OK:
		return err
	rendezvous = Rendezvous.new()
	var e := rendezvous.open(server)
	if e != "":
		rendezvous = null
		_set_status(status + "  " + e)
		return ERR_CANT_CONNECT
	rendezvous.start_host()
	_set_status("Getting a room code from %s…" % server)
	return OK


## Joins a room by its code through the connection server.
func join_online(code: String) -> Error:
	leave()
	rendezvous = Rendezvous.new()
	var e := rendezvous.open(server)
	if e != "":
		rendezvous = null
		_set_status(e)
		return ERR_CANT_CONNECT
	_ensure_audio()
	rendezvous.start_join(code)
	_host_tries = 0
	_set_status("Looking for room %s…" % code.strip_edges().to_upper())
	return OK


func set_server(addr: String) -> void:
	server = addr.strip_edges()
	Settings.set_value("server", server)


func _poll_rendezvous(delta: float) -> void:
	var rv := rendezvous
	match rv.poll(delta):
		"hosted":
			room_code = rv.room
			_register_sockets()
			_later("me")
			_set_status("Hosting online. Room code: %s  (players elsewhere press Join online and type it; on this network they can also join by IP: %s)" % [room_code, ", ".join(local_addresses())])
			players_changed.emit()
		"joined":
			_register_sockets() # the audio socket exists already
			_later("host")
		"host_eps":
			if rv.host_eps.has("enet") and rv.host_eps.has("clock"):
				_later("me")
			elif _host_tries < 10:
				_host_tries += 1
				_later("host") # the host's sockets haven't registered yet
			else:
				_fail("Room %s's host can't be reached." % rv.room)
		"my_eps":
			my_pub_audio = rv.my_eps.get("audio", [])
			if is_host():
				players[1].pub_audio = my_pub_audio
			elif role == Role.OFFLINE:
				_connect_online()
		"punch":
			for req in rv.punch_requests:
				_punch(req.eps)
			rv.punch_requests.clear()
		"error":
			if role == Role.OFFLINE:
				var msg := rv.error
				leave()
				_set_status(msg)
			else:
				_set_status(status + "  (" + rv.error + ")")
	if rendezvous == null:
		return
	if _rv_next != "":
		_t_rv -= delta
		if _t_rv <= 0.0:
			if _rv_next == "host":
				rendezvous.fetch_host()
			else:
				rendezvous.fetch_mine()
			_rv_next = ""
	if rendezvous.token != "":
		_t_reg -= delta
		if _t_reg <= 0.0:
			_t_reg = 1.0 if _reg_count < 8 else 15.0
			_reg_count += 1
			_register_sockets()


func _later(what: String) -> void:
	_rv_next = what
	_t_rv = 0.3 # let the registrations land first


func _connect_online() -> void:
	var e := rendezvous.host_eps
	_set_status("Connecting to room %s…" % rendezvous.room)
	if join(e.enet[0], e.enet[1], e.clock, true) != OK:
		return
	_reg_count = 0
	_register_sockets() # the host is told our addresses and opens its side


## Each socket tells the server where it is (and keeps its router mapping open).
func _register_sockets() -> void:
	if rendezvous == null or rendezvous.token == "":
		return
	var ip := rendezvous.server_ip
	var port := rendezvous.server_port
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet and enet.host:
		enet.host.socket_send(ip, port, rendezvous.register_packet("enet"))
	if _link:
		_link.send_raw(ip, port, rendezvous.register_packet("clock"))
	if audio:
		audio.send_raw(ip, port, rendezvous.register_packet("audio"))


## Host: sends toward a joiner's public addresses so our router lets their packets in.
func _punch(eps: Dictionary) -> void:
	var pkt := "ASMP".to_ascii_buffer()
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	for i in 3:
		if eps.has("enet") and enet and enet.host:
			enet.host.socket_send(eps.enet[0], eps.enet[1], pkt)
		if eps.has("clock") and _link:
			_link.send_raw(eps.clock[0], eps.clock[1], pkt)
		if eps.has("audio") and audio:
			audio.send_raw(eps.audio[0], eps.audio[1], pkt)


# ---- Avatars

## Called by the XR rig every frame with this player's head and hands
## (play-space transforms). Sent to the others at POSE_RATE.
func set_local_pose(head: Transform3D, left: Transform3D, right: Transform3D) -> void:
	_local_pose = {"head": head, "left": left, "right": right}
	_local_pose_t = Transport.now()


func clear_local_pose() -> void:
	_local_pose = {}


@rpc("any_peer", "unreliable_ordered", "call_remote", CH_POSE)
func _pose(t: float, packed: PackedFloat32Array) -> void:
	var p: Dictionary = players.get(multiplayer.get_remote_sender_id(), {})
	if not p.has("rig"):
		return
	if not p.has("poses"):
		p.poses = PoseBuffer.new()
	p.poses.add(t, packed)


## How far behind a remote avatar is shown: when that player's sound reaches
## your ear. Their streamed audio (voice, real instrument, audio mode) if they
## send any, else their live notes; the full interval in interval mode.
func avatar_delay(p: Dictionary) -> float:
	if interval_bars > 0:
		return interval_seconds()
	var out_lat := AudioServer.get_output_latency()
	var st: Dictionary = p.get("native", {})
	if st.get("streaming", false) and float(st.get("audio_delay_ms", -1.0)) > 0.0:
		return float(st.audio_delay_ms) / 1000.0 + out_lat
	var delay: float = st.note_delay_ms / 1000.0 if st.has("note_delay_ms") else float(p.get("delay", 0.0))
	var last: float = st.last_late_ms / 1000.0 if st.has("last_late_ms") else float(p.get("last_late", 0.0))
	return (delay if steady_timing else maxf(last, 0.0)) + out_lat


## A remote player's head/left/right as you should see them now ({} if none).
func remote_pose(id: int) -> Dictionary:
	var p: Dictionary = players.get(id, {})
	if not p.has("poses"):
		return {}
	return p.poses.sample(Transport.now() - avatar_delay(p))


# ---- Interval mode

## Seconds that others' live parts are held back (0 in live mode).
func interval_seconds() -> float:
	if interval_bars <= 0:
		return 0.0
	return minf(interval_bars * Transport.beats_per_bar * 60.0 / Transport.bpm, MAX_INTERVAL_S)


## Live (0) or interval mode with 1-2 bars. Clients ask the host.
func set_interval_bars(n: int) -> void:
	n = clampi(n, 0, 2)
	if role == Role.CLIENT:
		rpc_id(1, "_interval_request", n)
		return
	_set_interval(n)
	if is_host() and players.size() > 1:
		rpc("_interval", n)


@rpc("authority", "reliable")
func _interval(n: int) -> void:
	_set_interval(n)


@rpc("any_peer", "reliable")
func _interval_request(n: int) -> void:
	if is_host():
		set_interval_bars(n)


func _set_interval(n: int) -> void:
	interval_bars = clampi(n, 0, 2)
	_apply_interval()
	interval_changed.emit(interval_bars)


func _apply_interval() -> void:
	if audio:
		audio.set_interval(interval_seconds())


## The remote player whose sound reaches you latest: {name, ms} (ms = -1 if nobody).
func worst_latency() -> Dictionary:
	var out := {"name": "", "ms": -1.0}
	for id in players:
		var p: Dictionary = players[id]
		if not p.has("rig"):
			continue
		var ms := ear_ms(p)
		if ms > float(out.ms):
			out = {"name": p.name, "ms": ms}
	return out


## How late a player's live notes (or measured audio, if later) reach your ear in live mode.
func ear_ms(p: Dictionary) -> float:
	var delay: float = p.delay
	var last: float = p.last_late
	if p.has("native"):
		delay = p.native.note_delay_ms / 1000.0
		last = p.native.last_late_ms / 1000.0
	var ms: float = ((delay if steady_timing else maxf(last, 0.0)) + AudioServer.get_output_latency()) * 1000.0
	if p.has("native") and float(p.native.get("mouth_to_ear_ms", -1.0)) > 0.0 and interval_bars == 0:
		ms = maxf(ms, float(p.native.mouth_to_ear_ms))
	return ms


## Host: applies (true) or drops the pending tempo suggestion.
func answer_suggestion(accept: bool) -> void:
	if accept and not suggestion.is_empty() and is_host():
		Transport.set_tempo(float(suggestion.bpm))
	suggestion = {}


# ---- Master looper

func master_push(data: Dictionary) -> void:
	if is_host():
		_master_add_from(1, data)
	else:
		rpc_id(1, "_master_push", data)


func master_remove(id: int) -> void:
	if is_host():
		_master_remove_from(1, id)
	else:
		rpc_id(1, "_master_remove", id)


@rpc("any_peer", "reliable")
func _master_push(data: Dictionary) -> void:
	if is_host():
		_master_add_from(multiplayer.get_remote_sender_id(), data)


@rpc("any_peer", "reliable")
func _master_remove(id: int) -> void:
	if is_host():
		_master_remove_from(multiplayer.get_remote_sender_id(), id)


func _master_add_from(owner: int, data: Dictionary) -> void:
	var who: String = players.get(owner, {}).get("name", "?")
	var id := MasterLooper.add_layer(data, str(owner), -1, who)
	if id > 0:
		rpc("_master_layer", MasterLooper.export_layer(MasterLooper.find(id)))


func _master_remove_from(sender: int, id: int) -> void:
	var l := MasterLooper.find(id)
	if l.is_empty() or (sender != 1 and l.owner != str(sender)):
		return
	MasterLooper.force_remove(id)
	rpc("_master_removed", id)


@rpc("authority", "reliable")
func _master_layer(d: Dictionary) -> void:
	MasterLooper.import_layer(d)


@rpc("authority", "reliable")
func _master_removed(id: int) -> void:
	MasterLooper.force_remove(id)


# ---- Clock sync

@rpc("any_peer", "unreliable", "call_remote", CH_CLOCK)
func _ping(t0: float) -> void:
	if is_host():
		rpc_id(multiplayer.get_remote_sender_id(), "_pong", t0, Transport.now())
		_flush()


@rpc("authority", "unreliable", "call_remote", CH_CLOCK)
func _pong(t0: float, t1: float) -> void:
	_clock_sample(t0, t1, JamSynth.get_time())


func _clock_sample(t0: float, t1: float, t2: float) -> void:
	clock.add(t0, t1, t2)
	if not clock.ready():
		return
	var diff := clock.offset - Transport.clock_offset
	if not _clock_locked or absf(diff) > 0.02:
		Transport.clock_offset = clock.offset
		if not _clock_locked:
			_clock_locked = true
			_set_status("In %s's session (%d players). Clock synced %s." % [players.get(1, {}).get("name", "the host"), players.size(), clock_text()])
	else:
		# Slew small corrections so scheduled beats don't jump.
		Transport.clock_offset += clampf(diff, -0.0005, 0.0005)


# ---- Live notes

func _on_local_played(e: Dictionary) -> void:
	if players.size() < 2:
		return
	match e.type:
		"on":
			_send_event(Ev.ON, e.note, e.velocity, Transport.time_at(e.beat) if e.get("quantized", false) else NAN)
		"off":
			_send_event(Ev.OFF, e.note, 0.0)
		"cc":
			_send_event(Ev.CC, e.cc, e.value)
		"bend":
			_send_event(Ev.BEND, 0, e.value)
		"param":
			rpc("_param", e.id, e.value)


static func pack(sender: int, type: int, a: int, value: float, t: float, at := NAN) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(PKT_SIZE)
	b.encode_u32(0, MAGIC)
	b.encode_u32(4, sender)
	b[8] = type
	b[9] = a & 0xff
	b.encode_float(10, value)
	b.encode_double(14, t)
	b.encode_double(22, at)
	return b


static func unpack(b: PackedByteArray) -> Dictionary:
	if b.size() != PKT_SIZE or b.decode_u32(0) != MAGIC:
		return {}
	return {"from": b.decode_u32(4), "type": b[8], "a": b[9], "value": b.decode_float(10),
		"t": b.decode_double(14), "at": b.decode_double(22)}


func _send_event(type: int, a: int, value: float, at := NAN) -> void:
	if audio:
		audio.send_event(type, a, value, at) # straight to every peer from the native socket
	var pkt := pack(my_id(), type, a, value, Transport.now(), at)
	for id in players:
		var p: Dictionary = players[id]
		if id == my_id():
			continue
		if audio:
			if not p.direct_out:
				rpc_id(id, "_relay", pkt)
		elif p.direct_out:
			_udp.set_dest_address(p.ip, p.udp_port)
			_udp.put_packet(pkt)
		else:
			rpc_id(id, "_relay", pkt)
	_flush()


@rpc("any_peer", "unreliable_ordered", "call_remote", CH_NOTES)
func _relay(pkt: PackedByteArray) -> void:
	var e := unpack(pkt)
	if not e.is_empty() and e.from == multiplayer.get_remote_sender_id():
		_on_event(e, "", 0)


func _open_udp() -> void:
	_udp.close()
	_udp.bind(0)


func _poll_udp() -> void:
	while _udp.is_bound() and _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var e := unpack(pkt)
		if not e.is_empty():
			_on_event(e, _udp.get_packet_ip(), _udp.get_packet_port())


func _on_event(e: Dictionary, ip: String, port: int) -> void:
	var p: Dictionary = players.get(int(e.from), {})
	if not p.has("rig"):
		return
	match e.type:
		Ev.HELLO:
			p.direct_in = true
			if ip != "":
				# Answer (and send notes) to where the packets really come from.
				var moved: bool = p.ip != ip
				p.ip = ip
				p.udp_port = port
				if moved:
					_connect_audio(p)
				_udp.set_dest_address(ip, port)
				_udp.put_packet(pack(my_id(), Ev.ACK, 0, 0.0, e.t))
		Ev.ACK:
			p.direct_out = true
			p.rtt = Transport.now() - e.t
		_:
			_play_remote(p, e)


## Plays a remote player's live event at its stamp + that player's delay.
func _play_remote(p: Dictionary, e: Dictionary) -> void:
	var rig: InstrumentRig = p.rig
	var now := Transport.now()
	var late: float = now - e.t
	p.last_late = late
	var iv := interval_seconds()
	var out_lat := AudioServer.get_output_latency()
	var when: float = e.t + iv - out_lat if iv > 0.0 else e.t + (p.delay if steady_timing else 0.0)
	match e.type:
		Ev.ON:
			notes_received += 1
			p.lateness.append(late)
			if p.lateness.size() > 64:
				p.lateness.pop_front()
			var target := when
			if not is_nan(e.at):
				target = maxf(when, e.at + iv - out_lat)
			p.shift[e.a] = target - when
			rig.synth.note_on(e.a, e.value, _frame(rig, target, now))
		Ev.OFF:
			var target: float = when + p.shift.get(e.a, 0.0)
			p.shift.erase(e.a)
			rig.synth.note_off(e.a, _frame(rig, target, now))
		Ev.CC:
			rig.synth.control_change(e.a, e.value, _frame(rig, when, now))
		Ev.BEND:
			rig.synth.pitch_bend(e.value, _frame(rig, when, now))


func _frame(rig: InstrumentRig, t: float, now: float) -> int:
	if t <= now:
		return -1
	return rig.synth.time_to_frame(t - Transport.clock_offset)


## Steady-timing delay from recent arrival lateness: 95th percentile + 2 ms.
static func delay_from(lateness: Array) -> float:
	if lateness.is_empty():
		return 0.0
	var s := lateness.duplicate()
	s.sort()
	return clampf(float(s[int(0.95 * (s.size() - 1))]) + 0.002, 0.0, MAX_NOTE_DELAY)


# ---- Housekeeping

func _flush() -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet and enet.host:
		enet.host.flush()


func _process(delta: float) -> void:
	if _mic_capture and audio:
		var n := _mic_capture.get_frames_available()
		if n > 0:
			audio.push_input(_mic_capture.get_buffer(n), int(AudioServer.get_mix_rate()))
	if rendezvous:
		_poll_rendezvous(delta)
	if not is_online():
		return
	_poll_udp()
	if audio:
		audio.poll()
	_t_ping -= delta
	if role == Role.CLIENT and _t_ping <= 0.0 and multiplayer.get_unique_id() != 1 and \
			multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_t_ping = 0.1 if _pings < 30 else 1.0
		_pings += 1
		if _link:
			_link.ping()
		if _link == null or _pings % 5 == 0:
			rpc_id(1, "_ping", JamSynth.get_time())
			_flush()
	if _link:
		_link.host_offset = Transport.clock_offset
		for smp in _link.take_samples():
			_clock_sample(smp[0], smp[1], smp[2])
	if audio:
		audio.set_clock(Transport.clock_offset, AudioServer.get_output_latency())
		audio.set_steady_timing(steady_timing)
	_t_hello -= delta
	if _t_hello <= 0.0:
		_t_hello = 0.5
		for id in players:
			var p: Dictionary = players[id]
			if audio and p.has("rig"):
				var st: Dictionary = audio.get_peer_stats(id)
				if not st.is_empty():
					p.direct_in = st.direct_in
					p.direct_out = st.direct_out
					p.rtt = st.note_rtt_ms / 1000.0
					p.native = st
				continue
			if p.has("rig") and p.udp_port > 0 and p.ip != "":
				_udp.set_dest_address(p.ip, p.udp_port)
				_udp.put_packet(pack(my_id(), Ev.HELLO, 0, 0.0, Transport.now()))
	_t_delay -= delta
	if _t_delay <= 0.0:
		_t_delay = 1.0
		for p in players.values():
			if p.has("rig"):
				p.delay = delay_from(p.lateness)
	_t_pose -= delta
	if _t_pose <= 0.0 and not _local_pose.is_empty() and players.size() > 1:
		_t_pose = 1.0 / POSE_RATE
		rpc("_pose", _local_pose_t, PoseBuffer.pack(_local_pose))
	_t_snap -= delta
	if _t_snap <= 0.0:
		_t_snap = 0.25
		_check_snapshots()


# ---- Audio streams

## The audio link: made on first use (input turned on, or a session), then
## kept, so audio input and its recording (audio loops) work offline too.
func _ensure_audio() -> bool:
	if audio:
		return true
	if not ClassDB.class_exists("JamAudioLink"):
		audio_error = "Audio input isn't in this build."
		return false
	audio = ClassDB.instantiate("JamAudioLink")
	if audio.start(0, my_id()) != OK:
		audio_error = "Couldn't open a port for audio."
		audio = null
		return false
	audio.set_latency_ms(audio_buffer_ms)
	audio.set_codec(audio_codec)
	audio.set_interval(interval_seconds())
	return true


## Starts receiving a remote player's stream (and sending ours to them).
func _connect_audio(p: Dictionary) -> void:
	if audio == null or p.get("audio_port", 0) <= 0 or p.ip == "":
		return
	var ip: String = p.ip
	var port: int = p.audio_port
	var pub: Array = p.get("pub_audio", [])
	if pub.size() == 2 and my_pub_audio.size() == 2 and pub[0] != my_pub_audio[0]:
		ip = pub[0] # different networks: their router's address (hole punched by our HELLOs)
		port = pub[1]
	audio.add_peer(p.id, ip, port)
	if p.voice == null:
		p.voice = AudioStreamPlayer.new()
		p.voice.name = "Voice%d" % p.id
		add_child(p.voice)
	p.voice.stream = audio.get_peer_stream(p.id)
	p.voice.play()
	audio.route_notes(p.id, p.rig.synth)
	_update_audibility()


func set_send_audio(on: bool) -> void:
	send_audio = on
	_apply_audio_input()


func set_instrument_audio(on: bool) -> void:
	instrument_audio = on
	Settings.set_value("instrument_audio", on)
	_apply_audio_input()


func set_input(device: int, channel: int, exclusive := input_exclusive) -> void:
	input_device = device
	input_channel = channel
	input_exclusive = exclusive
	var names: PackedStringArray = ClassDB.class_call_static("JamAudioLink", "get_input_devices") if ClassDB.class_exists("JamAudioLink") else PackedStringArray()
	Settings.set_value("audio_device", names[device] if device >= 0 and device < names.size() else "")
	Settings.set_value("audio_channel", channel)
	Settings.set_value("audio_exclusive", exclusive)
	if audio and audio.is_capturing():
		audio.stop_capture()
	_apply_audio_input()


func set_audio_buffer_ms(ms: float) -> void:
	audio_buffer_ms = ms
	Settings.set_value("audio_buffer_ms", ms)
	if audio:
		audio.set_latency_ms(ms)


func set_audio_codec(codec: String) -> void:
	audio_codec = codec
	Settings.set_value("audio_codec", codec)
	if audio:
		audio.set_codec(codec)


## `send_audio` is "my audio input is on": captured always (meter, audio
## loops), and sent to the others while in a session.
func _apply_audio_input() -> void:
	if instrument_audio and local_rig and _ensure_audio():
		audio.set_instrument_audio(local_rig.synth)
	elif audio and audio.is_instrument_audio():
		audio.set_instrument_audio(null)
	if not send_audio:
		if audio:
			audio.set_sending(is_online() and instrument_audio)
			audio.stop_capture()
		_stop_godot_mic()
		return
	if not _ensure_audio():
		return
	audio_error = ""
	if audio.has_native_capture():
		if not audio.is_capturing() and audio.start_capture(input_device, input_channel, input_exclusive) != OK:
			audio_error = "Input didn't start: " + audio.get_capture_error()
			return
	elif not _start_godot_mic():
		return
	audio.set_sending(is_online())


## Fallback input: Godot's microphone on a silent bus with a capture effect,
## pushed into the audio link every frame (adds up to a frame of latency).
func _start_godot_mic() -> bool:
	if _mic:
		return true
	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		audio_error = "Audio input is disabled on this platform (audio/driver/enable_input)."
		return false
	if OS.get_name() == "Android" and not "android.permission.RECORD_AUDIO" in OS.get_granted_permissions():
		OS.request_permissions()
		audio_error = "Allow microphone access, then turn audio input on again."
		return false
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "JamMicIn")
	_mic_capture = AudioEffectCapture.new()
	_mic_capture.buffer_length = 0.5
	AudioServer.add_bus_effect(bus, _mic_capture)
	AudioServer.set_bus_mute(bus, true) # captured, never heard (direct monitoring)
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = "JamMicIn"
	add_child(_mic)
	_mic.play()
	return true


func _stop_godot_mic() -> void:
	if _mic == null:
		return
	_mic.queue_free()
	_mic = null
	var bus := AudioServer.get_bus_index("JamMicIn")
	if bus >= 0:
		AudioServer.remove_bus(bus)
	_mic_capture = null


func clock_text() -> String:
	var e := clock.error_bound() * 1000.0
	return "to within 0.1 ms" if e < 0.1 else "to ±%.1f ms" % e


## Live notes received from all players (native path + script path).
func total_notes_received() -> int:
	var n := notes_received
	if audio:
		for id in players:
			if players[id].has("rig"):
				n += int(audio.get_peer_stats(id).get("notes", 0))
	return n


## One line per remote player for the latency display.
func latency_text(p: Dictionary) -> String:
	if not p.has("rig"):
		return "you" + (" (host)" if is_host() else "")
	var parts := []
	parts.append("ping %s" % ("%.1f ms" % (p.rtt * 1000.0) if p.rtt >= 0.0 else "…"))
	if interval_bars > 0:
		parts.append("heard %d bar%s later (%.0f ms)" % [interval_bars, "" if interval_bars == 1 else "s", interval_seconds() * 1000.0])
	else:
		var delay: float = p.delay
		var last: float = p.last_late
		if p.has("native"):
			delay = p.native.note_delay_ms / 1000.0
			last = p.native.last_late_ms / 1000.0
		var ear: float = (delay if steady_timing else maxf(last, 0.0)) + AudioServer.get_output_latency()
		parts.append("notes reach you in %.0f ms" % (ear * 1000.0))
	if not p.direct_out:
		parts.append("via host")
	if audio:
		var st: Dictionary = audio.get_peer_stats(p.id)
		if st.get("streaming", false) and interval_bars == 0:
			var m2e: float = st.get("mouth_to_ear_ms", -1.0)
			if m2e > 0.0:
				parts.append("audio %.0f ms mic to ear" % m2e)
			else:
				var one_way: float = maxf(st.get("rtt_ms", 0.0), 0.0) * 0.5
				parts.append("audio ~%.0f ms" % (one_way + audio_buffer_ms + AudioServer.get_output_latency() * 1000.0))
			if int(st.get("underruns", 0)) > 0:
				parts.append("%d dropouts" % int(st.underruns))
	return "  •  ".join(parts)
