@tool
extends EditorPlugin
## Shivoo XR. Adds the export plugins the addon's nodes and presets need. Godot
## only finds addons/*/plugin.cfg one folder deep, so everything is registered
## from here instead of from its own plugin.cfg.

var _launcher: EditorExportPlugin
var _web_assets: EditorExportPlugin


func _enter_tree() -> void:
	_launcher = preload("launcher/export_plugin.gd").new()
	add_export_plugin(_launcher)
	_web_assets = preload("export/web_assets_export_plugin.gd").new()
	add_export_plugin(_web_assets)


func _exit_tree() -> void:
	remove_export_plugin(_launcher)
	_launcher = null
	remove_export_plugin(_web_assets)
	_web_assets = null
