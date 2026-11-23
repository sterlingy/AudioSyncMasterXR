extends XRToolsMovementProvider
## Keyboard and mouse movement for sessions with no headset.
## Controller locomotion stays on the XR Tools providers.

@export var order: int = 20
@export var max_speed: float = 3.0
@export var mouse_sensitivity: float = 0.003

var _pitch: float = 0.0
var _captured: bool = false


func physics_movement(_delta: float, player_body: XRToolsPlayerBody, _disabled: bool) -> bool:
	if XRToolsStartXR.is_xr_active():
		if _captured:
			_release_mouse()
		return false

	var input := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
	player_body.ground_control_velocity.y += input.y * max_speed
	player_body.ground_control_velocity.x += input.x * max_speed
	var length := player_body.ground_control_velocity.length()
	if length > max_speed:
		player_body.ground_control_velocity *= max_speed / length
	return false


func _unhandled_input(event: InputEvent) -> void:
	if XRToolsStartXR.is_xr_active():
		return
	if event.is_action_pressed("ui_cancel"):
		_release_mouse()
		return
	if event is InputEventMouseButton \
			and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_captured = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if not _captured or not event is InputEventMouseMotion:
		return

	var body := XRToolsPlayerBody.find_instance(self)
	if body:
		body.rotate_player(event.relative.x * mouse_sensitivity)
	var camera := XRHelpers.get_xr_camera(self)
	if camera:
		_pitch = clampf(
			_pitch + event.relative.y * -mouse_sensitivity,
			deg_to_rad(-80.0),
			deg_to_rad(80.0)
		)
		camera.rotation.x = _pitch


func _release_mouse() -> void:
	_captured = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
