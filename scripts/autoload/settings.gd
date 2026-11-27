extends Node
## App settings, saved to user://settings.cfg. Autoloaded as `Settings`.

signal changed(key: String)

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"midi_channel": -1, # -1 = omni
	"qwerty_input": true,
	"qwerty_velocity": 100,
	"net_send": false,
	"net_receive": null, # null = platform default (on for Android)
	"net_target": "",
	"master_volume_db": 0.0,
	"instrument": "Undertow",
	"player_name": "",
	"last_host": "",
	"audio_device": "", # input device name ("" = system default)
	"audio_channel": -1,
	"audio_exclusive": false,
	"audio_buffer_ms": 15.0,
	"audio_codec": "pcm16",
	"click_volume_db": 0.0,
	"instrument_audio": false, # send my instrument as audio instead of notes
	"server": "", # connection server host[:port] for online sessions
	"approve_tempo": true, # host: ask before applying a player's tempo change
}

var _cfg := ConfigFile.new()


func _init() -> void:
	UserDataMove.run() # first start after the rename: bring the AudioSyncMaster folder's data over


func _ready() -> void:
	_cfg.load(PATH)


func get_value(key: String) -> Variant:
	if _cfg.has_section_key("app", key):
		return _cfg.get_value("app", key)
	return DEFAULTS.get(key)


func set_value(key: String, value: Variant) -> void:
	if get_value(key) == value:
		return
	_cfg.set_value("app", key, value)
	_cfg.save(PATH)
	changed.emit(key)
