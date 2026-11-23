extends Node
## Maps XR Tools "primary" actions onto the WebXR thumbstick or trackpad.
## OpenXR already binds "primary" through the default action map.

func _ready() -> void:
	if not OS.has_feature("web"):
		return
	var settings := get_node_or_null("/root/XRToolsUserSettings")
	if settings == null:
		return
	settings.connect("webxr_primary_changed", _apply)
	_apply(settings.call("get_real_webxr_primary"))


func _apply(primary: Variant) -> void:
	var settings := get_node_or_null("/root/XRToolsUserSettings")
	if settings == null:
		return
	var action := str(settings.call("get_webxr_primary_action", primary))
	if action == "auto":
		return
	var origin := XRHelpers.get_xr_origin(self)
	if origin == null:
		return
	for node in origin.find_children("*", "", true, false):
		if "input_action" in node and str(node.input_action) == "primary":
			node.input_action = action
		if "rotation_action" in node and str(node.rotation_action) == "primary":
			node.rotation_action = action
