extends Node
## Stereo WebXR for browsers without the OVR_multiview2 WebGL extension, such as
## Chrome on Galaxy XR. Godot's WebXR interface refuses immersive VR without
## multiview, so web/webxr_stereo.js runs the session and this node renders each
## eye into its own SubViewport, side by side on the canvas, for the script to copy
## into the headset. Add ?stereo=split to the page URL to force this path.

const STEREO_JS := ShivooXRPaths.ADDON_DIR + "/web/webxr_stereo.js"
const BUTTON_NAMES: Array[StringName] = [
	&"trigger_click", &"grip_click", &"touchpad_click", &"thumbstick_click", &"ax_button", &"by_button",
]
const PRESSURE_NAMES: Array[StringName] = [
	&"trigger", &"grip", &"touchpad_click_pressure", &"thumbstick_click_pressure",
	&"ax_button_pressure", &"by_button_pressure",
]
const AXIS_NAMES: Array[StringName] = [&"touchpad_x", &"touchpad_y", &"thumbstick_x", &"thumbstick_y"]
## Godot's WebXR interface turns each joint by this to match its humanoid hand skeleton.
const HUMANOID_JOINT := Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, -1.0, 0.0))

@export var start_xr: XRToolsStartXR
@export var origin: XROrigin3D

## Start an immersive-ar session when the browser offers one. Set by scripts/passthrough.gd.
var prefer_passthrough := false
## True while the running session shows the room behind the scene.
var passthrough_active := false

var _stereo: JavaScriptObject
var _callbacks: Array[JavaScriptObject] = []
var _active := false
var _head: XRPositionalTracker
var _hands := {}
var _hand_trackers := {}
var _layer: CanvasLayer
var _eyes: Array[SubViewport] = []
var _eye_cameras: Array[Camera3D] = []
var _camera_rest := Transform3D()
var _eye_scale := 1.0
var _msaa := Viewport.MSAA_4X
var _disable_shadows := false
var _shadowed_lights: Array[Light3D] = []
var _physics_rest := 0
var _stat_frames := 0
var _stat_process := 0.0
var _stat_physics := 0.0
var _stat_script_usec := 0
var _stat_since_msec := 0


func _ready() -> void:
	set_process(false)
	# Before other scripts read the controllers, so hands match this frame's pose.
	process_priority = -100
	if not OS.has_feature("web") or start_xr == null or origin == null or start_xr.enable_passthrough:
		return
	JavaScriptBridge.eval(FileAccess.get_file_as_string(STEREO_JS), true)
	_stereo = JavaScriptBridge.get_interface("ShivooStereo")
	if _stereo == null or not _stereo.needsFallback():
		return
	_stereo.install()
	_read_test_switches()
	var button := start_xr.get_node("EnterWebXR/EnterVRButton") as Button
	var native := Callable(start_xr, "_on_enter_webxr_button_pressed")
	if button.pressed.is_connected(native):
		button.pressed.disconnect(native)
	button.pressed.connect(_on_enter_pressed)
	print("WebXR: using two-pass stereo. Add ?webxr=native to use Godot's session.")
	if prefer_passthrough:
		_label_button_when_ar_known(button)


## The AR probe answers a moment after load; relabel the button once it does.
func _label_button_when_ar_known(button: Button) -> void:
	for attempt in 20:
		match str(_stereo.arSupported):
			"yes":
				button.text = "Enter AR"
				return
			"no", "timeout":
				return
		await get_tree().create_timer(0.25).timeout


func _wants_ar() -> bool:
	return prefer_passthrough and str(_stereo.arSupported) == "yes"


func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	var json := str(_stereo.frameJson)
	if json.is_empty():
		return
	var frame = JSON.parse_string(json)
	if not frame is Dictionary:
		return
	if frame["head"] != null:
		_head.set_pose(&"default", _to_transform(frame["head"], false), Vector3.ZERO, Vector3.ZERO,
				XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_update_hands(frame["inputs"])
	_update_eyes(frame["views"])
	_stat_script_usec += Time.get_ticks_usec() - started
	_report_stats()


## ?eyescale=0.5 renders each eye at half size, ?msaa=0|2|4 sets antialiasing,
## ?shadows=0 turns off light shadows during VR. Used to find what costs time.
func _read_test_switches() -> void:
	var scale := str(_stereo.param("eyescale"))
	if not scale.is_empty():
		_eye_scale = clampf(scale.to_float(), 0.1, 1.0)
	match str(_stereo.param("msaa")):
		"0":
			_msaa = Viewport.MSAA_DISABLED
		"2":
			_msaa = Viewport.MSAA_2X
		"8":
			_msaa = Viewport.MSAA_8X
	_disable_shadows = str(_stereo.param("shadows")) == "0"


## Godot's share of the frame, sent to the page once a second for its console line.
func _report_stats() -> void:
	_stat_frames += 1
	_stat_process += Performance.get_monitor(Performance.TIME_PROCESS)
	_stat_physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	var now := Time.get_ticks_msec()
	if _stat_since_msec == 0:
		_stat_since_msec = now
		return
	if now - _stat_since_msec < 1000:
		return
	_match_physics_rate()
	var n := float(_stat_frames)
	var eye := _eyes[0].size if not _eyes.is_empty() else Vector2i.ZERO
	_stereo.godotInfo = "physics rate %d Hz, process %.1f ms, physics %.1f ms, this script %.2f ms, draws %d, objects %d, eye %dx%d, msaa %d, shadows %s" % [
		Engine.physics_ticks_per_second,
		_stat_process / n * 1000.0,
		_stat_physics / n * 1000.0,
		_stat_script_usec / n / 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		eye.x, eye.y,
		[0, 2, 4, 8][_msaa],
		"off" if _disable_shadows else "on",
	]
	_stat_frames = 0
	_stat_process = 0.0
	_stat_physics = 0.0
	_stat_script_usec = 0
	_stat_since_msec = now


## XR Tools hands follow the controller in _physics_process. Native StartXR sets
## the physics rate to the headset refresh rate so they move once per frame;
## without that they step unevenly and look stuttery next to the head.
func _match_physics_rate() -> void:
	var rate := roundi(float(_stereo.frameRate) * start_xr.physics_rate_multiplier)
	if rate > 0 and rate != Engine.physics_ticks_per_second:
		print("WebXR: setting physics rate to %d to match the headset" % rate)
		Engine.physics_ticks_per_second = rate


func _on_enter_pressed() -> void:
	if _active:
		return
	# "pending" and "timeout" still try: the probe is slow on some headsets.
	var ar := _wants_ar()
	if not ar and str(_stereo.vrSupported) == "no":
		OS.alert("This browser can't start an immersive VR session.")
		return
	_callbacks = [
		JavaScriptBridge.create_callback(_on_session_started),
		JavaScriptBridge.create_callback(_on_session_ended),
		JavaScriptBridge.create_callback(_on_session_failed),
	]
	_stereo.start(_callbacks[0], _callbacks[1], _callbacks[2], "immersive-ar" if ar else "immersive-vr")


func _on_session_started(_args: Array) -> void:
	_begin.call_deferred()


func _on_session_ended(_args: Array) -> void:
	_end.call_deferred()


func _on_session_failed(args: Array) -> void:
	OS.alert("Unable to enter VR: " + str(args[0] if args.size() > 0 else "unknown error"))


func _begin() -> void:
	_active = true
	var camera := _find_xr_camera()
	if camera:
		_camera_rest = camera.transform
	_head = XRPositionalTracker.new()
	_head.type = XRServer.TRACKER_HEAD
	_head.name = &"head"
	XRServer.add_tracker(_head)
	_layer = CanvasLayer.new()
	_layer.layer = 128
	add_child(_layer)
	# The eyes and the page canvas keep alpha so the headset shows the room behind them.
	passthrough_active = str(_stereo.sessionMode) == "immersive-ar"
	get_viewport().transparent_bg = passthrough_active
	get_viewport().disable_3d = true
	_set_tracking_interpolation(true)
	_physics_rest = Engine.physics_ticks_per_second
	if _disable_shadows:
		for light: Light3D in get_tree().root.find_children("*", "Light3D", true, false):
			if light.shadow_enabled:
				light.shadow_enabled = false
				_shadowed_lights.append(light)
	start_xr.get_node("EnterWebXR").visible = false
	XRToolsStartXR._xr_active = true
	start_xr.xr_started.emit()
	set_process(true)


func _end() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	for tracker in _hands.values():
		XRServer.remove_tracker(tracker)
	_hands.clear()
	for tracker in _hand_trackers.values():
		XRServer.remove_tracker(tracker)
	_hand_trackers.clear()
	XRServer.remove_tracker(_head)
	_head = null
	_clear_eyes()
	_layer.queue_free()
	_layer = null
	get_viewport().disable_3d = false
	passthrough_active = false
	get_viewport().transparent_bg = false
	_set_tracking_interpolation(false)
	Engine.physics_ticks_per_second = _physics_rest
	for light in _shadowed_lights:
		if is_instance_valid(light):
			light.shadow_enabled = true
	_shadowed_lights.clear()
	start_xr.get_node("EnterWebXR").visible = true
	var camera := _find_xr_camera()
	if camera:
		camera.transform = _camera_rest
	XRToolsStartXR._xr_active = false
	start_xr.xr_ended.emit()


func _update_hands(inputs: Array) -> void:
	var seen := {}
	for input: Dictionary in inputs:
		var hand: String = input["hand"]
		seen[hand] = true
		var tracker: XRControllerTracker = _hands.get(hand)
		if tracker == null:
			tracker = XRControllerTracker.new()
			tracker.type = XRServer.TRACKER_CONTROLLER
			tracker.name = StringName(hand + "_hand")
			tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
			tracker.profile = input["profile"]
			XRServer.add_tracker(tracker)
			_hands[hand] = tracker
		_set_pose(tracker, &"default", input["aim"])
		_set_pose(tracker, &"aim", input["aim"])
		_set_pose(tracker, &"grip", input["grip"])
		_update_inputs(tracker, input)
		_update_hand_joints(hand, input.get("joints"))
	for hand in _hands.keys():
		if not seen.has(hand):
			XRServer.remove_tracker(_hands[hand])
			_hands.erase(hand)
	for hand in _hand_trackers.keys():
		if not seen.has(hand):
			_update_hand_joints(hand, null)


## Same /user/hand_tracker/<side> trackers Godot's WebXR and OpenXR interfaces
## make, so hand skeletons work the same way on the web and on desktop.
func _update_hand_joints(hand: String, joints) -> void:
	var tracker: XRHandTracker = _hand_trackers.get(hand)
	if not joints is Array or (joints as Array).size() < 25 * 16:
		if tracker:
			tracker.has_tracking_data = false
			tracker.invalidate_pose(&"default")
		return
	if tracker == null:
		tracker = XRHandTracker.new()
		tracker.name = StringName("/user/hand_tracker/" + hand)
		tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
		tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
		var flags := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID \
				| XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED
		for joint in XRHandTracker.HAND_JOINT_MAX:
			tracker.set_hand_joint_flags(joint, flags)
		XRServer.add_tracker(tracker)
		_hand_trackers[hand] = tracker
	tracker.has_tracking_data = true
	# WebXR has no palm joint; Godot's index 0 is the palm, so WebXR joint i is Godot joint i + 1.
	for i in 25:
		var joint := _to_transform(joints, false, i * 16)
		joint.basis *= HUMANOID_JOINT
		tracker.set_hand_joint_transform(i + 1, joint)
	# The palm sits halfway along the middle finger metacarpal, as in Godot's WebXR code.
	var palm := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL)
	palm.origin = (palm.origin + tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL).origin) * 0.5
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, palm)
	tracker.set_pose(&"default", palm, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _set_pose(tracker: XRControllerTracker, pose: StringName, matrix) -> void:
	if matrix == null:
		tracker.invalidate_pose(pose)
	else:
		tracker.set_pose(pose, _to_transform(matrix, false), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Same input names as Godot's WebXR interface, so XR Tools and action maps match.
func _update_inputs(tracker: XRControllerTracker, input: Dictionary) -> void:
	var standard: bool = input["standard"]
	var buttons: Array = input["buttons"]
	for i in buttons.size():
		var value: float = buttons[i]
		var named := standard and i < BUTTON_NAMES.size()
		tracker.set_input(BUTTON_NAMES[i] if named else StringName("button_%d" % i), value > 0.0)
		tracker.set_input(PRESSURE_NAMES[i] if named else StringName("button_pressure_%d" % i), value)
	var axes: Array = input["axes"]
	for i in axes.size():
		var value: float = axes[i]
		if standard and i < AXIS_NAMES.size():
			tracker.set_input(AXIS_NAMES[i], -value if i == 1 or i == 3 else value)
		else:
			tracker.set_input(StringName("axis_%d" % i), value)
	if standard:
		if axes.size() >= 2:
			tracker.set_input(&"touchpad", Vector2(axes[0], -axes[1]))
		if axes.size() >= 4:
			tracker.set_input(&"thumbstick", Vector2(axes[2], -axes[3]))
	# Hands have no gamepad, so the browser's gesture stands in for it. Godot's
	# OpenXR hand interaction profile binds grasp to grip and pinch to trigger,
	# and XR Tools grabs on grip, so closing the hand grabs as it does natively.
	if input.get("isHand", false):
		var grasp: float = input.get("grasp", 0.0)
		var pinch: float = input.get("pinch", 0.0)
		tracker.set_input(&"grip", grasp)
		tracker.set_input(&"grip_click", grasp > 0.5)
		tracker.set_input(&"trigger", pinch)
		tracker.set_input(&"trigger_click", pinch > 0.5)


func _update_eyes(views: Array) -> void:
	if views.size() != _eyes.size():
		_build_eyes(views.size())
	for i in views.size():
		var view: Dictionary = views[i]
		var box: Array = view["viewport"]
		var size := _eye_size(box, view["projection"])
		# A one-pixel change recreates the eye target and the picture flashes.
		if _eyes[i].size != Vector2i.ZERO and absi(_eyes[i].size.x - size.x) < 16 and absi(_eyes[i].size.y - size.y) < 16:
			size = _eyes[i].size
		if _eyes[i].size != size:
			_eyes[i].size = size
			print("WebXR: eye %d renders %dx%d for a %dx%d headset viewport" % [i, size.x, size.y, box[2], box[3]])
		var camera := _eye_cameras[i]
		camera.global_transform = origin.global_transform * _to_transform(view["transform"])
		_apply_projection(camera, view["projection"])


## Godot takes a frustum's width from the eye's pixel aspect, so the eye must have
## the projection's shape or the picture is squashed. Headsets don't always size
## their viewport to match; the copy stretches the eye back into it. Same pixel
## count as the headset viewport, so the cost doesn't change.
func _eye_size(box: Array, p: Array) -> Vector2i:
	var pixels := float(box[2]) * float(box[3]) * _eye_scale * _eye_scale
	var aspect: float = p[5] / p[0]
	return Vector2i(maxi(1, roundi(sqrt(pixels * aspect))), maxi(1, roundi(sqrt(pixels / aspect))))


func _build_eyes(count: int) -> void:
	_clear_eyes()
	var world := get_viewport().find_world_3d()
	var xr_camera := _find_xr_camera()
	for i in count:
		var viewport := SubViewport.new()
		viewport.world_3d = world
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.transparent_bg = passthrough_active
		# 4x by default, the same MSAA Three.js asks for with antialias: true.
		viewport.msaa_3d = _msaa
		viewport.audio_listener_enable_3d = i == 0
		add_child(viewport)
		var camera := Camera3D.new()
		if xr_camera:
			camera.near = xr_camera.near
			camera.far = xr_camera.far
			camera.cull_mask = xr_camera.cull_mask
		viewport.add_child(camera)
		camera.current = true
		var rect := TextureRect.new()
		rect.texture = viewport.get_texture()
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.anchor_left = float(i) / count
		rect.anchor_right = float(i + 1) / count
		rect.anchor_bottom = 1.0
		_layer.add_child(rect)
		_eyes.append(viewport)
		_eye_cameras.append(camera)


func _clear_eyes() -> void:
	for viewport in _eyes:
		viewport.queue_free()
	_eyes.clear()
	_eye_cameras.clear()
	if _layer:
		for child in _layer.get_children():
			child.queue_free()


## Converts the WebXR projection matrix into an off-center frustum at the near plane.
func _apply_projection(camera: Camera3D, p: Array) -> void:
	var near := camera.near
	var left: float = (p[8] - 1.0) / p[0]
	var right: float = (p[8] + 1.0) / p[0]
	var bottom: float = (p[9] - 1.0) / p[5]
	var top: float = (p[9] + 1.0) / p[5]
	var offset := Vector2(left + right, bottom + top) * 0.5 * near
	camera.set_frustum((top - bottom) * near, offset, near, camera.far)


## Tracking is applied every headset frame. Physics interpolation blends those
## poses toward the physics tick, which is what makes web hands look choppy
## next to the native Windows build.
func _set_tracking_interpolation(tracking: bool) -> void:
	var mode := Node.PHYSICS_INTERPOLATION_MODE_OFF if tracking else Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	origin.physics_interpolation_mode = mode
	for child in origin.get_children():
		if child is Node3D:
			child.physics_interpolation_mode = mode


func _find_xr_camera() -> XRCamera3D:
	for child in origin.get_children():
		if child is XRCamera3D:
			return child
	return null


## WebXR matrices are column-major, in meters, relative to the reference space.
## XRPose applies world scale itself, so tracker poses pass scaled = false.
func _to_transform(m: Array, scaled := true, offset := 0) -> Transform3D:
	var basis := Basis(Vector3(m[offset], m[offset + 1], m[offset + 2]), Vector3(m[offset + 4], m[offset + 5], m[offset + 6]),
			Vector3(m[offset + 8], m[offset + 9], m[offset + 10]))
	var position := Vector3(m[offset + 12], m[offset + 13], m[offset + 14])
	return Transform3D(basis, position * XRServer.world_scale if scaled else position)
