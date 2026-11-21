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
var _rows := {} # id -> {latency: Label}


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
