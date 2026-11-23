@tool
extends EditorExportPlugin
## Puts the addon's web scripts into web exports. The nodes that use them read
## them with FileAccess at runtime, which Godot does not follow, so they would be
## left out of the export and fail to load there. Adding them here means a
## project's export presets don't have to name them.

const WEB_DIR := ShivooXRPaths.ADDON_DIR + "/web"
const FILES: Array[String] = [
	"image_tracking.js",
	"mindar_image.js",
	"capture.js",
	"surface_tracking.js",
	"webxr_stereo.js",
	"dom_overlay.js",
]


func _get_name() -> String:
	return "ShivooXRWebAssets"


func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if not features.has("web"):
		return
	for file in FILES:
		var path := WEB_DIR + "/" + file
		if not FileAccess.file_exists(path):
			# The export carries on: only the nodes that use this file break, and
			# they say so when they try to load it.
			push_error("%s: missing, so web exports won't include it" % path)
			continue
		add_file(path, FileAccess.get_file_as_bytes(path), false)
