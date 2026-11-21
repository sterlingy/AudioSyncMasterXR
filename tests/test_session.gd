extends GutTest
## Session building blocks: clock estimate, note packets, jitter delay,
## following the host's tempo map, looper and master-looper replication.
## The two-process test is tests/tools/net_test.gd.

const SR := 48000


func after_each() -> void:
	Transport.follower = false
	Transport.running = false
	MasterLooper.clear_all()


func test_clock_sync_trusts_the_fastest_exchange() -> void:
	var c := ClockSync.new()
	var true_offset := 5.25
	# Exchanges with uneven waits; one of them (rtt 2 ms) is nearly symmetric.
	var legs := [[0.012, 0.001], [0.001, 0.016], [0.001, 0.001], [0.008, 0.004], [0.0, 0.011]]
	var t := 10.0
	for l in legs:
		var t1: float = t + l[0] + true_offset
		c.add(t, t1, t + l[0] + l[1])
		t += 0.1
	assert_true(c.ready())
	assert_almost_eq(c.offset, true_offset, 0.0005)
	assert_almost_eq(c.rtt, 0.002, 1e-6)
	assert_lt(c.error_bound(), 0.0015)


func test_note_packet_round_trip() -> void:
	var b := Session.pack(7, Session.Ev.ON, 61, 0.75, 1234.5678, 16.5)
	assert_eq(b.size(), Session.PKT_SIZE)
	var e := Session.unpack(b)
	assert_eq(e.from, 7)
	assert_eq(e.type, Session.Ev.ON)
	assert_eq(e.a, 61)
	assert_almost_eq(e.value, 0.75, 1e-6)
	assert_eq(e.t, 1234.5678)
	assert_eq(e.at, 16.5)
	assert_true(is_nan(Session.unpack(Session.pack(1, Session.Ev.OFF, 1, 0.0, 1.0)).at))
	if ClassDB.class_exists("JamAudioLink"):
		assert_eq(ClassDB.class_call_static("JamAudioLink", "pack_event", 7, Session.Ev.ON, 61, 0.75, 1234.5678, 16.5), b,
			"native and script packets are identical")
	b[0] = 0
	assert_true(Session.unpack(b).is_empty(), "foreign packets are ignored")


func test_jitter_delay_covers_late_notes() -> void:
	var late := []
	for i in 100:
		late.append(0.004 + (0.012 if i % 10 == 0 else 0.0)) # every tenth note waits a frame
	var d := Session.delay_from(late)
	assert_almost_eq(d, 0.018, 0.0005)
	assert_eq(Session.delay_from([]), 0.0)
	assert_eq(Session.delay_from([1.0]), Session.MAX_NOTE_DELAY, "capped")


func test_follower_joins_running_transport_without_replaying_past() -> void:
	var host_state := {"running": true, "anchor_time": Transport.now() - 2.0, "anchor_beat": 0.0, "bpm": 120.0,
		"beats_per_bar": 3, "pending_bpm": 0.0, "pending_beat": 0.0}
	Transport.follower = true
	Transport.apply_state(host_state)
	assert_true(Transport.running)
	assert_eq(Transport.beats_per_bar, 3)
	assert_almost_eq(Transport.current_beat(), 4.0, 0.05)
	assert_gt(Transport._scheduled_until, 3.9, "beats already past aren't scheduled")
	# A follower's own start/stop become requests to the host.
	watch_signals(Transport)
	Transport.stop()
	assert_true(Transport.running)
	assert_signal_emitted_with_parameters(Transport, "request", ["stop", null])
	host_state.running = false
	Transport.apply_state(host_state)
	assert_false(Transport.running)
	Transport.beats_per_bar = 4


func test_looper_mirror_plays_finished_layers() -> void:
	var a := InstrumentRig.new()
	var b := InstrumentRig.new()
	var lp := Looper.new(a)
	var s := lp.slot()
	s.bars = 1
	s.state = Looper.State.PLAYING
	s.layers = [[{"b": 0.0, "on": true, "note": 36, "v": 1.0}, {"b": 0.1, "on": false, "note": 36}]]
	lp.slots[1].state = Looper.State.RECORDING # in progress: not shared
	var mirror := Looper.new(b)
	mirror.apply_net(lp.to_net())
	assert_eq(mirror.slots[0].state, Looper.State.PLAYING)
	assert_eq(mirror.slots[0].layers.size(), 1)
	assert_eq(mirror.slots[1].state, Looper.State.EMPTY)
	a.free()
	b.free()


func test_master_layers_survive_export_and_import() -> void:
	var data := {"bars": 1, "instrument": "Pulsar", "params": {},
		"events": [{"b": 0.0, "on": true, "note": 36, "v": 1.0}]}
	MasterLooper.audio_out = false
	var id := MasterLooper.add_layer(data, "3", 9, "Sam")
	assert_eq(id, 9)
	var exported := MasterLooper.export_layers()
	MasterLooper.import_layers(exported)
	assert_eq(MasterLooper.layers.size(), 1)
	assert_eq(MasterLooper.layers[0].owner_name, "Sam")
	assert_eq(MasterLooper.add_layer(data), 10, "new ids continue after imported ones")
	assert_eq(MasterLooper.add_layer({"bars": 1, "instrument": "Nope", "events": data.events}), -1)
	MasterLooper.audio_out = true


func test_tangle_knob_moves_do_not_rebuild_the_patch() -> void:
	var src := JamSynth.new()
	src.instrument = "Tangle"
	src.tangle_load_default()
	var rig := InstrumentRig.new()
	add_child_autofree(rig)
	rig.set_instrument("Tangle")
	var memo := {}
	Session.apply_sound(rig, src.get_params(), memo)
	var sig: int = memo.patch_sig
	var m: Dictionary = src.tangle_get_patch().modules.filter(func(x): return x.type == "vco")[0]
	var pid := "pw"
	var v := 0.3
	src.tangle_set_param(int(m.id), pid, v)
	Session.apply_sound(rig, src.get_params(), memo)
	assert_eq(memo.patch_sig, sig, "same modules and cables")
	assert_almost_eq(rig.synth.tangle_get_param(int(m.id), pid), v, 1e-5)
	assert_eq(rig.synth.tangle_get_patch().cables.size(), src.tangle_get_patch().cables.size())


func _onset(buf: PackedVector2Array, threshold := 0.05) -> int:
	for i in buf.size():
		if absf(buf[i].x) > threshold:
			return i
	return -1


func test_native_notes_land_on_their_frame() -> void:
	if not ClassDB.class_exists("JamAudioLink"):
		pass_test("jamcore built without AOO")
		return
	var a: Object = ClassDB.instantiate("JamAudioLink")
	var b: Object = ClassDB.instantiate("JamAudioLink")
	assert_eq(a.start(0, 101), OK)
	assert_eq(b.start(0, 202), OK)
	a.add_peer(202, "127.0.0.1", b.get_port())
	b.add_peer(101, "127.0.0.1", a.get_port())
	a.set_clock(0.0, 0.0)
	b.set_clock(0.0, 0.0)
	var synth := JamSynth.new()
	synth.instrument = "Pulsar"
	var t0 := JamSynth.get_time()
	synth.set_clock_anchor(t0, 0)
	a.route_notes(202, synth)
	# A live-quantized note meant to sound 100 ms from now: lands on that frame.
	b.send_event(Session.Ev.ON, 36, 1.0, t0 + 0.1)
	b.send_event(Session.Ev.OFF, 36, 0.0, NAN)
	await wait_seconds(0.05)
	var st: Dictionary = a.get_peer_stats(202)
	assert_eq(int(st.notes), 1)
	var on := _onset(synth.render_offline(SR / 4))
	assert_almost_eq(float(on), 0.1 * SR, 2.0, "onset at the requested time (frame %d)" % on)
	a.stop()
	b.stop()
