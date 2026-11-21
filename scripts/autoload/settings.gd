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
}

var _cfg := ConfigFile.new()


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
