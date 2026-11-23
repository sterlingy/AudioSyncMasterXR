extends Node
## Shows the real room behind the scene on devices that can: Quest and Android XR
## headsets through OpenXR, browsers that offer immersive-ar (Quest Browser, Chrome
## on Android XR), and phones. Everything else, such as SteamVR, stays in VR.
##
## Nodes in the "hide_in_passthrough" group, like the sandbox floor, are hidden
## while the room is visible. Their collision still works. The world's sky is also
## replaced by a clear background, otherwise it covers the room.
##
## Passthrough is turned on when XR starts, not in _ready(), because XR Tools only
## initializes OpenXR when the player presses Enter VR.

const HIDE_GROUP := &"hide_in_passthrough"

## Use passthrough where the device supports it.
@export var enabled := true
@export var start_xr: XRToolsStartXR
@export var webxr_stereo: Node
## The environment whose background the room replaces. Defaults to the one on the
## viewport's World3D.
@export var world_environment: WorldEnvironment

## True while the room is visible behind the scene.
var active := false

var _openxr: XRInterface
var _environment: Environment
var _background_mode: Environment.BGMode
var _background_color: Color
## The clear color to restore when the session ends.
var _clear_color := Color.BLACK
var _sky_hidden := false


func _ready() -> void:
	if world_environment:
		_environment = world_environment.environment
	if not enabled or start_xr == null:
		return
	start_xr.xr_started.connect(_on_xr_started)
	start_xr.xr_ended.connect(_on_xr_ended)
	# A scene can start XR before this node is ready (XRToolsStartXR auto-start).
	if XRToolsStartXR.is_xr_active():
		_on_xr_started.call_deferred()
	if OS.has_feature("web") and webxr_stereo:
		webxr_stereo.prefer_passthrough = true


func _on_xr_started() -> void:
	_openxr = _enable_openxr_passthrough()
	if _openxr:
		active = true
	elif webxr_stereo and webxr_stereo.passthrough_active:
		active = true
	elif start_xr.xr_interface is WebXRInterface:
		active = (start_xr.xr_interface as WebXRInterface).session_mode == "immersive-ar"
		# XR Tools normally sets this, but the session mode is the authority.
		if active:
			start_xr.get_xr_viewport().transparent_bg = true
	else:
		active = false
	_set_props_visible(not active)
	_set_sky_hidden(active)


func _on_xr_ended() -> void:
	RenderingServer.set_default_clear_color(_clear_color)
	active = false
	_set_props_visible(true)
	_set_sky_hidden(false)


## XR Tools' enable_passthrough leaves the background transparent even when the
## device can't show the room, which turns SteamVR's sky black. Check the runtime
## instead, once the interface is initialized.
func _enable_openxr_passthrough() -> XRInterface:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		return null
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND not in xr.get_supported_environment_blend_modes():
		print("Passthrough: not supported by this OpenXR runtime")
		return null
	if not xr.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND):
		print("Passthrough: failed to switch this OpenXR runtime to alpha blend")
		return null
	start_xr.get_xr_viewport().transparent_bg = true
	_clear_color = RenderingServer.get_default_clear_color()
	RenderingServer.set_default_clear_color(Color(0.0, 0.0, 0.0, 0.0))
	print("Passthrough: on")
	return xr


func _set_props_visible(shown: bool) -> void:
	for node in get_tree().get_nodes_in_group(HIDE_GROUP):
		if node is Node3D:
			node.visible = shown


## Clears the sky while the room is visible. The sky resource stays assigned, so
## ambient and reflection sources that use it keep lighting the scene.
func _set_sky_hidden(hidden: bool) -> void:
	if hidden == _sky_hidden:
		return
	if _environment == null:
		var world := get_viewport().find_world_3d()
		_environment = world.environment if world else null
		if _environment == null:
			return
	if hidden:
		_background_mode = _environment.background_mode
		_background_color = _environment.background_color
		_environment.background_mode = Environment.BG_CLEAR_COLOR
		_environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	else:
		_environment.background_mode = _background_mode
		_environment.background_color = _background_color
	_sky_hidden = hidden
