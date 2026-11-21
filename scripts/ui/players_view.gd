class_name PlayersView
extends VBoxContainer
## The Jam tab: host or join a session, and the per-player mixer with each
## player's latency (ping, how late their notes reach you).

var _name: LineEdit
var _ip: LineEdit
var _host: Button
var _join: Button
var _leave: Button
var _status: Label
var _list: VBoxContainer
var _steady: CheckButton
var _rows := {} # id -> latency Label
var _send: CheckButton
var _device: OptionButton
var _channel: OptionButton
var _exclusive: CheckBox
var _in_meter: ProgressBar
var _audio_info: Label
var _in_peak := 0.0


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	add_child(_heading("SESSION"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	row.add_child(_label("Your name"))
	_name = LineEdit.new()
	_name.text = Session.player_name
	_name.custom_minimum_size.x = 160
	_name.max_length = 24
	_name.text_changed.connect(func(t):
		Session.player_name = t.strip_edges() if t.strip_edges() != "" else "Player"
		Settings.set_value("player_name", t.strip_edges()))
	row.add_child(_name)
	_host = _button("Host a jam", func(): Session.host())
	row.add_child(_host)
	row.add_child(_label("   or join"))
	_ip = LineEdit.new()
	_ip.placeholder_text = "host IP, e.g. 192.168.1.20"
	_ip.text = str(Settings.get_value("last_host"))
	_ip.custom_minimum_size.x = 200
	_ip.text_submitted.connect(func(_t): _do_join())
	row.add_child(_ip)
	_join = _button("Join", _do_join)
	row.add_child(_join)
	_leave = _button("Leave", func(): Session.leave())
	row.add_child(_leave)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	add_child(HSeparator.new())
	add_child(_heading("MY AUDIO (mic, voice, real instrument)"))
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 8)
	add_child(arow)
	_send = CheckButton.new()
	_send.text = "Audio input on"
	_send.tooltip_text = "Capture your microphone or audio interface: streamed to everyone while you're in a session, and recordable as audio loops (Looper tab)"
	_send.button_pressed = Session.send_audio
	_send.toggled.connect(func(on): Session.set_send_audio(on))
	arow.add_child(_send)
	arow.add_child(_label("Input"))
	_device = OptionButton.new()
	_device.add_item("System default", 0)
	if ClassDB.class_exists("JamAudioLink"):
		var devs: PackedStringArray = ClassDB.class_call_static("JamAudioLink", "get_input_devices")
		for i in devs.size():
			_device.add_item(devs[i], i + 1)
	_device.custom_minimum_size.x = 260
	_device.item_selected.connect(func(_i): _input_changed())
	arow.add_child(_device)
	_channel = OptionButton.new()
	for t in ["All channels", "Channel 1", "Channel 2", "Channel 3", "Channel 4"]:
		_channel.add_item(t)
	_channel.item_selected.connect(func(_i): _input_changed())
	_channel.select(clampi(Session.input_channel + 1, 0, _channel.item_count - 1))
	_device.select(clampi(Session.input_device + 1, 0, _device.item_count - 1))
	arow.add_child(_channel)
	_exclusive = CheckBox.new()
	_exclusive.text = "Exclusive"
	_exclusive.tooltip_text = "Lowest input latency (about 3 ms instead of 10 ms on most interfaces). Other apps can't use this input meanwhile."
	_exclusive.button_pressed = Session.input_exclusive
	_exclusive.visible = OS.get_name() == "Windows"
	_exclusive.toggled.connect(func(_on): _input_changed())
	arow.add_child(_exclusive)
	_in_meter = ProgressBar.new()
	_in_meter.custom_minimum_size = Vector2(120, 14)
	_in_meter.max_value = 1.0
	_in_meter.show_percentage = false
	_in_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arow.add_child(_in_meter)
	arow.add_child(_label("   Format"))
	var codec := OptionButton.new()
	for c in [["PCM 16-bit (LAN)", "pcm16"], ["PCM 24-bit", "pcm24"], ["Opus 128k (Wi-Fi/internet)", "opus"]]:
		codec.add_item(c[0])
		codec.set_item_metadata(codec.item_count - 1, c[1])
		if c[1] == Session.audio_codec:
			codec.select(codec.item_count - 1)
	codec.item_selected.connect(func(i): Session.set_audio_codec(codec.get_item_metadata(i)))
	arow.add_child(codec)
	arow.add_child(_label("   Buffer"))
	var buf := SpinBox.new()
	buf.min_value = 3
	buf.max_value = 200
	buf.value = Session.audio_buffer_ms
	buf.suffix = "ms"
	buf.tooltip_text = "How much of each player's audio is buffered before it plays. Smaller = less delay, more dropouts on busy networks."
	buf.value_changed.connect(func(v): Session.set_audio_buffer_ms(v))
	arow.add_child(buf)
	_audio_info = Label.new()
	_audio_info.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	add_child(_audio_info)

	add_child(HSeparator.new())
	add_child(_heading("PLAYERS"))
	_steady = CheckButton.new()
	_steady.text = "Steady timing (live notes wait out network jitter; off = play on arrival)"
	_steady.button_pressed = Session.steady_timing
	_steady.toggled.connect(func(on): Session.steady_timing = on)
	add_child(_steady)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	add_child(_list)
	Session.players_changed.connect(_rebuild)
	Session.status_changed.connect(func(_t): _refresh())
	_rebuild()


func _input_changed() -> void:
	Session.set_input(_device.get_selected_id() - 1, _channel.selected - 1, _exclusive.button_pressed)


func _do_join() -> void:
	var ip := _ip.text.strip_edges()
	if ip == "":
		_status.text = "Type the host's IP address first (they see it when they press Host)."
		return
	Settings.set_value("last_host", ip)
	Session.join(ip)


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	var ids := Session.players.keys()
	ids.sort()
	if ids.is_empty():
		var l := _label("Host a jam, or join one, to play with others on your network.")
		l.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		_list.add_child(l)
	for id in ids:
		var p: Dictionary = Session.players[id]
		var r := HBoxContainer.new()
		r.add_theme_constant_override("separation", 10)
		var sw := ColorRect.new()
		sw.color = InstrumentRig.COLORS.get(p.instrument, Color.WHITE)
		sw.custom_minimum_size = Vector2(14, 14)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		r.add_child(sw)
		var n := _label("%s%s  •  %s" % [p.name, " (host)" if id == 1 else "", p.instrument])
		n.custom_minimum_size.x = 260
		r.add_child(n)
		var lat := _label("")
		lat.custom_minimum_size.x = 420
		r.add_child(lat)
		if p.has("rig"):
			var vol := HSlider.new()
			vol.min_value = -40
			vol.max_value = 6
			vol.value = p.volume_db
			vol.custom_minimum_size.x = 140
			vol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			vol.tooltip_text = "How loud this player is for you"
			vol.value_changed.connect(func(v): Session.set_volume(id, v))
			r.add_child(vol)
			r.add_child(_button("Unmute" if p.muted else "Mute", func(): Session.toggle_mute(id)))
		_list.add_child(r)
		_rows[id] = lat
	_refresh()


func _refresh() -> void:
	var online := Session.is_online()
	_host.disabled = online
	_join.disabled = online
	_ip.editable = not online
	_leave.disabled = not online
	_status.text = Session.status
	if not _name.has_focus() and _name.text != Session.player_name:
		_name.text = Session.player_name


func _process(_d: float) -> void:
	if not is_visible_in_tree():
		return
	var a: Object = Session.audio
	_in_peak = maxf(_in_peak * 0.85, a.take_input_peak() if a else 0.0)
	_in_meter.value = _in_peak
	if Session.audio_error != "":
		_audio_info.text = Session.audio_error
	elif not Session.is_online():
		_audio_info.text = ("Input on: you can record audio loops. " if a and a.is_capturing() else "") + "Host or join a session to stream your audio. Monitor yourself through your interface (direct monitoring); the app doesn't play your own input back."
	elif Session.audio_error != "":
		_audio_info.text = Session.audio_error
	elif a and a.is_capturing():
		_audio_info.text = "Sending: input period %.1f ms (%s), %s. Use headphones so others don't hear themselves back." % [a.get_capture_period_ms(), "exclusive" if a.is_capture_exclusive() else "shared", a.get_codec()]
		if Session.input_exclusive and not a.is_capture_exclusive():
			_audio_info.text += " The device refused exclusive mode.
	else:
		_audio_info.text = "Not sending. Everyone else's audio still plays here."
	for id in _rows:
		if Session.players.has(id):
			var t := Session.latency_text(Session.players[id])
			if id == Session.my_id() and Session.role == Session.Role.CLIENT and Session.clock.ready():
				t += "  •  clock synced " + Session.clock_text()
			(_rows[id] as Label).text = t


func _heading(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	return l


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b
