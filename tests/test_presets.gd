extends GutTest
## Factory presets load, use only real parameters, and sound reasonable.

const SR := 48000
const ALL := ["Pulsar", "Undertow", "Comet", "Lumen", "Driftwood", "Tangle"]


func test_eight_factory_presets_each() -> void:
	for t in ALL:
		var factory := PresetLibrary.list(t).filter(func(p): return p.factory)
		assert_eq(factory.size(), 8, "%s factory presets" % t)


func test_presets_use_known_params() -> void:
	for t in ALL:
		var s := JamSynth.new()
		s.instrument = t
		var ids := {}
		for p in s.get_param_list():
			ids[p.id] = true
		for preset in PresetLibrary.list(t):
			for k in preset.params.keys():
				if k == "patch":
					continue
				assert_true(ids.has(k), "%s / %s: unknown param '%s'" % [t, preset.name, k])


func test_tangle_presets_build_fully() -> void:
	var types := {}
	var s := JamSynth.new()
	s.instrument = "Tangle"
	for m in s.tangle_get_module_types():
		var params := {}
		for p in m.params:
			params[p.id] = true
		var ins := {}
		for p in m.inputs:
			ins[p.id] = true
		var outs := {}
		for p in m.outputs:
			outs[p.id] = true
		types[m.type] = {"params": params, "in": ins, "out": outs}
	for preset in PresetLibrary.list("Tangle"):
		var patch: Dictionary = preset.params.patch
		var by_id := {}
		for m in patch.modules:
			assert_true(types.has(m.type), "%s: module type %s" % [preset.name, m.type])
			by_id[m.id] = m.type
			for k in m.params.keys():
				assert_true(types[m.type].params.has(k), "%s: %s has no param %s" % [preset.name, m.type, k])
		for c in patch.cables:
			assert_true(types[by_id[c.from]].out.has(c.out), "%s: %s has no output %s" % [preset.name, by_id[c.from], c.out])
			assert_true(types[by_id[c.to]].in.has(c["in"]), "%s: %s has no input %s" % [preset.name, by_id[c.to], c["in"]])
		PresetLibrary.apply(s, preset)
		var built := s.tangle_get_patch()
		assert_eq(built.modules.size(), patch.modules.size(), preset.name)
		assert_eq(built.cables.size(), patch.cables.size(), preset.name)


func test_every_preset_renders_sensibly() -> void:
	for t in ALL:
		for preset in PresetLibrary.list(t):
			var s := JamSynth.new()
			s.instrument = t
			PresetLibrary.apply(s, preset)
			var notes := [36, 38, 42] if t == "Pulsar" else [48, 55, 60]
			var b := PackedVector2Array()
			for n in notes:
				s.note_on(n, 0.9)
				b.append_array(s.render_offline(SR / 2))
				s.note_off(n)
			b.append_array(s.render_offline(SR))
			var st := AudioUtil.stats(b)
			assert_eq(st.bad, 0, "%s / %s NaN" % [t, preset.name])
			assert_gt(st.peak, 0.02, "%s / %s too quiet (%.3f)" % [t, preset.name, st.peak])
			assert_lt(st.peak, 1.2, "%s / %s too loud (%.3f)" % [t, preset.name, st.peak])


func test_capture_and_share_code_roundtrip() -> void:
	for t in ALL:
		var s := JamSynth.new()
		s.instrument = t
		var presets := PresetLibrary.list(t)
		PresetLibrary.apply(s, presets[3])
		var captured := PresetLibrary.capture(s, "Round Trip")
		var code := PresetLibrary.to_code(captured)
		assert_true(code.begins_with("JAM1:"))
		var back := PresetLibrary.from_code(code)
		assert_eq(back.instrument, t)
		var s2 := JamSynth.new()
		s2.instrument = t
		PresetLibrary.apply(s2, back)
		assert_eq(s2.get_params().hash() if t != "Tangle" else s2.tangle_get_patch().cables.size(),
			s.get_params().hash() if t != "Tangle" else s.tangle_get_patch().cables.size(), "%s round trip" % t)
		if t == "Tangle":
			assert_lt(code.length(), 2900, "Tangle share code must fit one QR code (%d chars)" % code.length())


func test_bad_codes_are_rejected() -> void:
	assert_eq(PresetLibrary.from_code("hello"), {})
	assert_eq(PresetLibrary.from_code("JAM1:@@@@"), {})
	assert_eq(PresetLibrary.from_code("JAM1:"), {})
