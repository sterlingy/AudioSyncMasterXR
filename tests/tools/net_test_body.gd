extends Node
## Body of tests/tools/net_test.gd (loaded at runtime so the autoloads exist).
## Two machines: run the host with `-- --remote` and the client elsewhere with
## `-- --join=<host IP>`; checks that need a shared wall clock become reports.

const PORT := 47931
const SKEW := 3.217
const NOTES := 24

var channel: Node
var is_client := false
var remote := false # two machines: --remote on the host, --join=IP on the client
var join_ip := "127.0.0.1"
var server_arg := "" # --server=ip:port: go through the connection server (room code)
var room_arg := "" # client: --room=CODE
var sweep := false # host: measure dropouts per buffer size and codec instead of the checks
var failures := []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	is_client = "--client" in args
	for a in args:
		if a == "--remote":
			remote = true
		elif a == "--sweep":
			sweep = true
		elif a.begins_with("--server="):
			server_arg = a.trim_prefix("--server=")
		elif a.begins_with("--room="):
			room_arg = a.trim_prefix("--room=")
			is_client = true
		elif a.begins_with("--join="):
			join_ip = a.trim_prefix("--join=")
			is_client = true
			remote = true
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
	if server_arg != "":
		Session.server = server_arg
	if (Session.host_online(PORT) if server_arg != "" else Session.host(PORT)) != OK:
		print("can't host: ", Session.status)
		get_tree().quit(2)
		return
	Transport.clock_offset = SKEW
	var pid := -1
	if server_arg != "":
		var got := await wait_until(func(): return Session.room_code != "", 10.0)
		check(got, "room code from the connection server")
		print("room code: ", Session.room_code)
		if not got:
			get_tree().quit(1)
			return
	if remote:
		print("host: waiting for a client on port %d (run with --join=<this IP>)" % PORT)
	else:
		var exe := OS.get_executable_path()
		var cargs := ["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tests/tools/net_test.gd", "--", "--client"]
		if server_arg != "":
			cargs.append_array(["--server=" + server_arg, "--room=" + Session.room_code])
		pid = OS.create_process(exe, cargs)
		print("host: started client process ", pid)
	var joined := await wait_until(func(): return Session.players.size() == 2, 120.0 if remote else 20.0)
	check(joined, "client joined")
	if not joined:
		if pid > 0:
			OS.kill(pid)
		get_tree().quit(1)
		return
	Transport.start()
	var suggested: Array = [0.0]
	Session.tempo_suggested.connect(func(_id, _who, b):
		suggested[0] = b
		Session.answer_suggestion(true))
	var report: Array = [null]
	channel.reported.connect(func(d): report[0] = d)
	await wait_until(func(): return report[0] != null, 30.0)
	var r: Dictionary = report[0] if report[0] != null else {}
	check(not r.is_empty(), "client reported")
	if r.is_empty():
		if pid > 0:
			OS.kill(pid)
		get_tree().quit(1)
		return
	var client_id: int = Session.players.keys().filter(func(k): return k != 1)[0]
	var p: Dictionary = Session.players[client_id]
	var rrig: InstrumentRig = p.rig
	if sweep:
		await _sweep(client_id)
		channel.rpc("finish")
		await wait(0.5)
		Session.leave()
		get_tree().quit(0)
		return

	var true_offset: float = r.epoch - clock_epoch() + SKEW
	var err: float = absf(r.offset - true_offset)
	if remote:
		# Separate machines have separate wall clocks, so there's no ground truth:
		# report the sync's own bound and how far Windows' clocks disagree.
		print("  clock: client offset %.4f s, bound ±%.2f ms (best ping %.2f ms, %d samples)" % [r.offset, r.bound * 1000.0, r.rtt * 1000.0, r.samples])
		print("  clock: Windows wall clocks differ by %.1f ms (information only)" % [err * 1000.0])
		check(r.bound < 0.010, "clock sync bound under 10 ms")
	else:
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
		if remote:
			check(ns.note_delay_ms < ns.note_rtt_ms * 0.5 + 15.0, "native note delay within one-way trip + 15 ms")
		else:
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
	check(suggested[0] == 100.0, "client's tempo suggestion reached the host")
	check(Transport._pending_bpm == 100.0 or Transport.bpm == 100.0, "accepted tempo suggestion applied by the host")
	check(r.master_layers == 1, "master layer reached the client too")

	# Audio: the client streams a 440 Hz tone over AOO for a second.
	var tone_s := 20.0 if remote else 2.0
	channel.rpc_id(client_id, "report", {"cmd": "tone", "seconds": tone_s})
	var peak := 0.0
	var st := {}
	var under0 := -1
	var lats := []
	var t_end := Time.get_ticks_msec() + int((tone_s + 1.0) * 1000.0)
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		st = Session.audio.get_peer_stats(client_id) if Session.audio else {}
		peak = maxf(peak, float(st.get("peak", 0.0)))
		if st.get("streaming", false):
			if under0 < 0:
				under0 = int(st.get("underruns", 0))
			lats.append(float(st.get("latency_ms", 0.0)))
	print("  audio: %s, peak %.2f" % [st, peak])
	if not lats.is_empty():
		lats.sort()
		print("  audio: latency median %.1f ms, max %.1f ms; underruns during the tone %d" % [
			lats[lats.size() / 2], lats[-1], int(st.get("underruns", 0)) - maxi(under0, 0)])
	check(st.get("streaming", false), "client's audio stream arrives (AOO)")
	check(peak > 0.2, "tone audible in the client's player stream")
	var ad: float = st.get("audio_delay_ms", -1.0)
	print("  audio: estimated delay mic->mix %.1f ms, mic->ear %.1f ms" % [ad, st.get("mouth_to_ear_ms", -1.0)])
	check(ad > 0.0 and ad < 250.0, "audio delay estimated")

	# Interval mode: the host turns it on for everyone; the client's voice is
	# held back so it lands one bar after it was played.
	Session.set_interval_bars(1)
	var istate: Array = [null]
	channel.reported.connect(func(d):
		if d.has("interval"):
			istate[0] = d)
	channel.rpc_id(client_id, "report", {"cmd": "state"})
	channel.rpc_id(client_id, "report", {"cmd": "tone", "seconds": 2.0})
	await wait_until(func(): return istate[0] != null, 10.0)
	await wait(1.5)
	var ist: Dictionary = Session.audio.get_peer_stats(client_id)
	var want := Session.interval_seconds() * 1000.0 - float(ist.get("audio_delay_ms", 0.0)) - AudioServer.get_output_latency() * 1000.0
	print("  interval: %.0f ms; voice held back %.1f ms (expected %.1f ms)" % [Session.interval_seconds() * 1000.0, ist.get("interval_hold_ms", 0.0), want])
	check(istate[0] != null and int(istate[0].interval) == 1, "client switched to interval mode")
	check(absf(float(ist.get("interval_hold_ms", 0.0)) - want) < 8.0, "voice held back to land one interval later")
	Session.set_interval_bars(0)
	await wait(0.5)

	# Avatars: the client's head moves 1 m per second of shared time, so where
	# we see it says how late we show it; it should match avatar_delay().
	channel.rpc_id(client_id, "report", {"cmd": "pose"})
	await wait_until(func(): return p.has("poses") and p.poses.size() > 20, 5.0)
	await wait(0.3)
	var pose := Session.remote_pose(client_id)
	var shown_late := -1.0
	if not pose.is_empty():
		shown_late = fposmod(Transport.now(), 500.0) - pose.head.origin.x
	print("  avatar: %d poses; shown %.1f ms late, avatar delay %.1f ms" % [p.get("poses", PoseBuffer.new()).size(), shown_late * 1000.0, Session.avatar_delay(p) * 1000.0])
	check(not pose.is_empty() and absf(shown_late - Session.avatar_delay(p)) < 0.012, "remote avatar shown when its sound arrives")

	# Audio mode: the client sends its instrument as audio; we mute our copy
	# of its instrument and hear it through its stream instead.
	channel.rpc_id(client_id, "report", {"cmd": "inst_audio"})
	await wait_until(func(): return p.get("audio_mode", false), 5.0)
	check(p.get("audio_mode", false) and rrig.player.volume_db <= -79.0, "client in audio mode: our copy of its instrument muted")
	var ipk := 0.0
	var t_i := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < t_i:
		await get_tree().process_frame
		ipk = maxf(ipk, float(Session.audio.get_peer_stats(client_id).get("peak", 0.0)))
	print("  audio mode: instrument peak in the client's stream %.3f" % ipk)
	check(ipk > 0.02, "client's instrument heard through its audio stream")
	await wait_until(func(): return not p.get("audio_mode", false), 5.0)

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


## Streams a tone from the client for each receive buffer and codec, and
## prints dropouts (AOO underruns) and the estimated audio delay.
func _sweep(client_id: int) -> void:
	var seconds := 8.0
	print("  sweep: %.0f s of tone per setting; buffer = our receive buffer" % seconds)
	for codec in ["pcm16", "opus"]:
		channel.rpc_id(client_id, "report", {"cmd": "codec", "codec": codec})
		await wait(1.0)
		for buf in [5.0, 8.0, 10.0, 15.0, 20.0]:
			Session.audio.set_latency_ms(buf)
			channel.rpc_id(client_id, "report", {"cmd": "tone", "seconds": seconds + 1.0})
			await wait(1.0) # stream (re)starts and settles
			var u0 := int(Session.audio.get_peer_stats(client_id).get("underruns", 0))
			await wait(seconds)
			var st: Dictionary = Session.audio.get_peer_stats(client_id)
			print("  sweep: %-5s buffer %4.0f ms: %2d dropouts in %.0f s, audio delay %.1f ms, ping %.1f ms" % [
				codec, buf, int(st.get("underruns", 0)) - u0, seconds, st.get("audio_delay_ms", -1.0), st.get("rtt_ms", -1.0)])
			await wait(1.0)
	channel.rpc_id(client_id, "report", {"cmd": "codec", "codec": "pcm16"})
	Session.audio.set_latency_ms(Session.audio_buffer_ms)


# ---- Client

func _client() -> void:
	MasterLooper.audio_out = false
	var rig := make_rig("Comet")
	Session.player_name = "Client"
	channel.reported.connect(func(d):
		if d.get("cmd") == "tone":
			_tone(float(d.get("seconds", 2.0)))
		elif d.get("cmd") == "aloop":
			_aloop()
		elif d.get("cmd") == "pose":
			_poses(3.0)
		elif d.get("cmd") == "codec":
			Session.set_audio_codec(str(d.codec))
		elif d.get("cmd") == "inst_audio":
			_inst_audio()
		elif d.get("cmd") == "state":
			channel.rpc_id(1, "report", {"interval": Session.interval_bars}))
	channel.finished.connect(func():
		Session.leave()
		get_tree().quit(0))
	if room_arg != "":
		Session.server = server_arg
		Session.join_online(room_arg)
	else:
		Session.join(join_ip, PORT)
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
		"bound": Session.clock.error_bound(), "rtt": Session.clock.rtt, "samples": Session.clock.samples.size(), "anchor_time": Transport.anchor_time, "running": Transport.running,
		"param_id": info.id, "param_value": rig.synth.get_param(info.id), "master_layers": MasterLooper.layers.size()})
	await wait(300.0 if remote else 15.0) # the host sends "finish" when done
	get_tree().quit(1)


func _poses(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		var x := fposmod(Transport.now(), 500.0)
		Session.set_local_pose(Transform3D(Basis.IDENTITY, Vector3(x, 1.6, 0.0)),
			Transform3D(Basis.IDENTITY, Vector3(x - 0.3, 1.0, -0.3)), Transform3D(Basis.IDENTITY, Vector3(x + 0.3, 1.0, -0.3)))
		await get_tree().process_frame
	Session.clear_local_pose()


func _inst_audio() -> void:
	Session.set_instrument_audio(true)
	var rig: InstrumentRig = Session.local_rig
	await wait(0.3)
	for n in [60, 64, 67]:
		rig.play_note(n, 0.9)
	await wait(2.0)
	for n in [60, 64, 67]:
		rig.release_note(n)
	Session.set_instrument_audio(false) # also restores the saved setting


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
