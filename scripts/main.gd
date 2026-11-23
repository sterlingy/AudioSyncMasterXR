extends Control
## Flat (desktop) front end: pick an instrument and preset, tweak the panel,
## play from MIDI, the computer keyboard or the on-screen keys.
##
## Dev: `-- --shot=<path> [--instrument=Name] [--frames=N]` saves a screenshot and quits.

var rig: InstrumentRig
var panel: SynthPanel
var tangle: TangleEditor
var keys: KeyboardView
var seq_view: SequencerView
var loop_view: LooperView
var players_view: PlayersView
var recorder: JamRecorder
var _rec_jam: Button
var _ext_conns: Array = [] # [signal, callable] on autoloads, undone when we leave
var _tabs: TabBar
var _play: Button
var _pos: Label

var _inst_select: OptionButton
var _preset_select: OptionButton
var _status: Label
var _meter: ProgressBar
var _cpu: Label
var _tempo: SpinBox
var _suggest_bar: HBoxContainer
var _suggest_text: Label
var _add_module: MenuButton
var _presets: Array[Dictionary] = []
var _share_dialog: AcceptDialog
var _midi_dialog: MidiSettings
var _top_bar: Control
var _share_text: TextEdit
var _share_qr: TextureRect
var _save_dialog: ConfirmationDialog
var _save_name: LineEdit
var _shot_path := ""
var _shot_frames := 45
var _shot_after := 0.0 # seconds; used instead of frames when set


func _ready() -> void:
	_fit_to_screen()
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.075, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	rig = InstrumentRig.new()
	rig.name = "LocalInstrument"
	rig.instrument = String(Settings.get_value("instrument"))
	add_child(rig)
	Session.bind_rig(rig)
	recorder = JamRecorder.new()
	recorder.name = "JamRecorder"
	add_child(recorder)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	margin.add_child(root)

	root.add_child(_build_top_bar())
	root.add_child(_build_transport_bar())
	root.add_child(_build_suggest_bar())
	_tabs = TabBar.new()
	_tabs.add_tab("Sound")
	_tabs.add_tab("Sequencer")
	_tabs.add_tab("Looper")
	_tabs.add_tab("Jam")
	_tabs.tab_changed.connect(func(_i): _show_body())
	root.add_child(_tabs)
	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	panel = SynthPanel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.add_child(panel)
	panel.bind(rig)
	tangle = TangleEditor.new()
	tangle.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.add_child(tangle)
	seq_view = SequencerView.new()
	seq_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.add_child(seq_view)
	loop_view = LooperView.new()
	loop_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.add_child(loop_view)
	var jam_scroll := ScrollContainer.new() # the Jam tab scrolls on short screens
	jam_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	jam_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(jam_scroll)
	players_view = PlayersView.new()
	players_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jam_scroll.add_child(players_view)

	keys = KeyboardView.new()
	keys.custom_minimum_size.y = 130
	root.add_child(keys)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	root.add_child(_status)

	_build_dialogs()
	rig.instrument_changed.connect(func(_t): _on_instrument_changed())
	rig.preset_changed.connect(func(_p): _sync_preset_select())
	rig.learn_changed.connect(func(id): _update_status("Move a knob or slider on your MIDI controller to map it to %s" % id if id != "" else ""))
	_link(Midi.devices_changed, func(_d): _update_status())
	_on_instrument_changed()
	_update_status()
	_parse_dev_args()


func _build_top_bar() -> Control:
	var bar := HFlowContainer.new() # wraps onto a second line on narrow screens
	_top_bar = bar
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("v_separation", 6)
	var title := Label.new()
	title.text = "AudioSyncMaster"
	title.add_theme_font_size_override("font_size", 18)
	bar.add_child(title)
	bar.add_child(VSeparator.new())

	_inst_select = OptionButton.new()
	for t in JamSynth.get_instrument_types():
		if t != "Metronome" and t != "Clips":
			_inst_select.add_item(t)
	_inst_select.item_selected.connect(func(i):
		var t := _inst_select.get_item_text(i)
		Settings.set_value("instrument", t)
		rig.set_instrument(t))
	bar.add_child(_inst_select)

	var prev := Button.new()
	prev.text = "◀"
	prev.tooltip_text = "Previous preset"
	prev.pressed.connect(func(): _step_preset(-1))
	bar.add_child(prev)
	_preset_select = OptionButton.new()
	_preset_select.custom_minimum_size.x = 220
	_preset_select.item_selected.connect(func(i): rig.load_preset(_presets[i]))
	bar.add_child(_preset_select)
	var next := Button.new()
	next.text = "▶"
	next.tooltip_text = "Next preset"
	next.pressed.connect(func(): _step_preset(1))
	bar.add_child(next)

	var save := Button.new()
	save.text = "Save…"
	save.tooltip_text = "Save the current sound as your own preset"
	save.pressed.connect(func():
		_save_name.text = String(rig.current_preset.get("name", "My Sound")) + " (mine)"
		_save_dialog.popup_centered(Vector2i(420, 120)))
	bar.add_child(save)
	var share := Button.new()
	share.text = "Share…"
	share.tooltip_text = "Copy this sound as a code, or paste a code from someone else"
	share.pressed.connect(_open_share)
	bar.add_child(share)
	var midi := Button.new()
	midi.text = "MIDI…"
	midi.tooltip_text = "MIDI devices, Bluetooth MIDI, input channel, Wi-Fi MIDI relay"
	midi.pressed.connect(func(): _midi_dialog.popup_centered(Vector2i(620, 560)))
	bar.add_child(midi)

	_add_module = MenuButton.new()
	_add_module.text = "+ Module"
	_add_module.flat = false
	_add_module.get_popup().id_pressed.connect(func(id): tangle.add_module(_add_module.get_popup().get_item_metadata(id)))
	bar.add_child(_add_module)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var vl := Label.new()
	vl.text = "Volume"
	bar.add_child(vl)
	var vol := HSlider.new()
	vol.min_value = -40
	vol.max_value = 6
	vol.value = float(Settings.get_value("master_volume_db"))
	vol.custom_minimum_size.x = 120
	vol.value_changed.connect(func(v):
		rig.synth.volume_db = v
		Settings.set_value("master_volume_db", v))
	rig.synth.volume_db = vol.value
	bar.add_child(vol)
	_meter = ProgressBar.new()
	_meter.custom_minimum_size = Vector2(90, 14)
	_meter.max_value = 1.0
	_meter.show_percentage = false
	_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(_meter)
	_cpu = Label.new()
	_cpu.custom_minimum_size.x = 80
	_cpu.add_theme_font_size_override("font_size", 11)
	bar.add_child(_cpu)
	_group([vl, vol, _meter, _cpu])
	return bar


func _build_transport_bar() -> Control:
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("v_separation", 6)
	_play = Button.new()
	_play.text = "▶ Play"
	_play.custom_minimum_size.x = 90
	_play.tooltip_text = "Start/stop the shared clock (Space)"
	_play.pressed.connect(func(): Transport.toggle())
	_link(Transport.state_changed, func(r): _play.text = "■ Stop" if r else "▶ Play")
	bar.add_child(_play)
	_rec_jam = Button.new()
	_rec_jam.text = "● Rec jam"
	_rec_jam.tooltip_text = "Record the jam as heard here: a WAV stem per player, a mixdown, MIDI of every note, and a session file (saved under user://jams)"
	_rec_jam.disabled = not JamRecorder.supported()
	_rec_jam.pressed.connect(_toggle_jam_recording)
	bar.add_child(_rec_jam)
	_pos = Label.new()
	_pos.custom_minimum_size.x = 60
	_pos.text = "1.1"
	_pos.add_theme_font_size_override("font_size", 18)
	bar.add_child(_pos)
	bar.add_child(_lbl("Tempo"))
	_tempo = SpinBox.new()
	_tempo.min_value = 30
	_tempo.max_value = 300
	_tempo.step = 1
	_tempo.value = Transport.bpm
	_tempo.suffix = "BPM"
	_tempo.custom_minimum_size.x = 120
	_tempo.value_changed.connect(func(v): Transport.set_tempo(v))
	_link(Transport.tempo_changed, func(b): _tempo.set_value_no_signal(b))
	bar.add_child(_tempo)
	var tempo_label := bar.get_child(bar.get_child_count() - 2)
	var tap := Button.new()
	tap.text = "Tap"
	tap.tooltip_text = "Tap a few times on the beat to set the tempo (in a session, the host approves it)"
	tap.pressed.connect(func(): Transport.tap())
	bar.add_child(tap)
	_group([tempo_label, _tempo, tap])
	bar.add_child(_lbl("Beats/Bar"))
	var bpb := SpinBox.new()
	bpb.min_value = 1
	bpb.max_value = 16
	bpb.value = Transport.beats_per_bar
	bpb.value_changed.connect(func(v): Transport.set_beats_per_bar(int(v)))
	_link(Transport.meter_changed, func(n): bpb.set_value_no_signal(n))
	bar.add_child(bpb)
	_group([bar.get_child(bar.get_child_count() - 2), bpb])
	var met := CheckButton.new()
	met.text = "Metronome"
	met.button_pressed = Transport.metronome_on
	met.toggled.connect(func(t): Transport.metronome_on = t)
	bar.add_child(met)
	var cv := HSlider.new()
	cv.min_value = -40
	cv.max_value = 6
	cv.value = Transport.click_volume_db
	cv.custom_minimum_size.x = 70
	cv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cv.tooltip_text = "Click volume (just for you)"
	cv.value_changed.connect(func(v):
		Transport.click_volume_db = v
		Settings.set_value("click_volume_db", v))
	bar.add_child(cv)
	_group([met, cv])
	var ci := CheckButton.new()
	ci.text = "Count-in"
	ci.button_pressed = Transport.count_in_bars > 0
	ci.toggled.connect(func(t): Transport.count_in_bars = 1 if t else 0)
	bar.add_child(ci)
	bar.add_child(VSeparator.new())
	var q := CheckButton.new()
	q.text = "Quantize"
	q.tooltip_text = "Snap what gets recorded to the grid"
	q.button_pressed = Transport.quantize_enabled
	bar.add_child(q)
	var grid := OptionButton.new()
	for g in Transport.GRIDS:
		grid.add_item(g[0])
	grid.select(4)
	bar.add_child(grid)
	var live := CheckButton.new()
	live.text = "Live Quantize"
	live.tooltip_text = "Also snap what you play live (delays notes to the next grid point)"
	bar.add_child(live)
	_group([q, grid])
	var apply := func(_x = null):
		Transport.set_quantize(q.button_pressed, Transport.GRIDS[grid.selected][1], live.button_pressed)
	q.toggled.connect(apply)
	grid.item_selected.connect(apply)
	live.toggled.connect(apply)
	return bar


## For hosts of this scene (the XR panel): an extra button next to MIDI….
func add_top_button(text: String, tooltip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tooltip
	b.pressed.connect(cb)
	_top_bar.add_child(b)
	var midi_at := -1
	for c in _top_bar.get_children():
		if c is Button and c.text == "MIDI…":
			midi_at = c.get_index()
	if midi_at >= 0:
		_top_bar.move_child(b, midi_at + 1)
	return b


## Keeps a label and its controls together when a flow bar wraps.
func _group(nodes: Array) -> void:
	var parent: Node = nodes[0].get_parent()
	var g := HBoxContainer.new()
	g.add_theme_constant_override("separation", 6)
	parent.add_child(g)
	parent.move_child(g, nodes[0].get_index())
	for n in nodes:
		n.reparent(g, false)


## Host only: a player's tempo suggestion, with Accept / Ignore.
func _build_suggest_bar() -> Control:
	_suggest_bar = HBoxContainer.new()
	_suggest_bar.add_theme_constant_override("separation", 8)
	_suggest_bar.visible = false
	_suggest_text = Label.new()
	_suggest_text.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_suggest_bar.add_child(_suggest_text)
	for pair in [["Accept", true], ["Ignore", false]]:
		var b := Button.new()
		b.text = pair[0]
		b.pressed.connect(_answer_suggestion.bind(pair[1]))
		_suggest_bar.add_child(b)
	var always := CheckBox.new()
	always.text = "Always accept"
	always.button_pressed = not Session.approve_tempo
	always.toggled.connect(func(t):
		Session.approve_tempo = not t
		Settings.set_value("approve_tempo", not t)
		if t:
			_answer_suggestion(true))
	_suggest_bar.add_child(always)
	_link(Session.tempo_suggested, _on_tempo_suggested)
	return _suggest_bar


func _on_tempo_suggested(_id: int, who: String, bpm: float) -> void:
	_suggest_text.text = "%s suggests %d BPM" % [who, roundi(bpm)]
	_suggest_bar.visible = true


func _answer_suggestion(accept: bool) -> void:
	Session.answer_suggestion(accept)
	_suggest_bar.visible = false


## Phones and tablets: scale the whole UI by screen density so text and
## controls are finger-sized (desktop stays 1:1).
func _fit_to_screen() -> void:
	if not OS.has_feature("mobile") or get_viewport() != get_window():
		return # desktop, or inside the XR panel (its own viewport)
	var dpi := float(DisplayServer.screen_get_dpi())
	get_window().content_scale_factor = ui_scale_for_dpi(dpi)


static func ui_scale_for_dpi(dpi: float) -> float:
	# ~1.0 at 160 dpi (desktop-like), ~2 on a 420 dpi phone.
	return clampf(snappedf(dpi / 210.0, 0.25), 1.0, 3.0)


## Connects to an autoload's signal and remembers it, so freeing this scene
## (tests, scene changes) leaves no callbacks pointing at freed controls.
func _link(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_ext_conns.append([sig, cb])


func _exit_tree() -> void:
	for c in _ext_conns:
		if c[0].is_connected(c[1]):
			c[0].disconnect(c[1])
	_ext_conns.clear()
	if recorder and recorder.recording:
		recorder.stop()
	if Session.local_rig == rig:
		Session.local_rig = null


func _toggle_jam_recording() -> void:
	if recorder.recording:
		var d := recorder.stop()
		_rec_jam.text = "● Rec jam"
		_update_status("Jam saved to %s (stems, mixdown.wav, jam.mid, session.json)" % ProjectSettings.globalize_path(d))
	elif recorder.start() == OK:
		_rec_jam.text = "■ Stop rec 0:00"
	else:
		_update_status("Couldn't start recording the jam.")


func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _show_body() -> void:
	var is_tangle := rig.instrument == "Tangle"
	var sound := _tabs.current_tab == 0
	panel.visible = sound and not is_tangle
	tangle.visible = sound and is_tangle
	seq_view.visible = _tabs.current_tab == 1
	loop_view.visible = _tabs.current_tab == 2
	players_view.get_parent().visible = _tabs.current_tab == 3
	if seq_view.visible:
		seq_view.bind(rig.sequencer, rig.color(), rig.instrument == "Pulsar")
	if loop_view.visible:
		loop_view.bind(rig)


func _build_dialogs() -> void:
	_midi_dialog = MidiSettings.new()
	add_child(_midi_dialog)
	_share_dialog = AcceptDialog.new()
	_share_dialog.title = "Share a sound"
	var v := VBoxContainer.new()
	var help := Label.new()
	help.text = "Copy this code and send it to someone, show them the QR code, or paste their code here and press Load."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(help)
	_share_text = TextEdit.new()
	_share_text.custom_minimum_size = Vector2(580, 160)
	_share_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_share_text.text_changed.connect(_update_share_qr)
	v.add_child(_share_text)
	_share_qr = TextureRect.new()
	_share_qr.custom_minimum_size = Vector2(280, 280)
	_share_qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_share_qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_share_qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	v.add_child(_share_qr)
	var row := HBoxContainer.new()
	var copy := Button.new()
	copy.text = "Copy"
	copy.pressed.connect(func(): DisplayServer.clipboard_set(_share_text.text))
	row.add_child(copy)
	var paste := Button.new()
	paste.text = "Paste"
	paste.pressed.connect(func():
		_share_text.text = DisplayServer.clipboard_get()
		_update_share_qr())
	row.add_child(paste)
	var load := Button.new()
	load.text = "Load"
	load.pressed.connect(_load_shared)
	row.add_child(load)
	var save_qr := Button.new()
	save_qr.text = "Save QR image"
	save_qr.tooltip_text = "Save the QR code as a PNG (user://shared) to print or send"
	save_qr.pressed.connect(_save_share_qr)
	row.add_child(save_qr)
	v.add_child(row)
	_share_dialog.add_child(v)
	add_child(_share_dialog)

	_save_dialog = ConfirmationDialog.new()
	_save_dialog.title = "Save preset"
	_save_name = LineEdit.new()
	_save_name.placeholder_text = "Preset name"
	_save_dialog.add_child(_save_name)
	_save_dialog.confirmed.connect(func():
		var name := _save_name.text.strip_edges()
		if name == "":
			return
		var preset := PresetLibrary.capture(rig.synth, name)
		var path := PresetLibrary.save_user(preset)
		preset["path"] = path
		preset["factory"] = false
		rig.current_preset = preset
		_refresh_presets()
		_update_status("Saved preset '%s'" % name))
	add_child(_save_dialog)


func _open_share() -> void:
	_share_text.text = PresetLibrary.to_code(PresetLibrary.capture(rig.synth, String(rig.current_preset.get("name", "Shared"))))
	_update_share_qr()
	_share_dialog.popup_centered(Vector2i(620, 620))


func _update_share_qr() -> void:
	var code := _share_text.text.strip_edges()
	var qr := QrCode.encode_text(code, QrCode.Ecc.L) if code.begins_with("JAM1:") else null
	_share_qr.texture = ImageTexture.create_from_image(qr.to_image(4, 4)) if qr else null


func _save_share_qr() -> void:
	var code := _share_text.text.strip_edges()
	var qr := QrCode.encode_text(code, QrCode.Ecc.L) if code.begins_with("JAM1:") else null
	if qr == null:
		_update_status("No share code to save.")
		return
	DirAccess.make_dir_recursive_absolute("user://shared")
	var preset := PresetLibrary.from_code(code)
	var name := str(preset.get("name", "sound")).validate_filename() if not preset.is_empty() else "sound"
	var path := "user://shared/%s %s.png" % [str(preset.get("instrument", "")), name]
	qr.to_image(8, 4).save_png(path)
	_update_status("QR code saved to " + ProjectSettings.globalize_path(path))


func _load_shared() -> void:
	var preset := PresetLibrary.from_code(_share_text.text)
	if preset.is_empty():
		_update_status("That code isn't a valid sound code.")
		return
	if preset.instrument != rig.instrument:
		rig.set_instrument(preset.instrument)
		Settings.set_value("instrument", preset.instrument)
	rig.load_preset(preset)
	_share_dialog.hide()
	_update_status("Loaded shared sound '%s'" % preset.get("name", "?"))


func _on_instrument_changed() -> void:
	var t := rig.instrument
	for i in _inst_select.item_count:
		if _inst_select.get_item_text(i) == t:
			_inst_select.select(i)
	var is_tangle := t == "Tangle"
	_add_module.visible = is_tangle
	if is_tangle:
		if tangle.rig == null:
			tangle.bind(rig)
		else:
			tangle.rebuild()
		var popup := _add_module.get_popup()
		popup.clear()
		var i := 0
		for m in tangle.module_types():
			popup.add_item(m.name, i)
			popup.set_item_metadata(i, m.type)
			popup.set_item_tooltip(i, m.description)
			i += 1
	else:
		panel.rebuild()
	_show_body()
	keys.accent = rig.color()
	keys.drum_mode = t == "Pulsar"
	keys.queue_redraw()
	_refresh_presets()


func _refresh_presets() -> void:
	_presets = PresetLibrary.list(rig.instrument)
	_preset_select.clear()
	for p in _presets:
		_preset_select.add_item(("" if p.factory else "★ ") + String(p.name))
	_sync_preset_select()


func _sync_preset_select() -> void:
	for i in _presets.size():
		if _presets[i].get("path", "") == rig.current_preset.get("path", "-"):
			_preset_select.select(i)
			return


func _step_preset(d: int) -> void:
	if _presets.is_empty():
		return
	var i := (_preset_select.selected + d + _presets.size()) % _presets.size()
	_preset_select.select(i)
	rig.load_preset(_presets[i])


func _update_status(extra := "") -> void:
	var dev := "No MIDI devices" if Midi.devices.is_empty() else "MIDI: " + ", ".join(Midi.devices)
	var help := "Keys: A–L play, W E T Y U O P sharps, Z/X octave (%d), C/V velocity (%d)" % [Midi.qwerty_octave, Midi.qwerty_velocity]
	_status.text = "  •  ".join([extra, dev, help].filter(func(s): return s != ""))


func _process(_delta: float) -> void:
	var pk := rig.synth.take_peak()
	_meter.value = maxf(_meter.value * 0.85, maxf(pk.x, pk.y))
	_cpu.text = "DSP %.1f%%" % (rig.synth.get_cpu_load() * 100.0)
	_pos.text = Transport.position_text() if Transport.running else "1.1"
	if recorder.recording:
		var secs := int(recorder.length())
		_rec_jam.text = "■ Stop rec %d:%02d" % [secs / 60, secs % 60]
	if _shot_path != "":
		_shot_frames -= 1
		_shot_after -= _delta
		if _shot_frames <= 0 and _shot_after <= 0.0:
			var img := get_viewport().get_texture().get_image()
			DirAccess.make_dir_recursive_absolute(_shot_path.get_base_dir())
			img.save_png(_shot_path)
			print("screenshot: ", _shot_path)
			get_tree().quit()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		Transport.toggle()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_R:
		rig.looper.press_record()
		get_viewport().set_input_as_handled()
		return
	# Octave/velocity changes show up in the status line.
	if event is InputEventKey and event.pressed:
		_update_status()


func _parse_dev_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--name="):
			Session.player_name = a.trim_prefix("--name=")
		elif a.begins_with("--shot-after="):
			_shot_after = float(a.trim_prefix("--shot-after="))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.trim_prefix("--shot=")
		elif a.begins_with("--instrument="):
			rig.set_instrument(a.trim_prefix("--instrument="))
		elif a == "--seq":
			_tabs.current_tab = 1
		elif a == "--loop":
			_tabs.current_tab = 2
		elif a == "--play":
			Transport.start()
		elif a == "--midi":
			_midi_dialog.popup_centered.call_deferred(Vector2i(620, 560))
		elif a == "--share":
			_open_share.call_deferred()
		elif a == "--jam":
			_tabs.current_tab = 3
		elif a == "--host":
			Session.host()
		elif a.begins_with("--join="):
			Session.join(a.trim_prefix("--join="))
		elif a.begins_with("--frames="):
			_shot_frames = int(a.trim_prefix("--frames="))
