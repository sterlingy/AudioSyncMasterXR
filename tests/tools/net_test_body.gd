extends Node
## Body of tests/tools/net_test.gd (loaded at runtime so the autoloads exist).

const PORT := 47931
const SKEW := 3.217
const NOTES := 24

var channel: Node
var is_client := false
var failures := []


func _ready() -> void:
	is_client = "--client" in OS.get_cmdline_user_args()
	channel = preload("res://tests/tools/net_test_channel.gd").new()
	channel.name = "NetTestChannel"
	get_tree().root.add_child.call_deferred(channel)
	await get_tree().process_frame
	await get_tree().process_frame
	if is_client:
		_client.call_deferred()
	else:
		_host.call_deferred()


static func clock_epoch() -> float:
	# Wall-clock time at which this process's JamSynth clock read 0. Both
	# processes share the wall clock, so this gives the true offset. The
	# wall clock may tick coarsely (1 ms), so stamp the moment it ticks.
	var es := []
	for k in 5:
		var u0 := Time.get_unix_time_from_system()
		var u := u0
		var a := 0.0
		while u == u0:
			a = JamSynth.get_time()
			u = Time.get_unix_time_from_system()
		var b := JamSynth.get_time()
		es.append(u - (a + b) * 0.5)
	es.sort()
	return es[2]


func make_rig(type: String) -> InstrumentRig:
	var rig := InstrumentRig.new()
	rig.instrument = type
	get_tree().root.add_child(rig)
	Session.bind_rig(rig)
	return rig


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures.append(what)


func wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func wait_until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	return cond.call()


# ---- Host

func _host() -> void:
	MasterLooper.audio_out = false
	var rig := make_rig("Pulsar")
	Session.player_name = "Host"
	if Session.host(PORT) != OK:
		print("can't host")
		get_tree().quit(2)
		return
	Transport.clock_offset = SKEW
	var exe := OS.get_executable_path()
	var pid := OS.create_process(exe, ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://tests/tools/net_test.gd", "--", "--client"])
	print("host: started client process ", pid)
	var joined := await wait_until(func(): return Session.players.size() == 2, 20.0)
	check(joined, "client joined")
	if not joined:
		OS.kill(pid)
		get_tree().quit(1)
		return
	Transport.start()
	var report: Array = [null]
	channel.reported.connect(func(d): report[0] = d)
	await wait_until(func(): return report[0] != null, 30.0)
	var r: Dictionary = report[0] if report[0] != null else {}
	check(not r.is_empty(), "client reported")
	if r.is_empty():
		OS.kill(pid)
		get_tree().quit(1)
		return
	var client_id: int = Session.players.keys().filter(func(k): return k != 1)[0]
	var p: Dictionary = Session.players[client_id]
	var rrig: InstrumentRig = p.rig

	var true_offset: float = r.epoch - clock_epoch() + SKEW
	var err: float = absf(r.offset - true_offset)
	print("  clock: client offset %.4f s, true %.4f s, error %.3f ms (bound ±%.2f ms)" % [r.offset, true_offset, err * 1000.0, r.bound * 1000.0])
	print("  clock: estimate error %.3f ms; wall-clock reference jitter %.3f ms" % [absf(r.estimate - true_offset) * 1000.0, absf(r.epoch2 - r.epoch) * 1000.0])
	# The wall-clock reference itself can wobble by a fraction of a ms; allow for it.
	check(err < 0.001 + absf(r.epoch2 - r.epoch), "clock offset within 1 ms")
	check(absf(r.anchor_time - Transport.anchor_time) < 1e-6 and r.running, "client follows the host's tempo map")
	check(p.instrument == "Comet" and rrig.instrument == "Comet", "client's instrument mirrored")
	check(p.direct_out and p.direct_in, "direct UDP both ways")
	check(Session.total_notes_received() == NOTES, "live notes received (%d/%d)" % [Session.total_notes_received(), NOTES])
	if Session.audio:
		var ns: Dictionary = Session.audio.get_peer_stats(client_id)
		print("  notes (native thread): last arrived %.2f ms after it was played; steady delay %.2f ms; ping %.2f ms" % [ns.last_late_ms, ns.note_delay_ms, ns.note_rtt_ms])
		check(ns.note_delay_ms < 6.0, "native note delay under 6 ms on loopback")
	var lat: Array = p.lateness
	if not lat.is_empty():
		var mx: float = lat.max()
		var sum := 0.0
		for x in lat:
			sum += x
		print("  notes (script path): arrival lateness mean %.1f ms, max %.1f ms" % [sum / lat.size() * 1000.0, mx * 1000.0])
	check(absf(rrig.synth.get_param(r.param_id) - r.param_value) < 1e-4, "parameter change mirrored")
	check(rrig.sequencer.has_note(0, 72), "sequencer edit mirrored")
	var mine := MasterLooper.layers.filter(func(l): return l.owner == str(client_id))
	check(mine.size() == 1 and mine[0].owner_name == "Client", "client's master-looper layer added by the host")
	check(Transport._pending_bpm == 100.0 or Transport.bpm == 100.0, "client's tempo request applied by the host")
	check(r.master_layers == 1, "master layer reached the client too")

	# Audio: the client streams a 440 Hz tone over AOO for a second.
	channel.rpc_id(client_id, "report", {"cmd": "tone"})
	var peak := 0.0
	var st := {}
	var t_end := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		st = Session.audio.get_peer_stats(client_id) if Session.audio else {}
		peak = maxf(peak, float(st.get("peak", 0.0)))
	print("  audio: %s, peak %.2f" % [st, peak])
	check(st.get("streaming", false), "client's audio stream arrives (AOO)")
	check(peak > 0.2, "tone audible in the client's player stream")

	# Audio loop: the client records one bar of its input into looper slot 2;
	# the clip reaches us once and plays from the clock here.
	var aloop: Array = [null]
	channel.reported.connect(func(d):
		if d.has("aloop"):
			aloop[0] = d)
	channel.rpc_id(client_id, "report", {"cmd": "aloop"})
	await wait_until(func(): return aloop[0] != null, 20.0)
	await wait(0.8)
	var ar: Dictionary = aloop[0] if aloop[0] != null else {}
	check(ar.get("aloop", false), "client recorded an audio loop (%s)" % [ar])
	var rs: Dictionary = rrig.looper.slots[1]
	check(rs.kind == "audio" and rs.layers.size() == 1, "audio loop slot mirrored")
	var got: Dictionary = rrig.looper.clips.get(int(ar.get("clip", -1)), {})
	check(not got.is_empty() and got.samples.size() == int(ar.get("samples", -1)), "clip audio arrived intact")

	channel.rpc("finish")
	await wait(0.5)
	Session.leave()
	print("PASS" if failures.is_empty() else "FAILED: %s" % [failures])
	get_tree().quit(0 if failures.is_empty() else 1)


# ---- Client

func _client() -> void:
	MasterLooper.audio_out = false
	var rig := make_rig("Comet")
	Session.player_name = "Client"
	channel.reported.connect(func(d):
		if d.get("cmd") == "tone":
			_tone(2.0)
		elif d.get("cmd") == "aloop":
			_aloop())
	channel.finished.connect(func():
		Session.leave()
		get_tree().quit(0))
	Session.join("127.0.0.1", PORT)
	var ok := await wait_until(func(): return Session.clock.samples.size() >= 12 and Transport.running \
			and Session.players.size() == 2 and Session.players[1].direct_out, 20.0)
	if not ok:
		print("client: never synced")
		get_tree().quit(1)
		return
	for i in NOTES:
		rig.play_note(60 + (i % 12), 0.8)
		await wait(0.03 + 0.01 * (i % 3))
		rig.release_note(60 + (i % 12))
		await wait(0.02)
	var info: Dictionary = rig.synth.get_param_list()[1]
	var v: float = lerpf(float(info.min), float(info.max), 0.37)
	rig.set_param(info.id, v)
	rig.sequencer.set_note(0, 72, true)
	MasterLooper.push({"bars": 1, "instrument": "Comet", "params": {},
		"events": [{"b": 0.0, "on": true, "note": 60, "v": 1.0}, {"b": 1.0, "on": false, "note": 60}]})
	Transport.set_tempo(100.0)
	await wait(0.8) # snapshots go out every 0.25 s
	channel.rpc_id(1, "report", {"epoch": clock_epoch(), "offset": Transport.clock_offset, "estimate": Session.clock.offset, "epoch2": clock_epoch(),
		"bound": Session.clock.error_bound(), "anchor_time": Transport.anchor_time, "running": Transport.running,
		"param_id": info.id, "param_value": rig.synth.get_param(info.id), "master_layers": MasterLooper.layers.size()})
	await wait(15.0)
	get_tree().quit(1)


func _aloop() -> void:
	var lp: Looper = Session.local_rig.looper
	_tone(12.0)
	await wait(0.3)
	lp.length_bars = 1
	lp.audio_input = true
	lp.current = 1
	lp.press_record()
	await wait_until(func(): return not lp.slots[1].layers.is_empty() or lp.last_error != "", 15.0)
	var id: int = int(lp.slots[1].layers[0].clip) if not lp.slots[1].layers.is_empty() else -1
	var c: Dictionary = lp.clips.get(id, {})
	var rms := 0.0
	if not c.is_empty():
		for i in range(0, c.samples.size(), 37):
			rms += c.samples[i] * c.samples[i]
		rms = sqrt(rms / (c.samples.size() / 37.0))
	print("client: audio loop clip %d, %d samples, rms %.2f, error '%s'" % [id, c.get("samples", []).size(), rms, lp.last_error])
	channel.rpc_id(1, "report", {"aloop": id > 0 and rms > 0.2, "clip": id, "samples": c.get("samples", []).size()})


func _tone(seconds: float) -> void:
	var a: Object = Session.audio
	a.set_sending(true)
	var phase := 0.0
	var sent := 0
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < int(seconds * 1_000_000):
		# Push what real time says is due, like a capture callback would.
		var due := int((Time.get_ticks_usec() - t0) * 48000 / 1_000_000) - sent
		if due > 0:
			var buf := PackedVector2Array()
			buf.resize(due)
			for i in due:
				var v := 0.5 * sin(phase)
				phase += TAU * 440.0 / 48000.0
				buf[i] = Vector2(v, v)
			a.push_input(buf, 48000)
			sent += due
		await get_tree().process_frame
