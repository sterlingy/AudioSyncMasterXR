extends Node
## This app's MIDI around SynthKit's `Midi` autoload: applies the saved MIDI
## settings (input channel, computer-keyboard play and velocity) and runs the
## Wi-Fi MIDI relay (NetMidiLink) to another JamSyncXR, e.g. a laptop
## keyboard playing the headset. Autoloaded as `MidiNet`, after Settings and Midi.

signal net_status(text: String)

var net: NetMidiLink
var _saved_velocity := -1


func _ready() -> void:
	Midi.qwerty_velocity = int(Settings.get_value("qwerty_velocity"))
	_saved_velocity = Midi.qwerty_velocity
	_apply_input_settings()
	net = NetMidiLink.new()
	net.name = "NetMidi"
	net.on_message = func(ch: int, type: int, d1: int, d2: int):
		Midi.dispatch_raw(ch, type, d1, d2, true)
	net.status_changed.connect(func(t: String): net_status.emit(t))
	add_child(net)
	Midi.outgoing.connect(_on_outgoing)
	_apply_net_settings()
	Settings.changed.connect(_on_setting)


func _on_setting(key: String) -> void:
	if key.begins_with("net_"):
		_apply_net_settings()
	elif key == "midi_channel" or key == "qwerty_input":
		_apply_input_settings()


func _apply_input_settings() -> void:
	Midi.midi_channel = int(Settings.get_value("midi_channel"))
	Midi.qwerty_input = bool(Settings.get_value("qwerty_input"))


func _apply_net_settings() -> void:
	net.target = str(Settings.get_value("net_target")).strip_edges()
	net.set_sending(bool(Settings.get_value("net_send")))
	var rx = Settings.get_value("net_receive")
	# Receive by default on Android (the headset), not on desktop: binding a
	# port there makes Windows Firewall ask.
	net.set_receiving(OS.has_feature("android") if rx == null else bool(rx))


func _on_outgoing(status: int, d1: int, d2: int) -> void:
	if net.sending:
		net.send_midi(status, d1, d2)


func _process(_delta: float) -> void:
	# The C/V keys change the computer keyboard's velocity; remember it.
	if Midi.qwerty_velocity != _saved_velocity:
		_saved_velocity = Midi.qwerty_velocity
		Settings.set_value("qwerty_velocity", _saved_velocity)
