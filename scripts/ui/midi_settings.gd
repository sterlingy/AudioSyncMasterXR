class_name MidiSettings
extends AcceptDialog
## MIDI setup: connected devices, Bluetooth LE MIDI scanning (Android), the
## input channel, computer-keyboard play and the Wi-Fi MIDI relay.

var _devices: Label
var _bt_status: Label
var _net_status: Label
var _conns: Array = [] # [signal, callable] on autoloads, undone on exit


func _init() -> void:
	title = "MIDI"
	ok_button_text = "Close"
	min_size = Vector2i(560, 0)


func _ready() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	box.add_child(_heading("DEVICES"))
	_devices = Label.new()
	box.add_child(_devices)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	row.add_child(_button("Rescan", Midi.rescan))
	var scan := _button("Scan for Bluetooth MIDI", func():
		_bt_status.text = "Scanning for 15 s… switch your Bluetooth MIDI device on (pairing mode)."
		Midi.scan_bluetooth(15))
	scan.tooltip_text = "Finds Bluetooth LE MIDI keyboards and controllers and connects them (Android). Allow Bluetooth access if asked."
	row.add_child(scan)
	_bt_status = Label.new()
	_bt_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bt_status.custom_minimum_size.x = 560 # a set width, or wrapping makes the dialog full height
	_bt_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	box.add_child(_bt_status)

	box.add_child(HSeparator.new())
	box.add_child(_heading("INPUT"))
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 8)
	box.add_child(crow)
	crow.add_child(_label("Listen on channel"))
	var ch := OptionButton.new()
	ch.add_item("All channels", 0)
	for i in 16:
		ch.add_item("Channel %d" % (i + 1), i + 1)
	ch.select(int(Settings.get_value("midi_channel")) + 1)
	ch.item_selected.connect(func(i): Settings.set_value("midi_channel", i - 1))
	crow.add_child(ch)
	var qw := CheckBox.new()
	qw.text = "Play with the computer keyboard"
	qw.button_pressed = bool(Settings.get_value("qwerty_input"))
	qw.toggled.connect(func(on): Settings.set_value("qwerty_input", on))
	box.add_child(qw)

	box.add_child(HSeparator.new())
	box.add_child(_heading("WI-FI MIDI RELAY (laptop keyboard → headset)"))
	var send := CheckBox.new()
	send.text = "Send this computer's MIDI to another AudioSyncMaster"
	send.button_pressed = bool(Settings.get_value("net_send"))
	send.toggled.connect(func(on): Settings.set_value("net_send", on))
	box.add_child(send)
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 8)
	box.add_child(trow)
	trow.add_child(_label("Send to"))
	var target := LineEdit.new()
	target.placeholder_text = "headset IP (empty = find it automatically)"
	target.text = str(Settings.get_value("net_target"))
	target.custom_minimum_size.x = 360
	target.text_changed.connect(func(t): Settings.set_value("net_target", t.strip_edges()))
	trow.add_child(target)
	var recv := CheckBox.new()
	recv.text = "Receive MIDI sent from another AudioSyncMaster"
	var rx = Settings.get_value("net_receive")
	recv.button_pressed = OS.has_feature("android") if rx == null else bool(rx)
	recv.toggled.connect(func(on): Settings.set_value("net_receive", on))
	box.add_child(recv)
	_net_status = Label.new()
	_net_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_status.custom_minimum_size.x = 560 # a set width, or wrapping makes the dialog full height
	_net_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	box.add_child(_net_status)

	_link(Midi.devices_changed, _show_devices)
	_link(Midi.bluetooth_status, _on_bt_status)
	_link(MidiNet.net_status, _on_net_status)
	_show_devices(Midi.devices)


func _show_devices(names: PackedStringArray) -> void:
	_devices.text = "No MIDI devices connected." if names.is_empty() else "\n".join(names)


func _on_bt_status(t: String) -> void:
	_bt_status.text = t


func _on_net_status(t: String) -> void:
	_net_status.text = t


func _link(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_conns.append([sig, cb])


func _exit_tree() -> void:
	for c in _conns:
		if c[0].is_connected(c[1]):
			c[0].disconnect(c[1])
	_conns.clear()


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
