extends SceneTree
## Headless render of each instrument: plays a phrase, prints stats and CPU cost, writes WAVs.
## godot --headless --path . --script res://tests/tools/render_check.gd [-- Instrument]

const SR := 48000

func phrase_for(type: String) -> Array:
	match type:
		"Pulsar": return [[36], [42], [38, 42], [42], [36], [36, 46], [39, 42], [45], [50], [49, 36]]
		"Undertow": return [[36], [36], [43], [48], [39], [41]]
		"Lumen": return [[60, 64, 67, 71], [57, 60, 64, 67], [53, 57, 60, 64], [55, 59, 62, 65]]
		_: return [[60], [62], [64], [67], [72], [67]]


func _init() -> void:
	var only := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		only = args[0]
	for type in JamSynth.get_instrument_types():
		if only != "" and type != only:
			continue
		var s := JamSynth.new()
		s.instrument = type
		var out := PackedVector2Array()
		var step := SR / 4 if type == "Pulsar" else SR / 2
		for chord in phrase_for(type):
			for n in chord:
				s.note_on(n, 0.9)
			out.append_array(s.render_offline(step * 3 / 4, SR))
			for n in chord:
				s.note_off(n)
			out.append_array(s.render_offline(step / 4, SR))
		out.append_array(s.render_offline(SR * 2, SR))
		var st := AudioUtil.stats(out)
		# CPU: hold 8 notes (or a drum roll) for 4 s of audio.
		for n in [48, 52, 55, 59, 62, 64, 67, 71]:
			s.note_on(n, 0.8)
		var t0 := Time.get_ticks_usec()
		var frames := 0
		for i in 16:
			if type == "Pulsar":
				for n in [36, 38, 42, 46]:
					s.note_on(n, 0.8)
			s.render_offline(SR / 4, SR)
			frames += SR / 4
		var secs := float(Time.get_ticks_usec() - t0) / 1e6
		print("%-9s peak=%.3f rms=%.3f bad=%d params=%d  cpu=%.2f%% of one core (8 voices, incl. GDScript copy overhead)" % [type, st.peak, st.rms, st.bad, s.get_param_list().size(), 100.0 * secs / (float(frames) / SR)])
		AudioUtil.write_wav("res://test_output/%s.wav" % type, out, SR)
	quit()
