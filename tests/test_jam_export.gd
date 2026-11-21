extends GutTest
## Jam recording: stems and mixdown on disk, MIDI of what played, session
## file that loads back. Runs in real time (taps work on live playback).

var rig: InstrumentRig
var saved_rig: InstrumentRig


func before_each() -> void:
	Transport.stop()
	saved_rig = Session.local_rig
	rig = InstrumentRig.new()
	rig.instrument = "Pulsar"
	add_child_autofree(rig)
	Session.local_rig = rig


func after_each() -> void:
	Session.local_rig = saved_rig
	MasterLooper.clear_all()


func _read_wav(path: String) -> PackedFloat32Array:
	var f := FileAccess.open(path, FileAccess.READ)
	f.seek(44)
	return f.get_buffer(f.get_length() - 44).to_float32_array()


func test_record_a_jam() -> void:
	if not JamRecorder.supported():
		pass_test("jamcore without the stem recorder")
		return
	var rec := JamRecorder.new()
	add_child_autofree(rec)
	assert_eq(rec.start(), OK)
	await wait_frames(5)
	for i in 4:
		rig.play_note(36, 1.0)
		await wait_seconds(0.25)
		rig.release_note(36)
	await wait_seconds(0.4)
	var dir := rec.stop()
	assert_true(FileAccess.file_exists(dir + "mixdown.wav"))
	assert_true(FileAccess.file_exists(dir + "stem_" + Session.player_name + ".wav"))
	assert_true(FileAccess.file_exists(dir + "jam.mid"))
	# MIDI: header, and four note-ons in the player's track.
	var midi := FileAccess.get_file_as_bytes(dir + "jam.mid")
	assert_eq(midi.slice(0, 4).get_string_from_ascii(), "MThd")
	var ons := 0
	for i in midi.size() - 2:
		if midi[i] == 0x99 and midi[i + 1] == 36:
			ons += 1
	assert_eq(ons, 4, "note-ons in jam.mid")
	# The mixdown has the kicks, and the first one sits where MIDI says it does.
	var mix := _read_wav(dir + "mixdown.wav")
	var sr := AudioServer.get_mix_rate()
	var first := -1
	for i in range(0, mix.size(), 2):
		if absf(mix[i]) > 0.05:
			first = i / 2
			break
	assert_gt(first, 0, "audio in the mixdown")
	var ticks := _first_note_tick(midi)
	var midi_s := ticks / float(JamRecorder.PPQ) * 60.0 / Transport.bpm
	var wav_s := first / sr - AudioServer.get_output_latency()
	assert_almost_eq(wav_s, midi_s, 0.006, "stem and MIDI line up (wav %.4f s, midi %.4f s)" % [wav_s, midi_s])
	# Session file loads back into another instrument.
	rig.set_instrument("Lumen")
	assert_eq(JamRecorder.load_session(dir + "session.json"), "")
	assert_eq(rig.instrument, "Pulsar")


func _first_note_tick(midi: PackedByteArray) -> int:
	# Walks the second track (the player's) to its first note-on.
	var pos := 14
	var track := 0
	while pos < midi.size():
		var size := (midi[pos + 4] << 24) | (midi[pos + 5] << 16) | (midi[pos + 6] << 8) | midi[pos + 7]
		if track == 1:
			var p := pos + 8
			var tick := 0
			var status := 0
			while p < pos + 8 + size:
				var delta := 0
				while true:
					var b := midi[p]
					p += 1
					delta = (delta << 7) | (b & 0x7f)
					if b < 0x80:
						break
				tick += delta
				var s := midi[p]
				if s == 0xff:
					var len2 := midi[p + 2]
					p += 3 + len2
					continue
				status = s
				if (status & 0xf0) == 0x90:
					return tick
				p += 3
			return -1
		pos += 8 + size
		track += 1
	return -1
