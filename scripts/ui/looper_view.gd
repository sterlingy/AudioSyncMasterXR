class_name LooperView
extends VBoxContainer
## Personal looper controls (slots, record/overdub, play, undo, clear, mute,
## push to master) and the master looper's layer list with listening modes.

var rig: InstrumentRig
var _slot_buttons: Array[Button] = []
var _rec: Button
var _play: Button
var _len: SpinBox
var _state: Label
var _master_list: VBoxContainer
var _listen: OptionButton


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	add_child(_heading("MY LOOPER"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	for i in Looper.SLOTS:
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(120, 48)
		b.pressed.connect(func(): _select(i))
		row.add_child(b)
		_slot_buttons.append(b)
	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 8)
	add_child(ctl)
	_rec = _button("● Record", func(): rig.looper.press_record())
	_rec.tooltip_text = "Record on the next bar; while playing, overdub one pass (R)"
	ctl.add_child(_rec)
	_play = _button("▶ Play", func(): rig.looper.toggle_play())
	ctl.add_child(_play)
	ctl.add_child(_button("Undo", func(): rig.looper.undo()))
	ctl.add_child(_button("Clear", func(): rig.looper.clear()))
	ctl.add_child(_button("Mute", func(): rig.looper.toggle_mute()))
	var l := Label.new()
	l.text = "Length (bars)"
	ctl.add_child(l)
	_len = SpinBox.new()
	_len.min_value = 1
	_len.max_value = 16
	_len.value = 2
	_len.value_changed.connect(func(v): rig.looper.length_bars = int(v))
	ctl.add_child(_len)
	ctl.add_child(_button("Send to Master →", _push_master))
	_state = Label.new()
	_state.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	add_child(_state)

	add_child(HSeparator.new())
	add_child(_heading("MASTER LOOPER"))
	var lrow := HBoxContainer.new()
	var ll := Label.new()
	ll.text = "I hear:"
	lrow.add_child(ll)
	_listen = OptionButton.new()
	_listen.add_item("Master looper + everyone live")
	_listen.add_item("Only my loops + everyone live")
	_listen.add_item("Only my loops")
	_listen.item_selected.connect(func(i): MasterLooper.set_listen(i))
	lrow.add_child(_listen)
	add_child(lrow)
	_master_list = VBoxContainer.new()
	add_child(_master_list)
	MasterLooper.changed.connect(_refresh_master)
	_refresh_master()


func bind(p_rig: InstrumentRig) -> void:
	rig = p_rig
	if not rig.looper.changed.is_connected(_refresh):
		rig.looper.changed.connect(_refresh)
	_refresh()


func _process(_d: float) -> void:
	if is_visible_in_tree() and rig:
		_refresh()


func _select(i: int) -> void:
	rig.looper.current = i
	_len.set_value_no_signal(rig.looper.slots[i].bars if rig.looper.slots[i].state != Looper.State.EMPTY else rig.looper.length_bars)
	_refresh()


func _refresh() -> void:
	var lp := rig.looper
	var colors := {Looper.State.EMPTY: Color(0.2, 0.2, 0.24), Looper.State.ARMED: Color("ffd166"), Looper.State.RECORDING: Color("ff4f5e"),
		Looper.State.PLAYING: rig.color(), Looper.State.OVERDUB_ARMED: Color("ffb347"), Looper.State.OVERDUBBING: Color("ff7a45"), Looper.State.STOPPED: Color(0.35, 0.35, 0.4)}
	for i in _slot_buttons.size():
		var s: Dictionary = lp.slots[i]
		var b := _slot_buttons[i]
		b.set_pressed_no_signal(i == lp.current)
		b.text = "Slot %d\n%s%s" % [i + 1, lp.state_name(s), " (muted)" if s.muted else ""]
		var sb := StyleBoxFlat.new()
		sb.bg_color = colors[s.state].darkened(0.0 if i == lp.current else 0.35)
		sb.set_corner_radius_all(6)
		if i == lp.current:
			sb.set_border_width_all(2)
			sb.border_color = Color.WHITE
		for st in ["normal", "pressed", "hover"]:
			b.add_theme_stylebox_override(st, sb)
	var s: Dictionary = lp.slot()
	_rec.text = "● Overdub" if s.state in [Looper.State.PLAYING, Looper.State.STOPPED] else ("■ Stop Rec" if s.state in [Looper.State.RECORDING, Looper.State.OVERDUBBING] else "● Record")
	_play.text = "■ Stop" if s.state in [Looper.State.PLAYING, Looper.State.OVERDUBBING, Looper.State.OVERDUB_ARMED] else "▶ Play"
	var layers: int = s.layers.size()
	_state.text = "Slot %d: %s, %d bar(s), %d layer(s). Recording starts and stops on bar lines; notes snap to the quantize grid." % [lp.current + 1, lp.state_name(s), s.bars, layers]


func _push_master() -> void:
	var data := rig.looper.export_slot()
	if MasterLooper.add_layer(data) < 0:
		_state.text = "Record something in this slot first."


func _refresh_master() -> void:
	if _master_list == null:
		return
	for c in _master_list.get_children():
		c.queue_free()
	if MasterLooper.layers.is_empty():
		var l := Label.new()
		l.text = "No layers yet. Record a loop above, then Send to Master."
		l.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		_master_list.add_child(l)
	for layer in MasterLooper.layers:
		var row := HBoxContainer.new()
		var swatch := ColorRect.new()
		swatch.color = InstrumentRig.COLORS.get(layer.instrument, Color.WHITE)
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var l := Label.new()
		l.text = "  %s  •  %d bar(s)  •  by %s" % [layer.instrument, layer.bars, layer.owner]
		l.custom_minimum_size.x = 360
		row.add_child(l)
		var id: int = layer.id
		var mute := _button("Unmute" if layer.muted else "Mute", func(): MasterLooper.toggle_mute(id))
		row.add_child(mute)
		var del := _button("Delete", func(): MasterLooper.remove_layer(id))
		del.disabled = not MasterLooper.can_delete(layer)
		del.tooltip_text = "Only the layer's owner or the host can delete it"
		row.add_child(del)
		_master_list.add_child(row)


func _heading(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	return l


func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b
