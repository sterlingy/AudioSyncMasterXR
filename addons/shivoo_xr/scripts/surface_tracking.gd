class_name SurfaceTracking
extends Node3D
## Finds real surfaces, such as floors, tables and walls, in phone browsers that
## offer WebXR immersive-ar sessions with hit testing (Chrome on Android, with
## Google Play Services for AR). web/surface_tracking.js runs the hit tests in
## Godot's session; this node reports where the middle of the screen meets a
## surface, and signals each touch with where the finger's ray meets surfaces.
## SurfacePlacement nodes under it are placed by the place button.

## A finger went down on the screen.
signal touch_started(touch: SurfaceTouch)
## Every frame while a finger is down, with where it now is.
signal touch_moved(touch: SurfaceTouch)
## A finger was lifted, or the session ended.
signal touch_ended(touch: SurfaceTouch)

const SURFACES_JS := ShivooXRPaths.ADDON_DIR + "/web/surface_tracking.js"

@export var xr_origin: XROrigin3D
@export var xr_camera: XRCamera3D
@export var start_button: Button
@export var status_label: Label
## The splash, status and place/reset buttons.
@export var hud: TrackingHud
## The content the place button puts on the surface in the middle of the screen.
@export var placement: SurfacePlacement

## Whether the ray through the middle of the screen meets a surface.
var has_center_hit := false
## Where it does, in global space, with +Y out of the surface.
var center_hit := Transform3D.IDENTITY

var _surfaces: JavaScriptObject
var _webxr: WebXRInterface
var _last_frame := ""
## SurfaceTouch by id, while the finger is down.
var _touches := {}
var _msaa_outside_xr := Viewport.MSAA_DISABLED


func _ready() -> void:
	set_process(false)
	start_button.disabled = true
	if hud:
		hud.place_pressed.connect(_on_place_pressed)
		hud.reset_pressed.connect(_on_reset_pressed)
		hud.review_closed.connect(_on_review_closed)
		# This scene never draws the camera feed into the canvas flat, so capture has
		# nothing to composite until a session gives the page the camera image.
		hud.set_capture_available(false)
	if not OS.has_feature("web"):
		status_label.text = "Surface tracking runs in the web export, in Chrome on Android."
		return
	_webxr = XRServer.find_interface("WebXR") as WebXRInterface
	if _webxr == null:
		status_label.text = "This browser has no WebXR."
		# Nothing can start, so the splash would never lift off the message.
		start_button.visible = false
		return
	JavaScriptBridge.eval(FileAccess.get_file_as_string(SURFACES_JS), true)
	_surfaces = JavaScriptBridge.get_interface("ShivooSurfaceTracking")
	_surfaces.prepare()
	start_button.pressed.connect(_on_start_pressed)
	_webxr.session_supported.connect(_on_session_supported)
	_webxr.session_started.connect(_on_session_started)
	_webxr.session_ended.connect(_on_session_ended)
	_webxr.session_failed.connect(_on_session_failed)
	status_label.text = "Checking for AR..."
	_webxr.is_session_supported("immersive-ar")


func _on_session_supported(session_mode: String, supported: bool) -> void:
	if session_mode != "immersive-ar":
		return
	start_button.disabled = not supported
	if not supported:
		start_button.visible = false
	status_label.text = "Press Start, then move the phone slowly to find surfaces." if supported else \
		"This browser has no WebXR AR. Chrome on Android, with Google Play Services for AR, has."


func _on_start_pressed() -> void:
	_webxr.session_mode = "immersive-ar"
	_webxr.required_features = "local, hit-test"
	# Wanted, not required: the session runs without it, minus capture.
	_webxr.optional_features = "camera-access"
	_webxr.requested_reference_space_types = "local"
	if _webxr.initialize():
		start_button.visible = false
		status_label.text = "Starting AR..."
	else:
		status_label.text = "Couldn't start AR."


func _on_session_started() -> void:
	# The page composites the camera image under the layer Godot renders into.
	if hud:
		hud.set_capture_in_xr(true)
		hud.refresh_layout.call_deferred()
	# Godot resolves MSAA into WebXR's textures with one blit of color and depth,
	# which WebGL rejects because the depth formats differ, leaving the view empty.
	_msaa_outside_xr = get_viewport().msaa_3d
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().use_xr = true
	xr_camera.current = true
	_surfaces.start(_webxr.reference_space_type)
	set_process(true)


func _on_session_ended() -> void:
	set_process(false)
	get_viewport().use_xr = false
	get_viewport().msaa_3d = _msaa_outside_xr
	_last_frame = ""
	has_center_hit = false
	if placement:
		placement.hide_preview()
	if hud:
		hud.show_place_ui(false)
		hud.show_reset_ui(false)
	_release_touches()
	start_button.visible = true
	if hud:
		hud.set_capture_in_xr(false)
		hud.set_capture_available(true)
		hud.refresh_layout.call_deferred()
	status_label.text = "Press Start, then move the phone slowly to find surfaces."


func _on_session_failed(message: String) -> void:
	start_button.visible = true
	status_label.text = "Couldn't start AR: " + message


func _process(_delta: float) -> void:
	var state := str(_surfaces.state)
	if state != "running":
		status_label.text = "Surface tracking: " + state
		return
	var json := str(_surfaces.frameJson)
	if json == _last_frame or json.is_empty():
		return
	_last_frame = json
	var frame = JSON.parse_string(json)
	if not frame is Dictionary:
		return
	# With the camera open the fingers are its buttons, not gestures on the content.
	if hud and hud.capture_open():
		_give_screen_to_capture()
		return
	# Hits come in the session's reference space, which is the origin's.
	var room := xr_origin.global_transform
	var center: Array = frame["center"]
	has_center_hit = not center.is_empty()
	if has_center_hit:
		center_hit = room * _matrix_transform(center[0])
	# It shows see-through under the middle of the screen until it is placed, which
	# is the only thing that has to mark where it would go.
	if placement and not placement.placed:
		if has_center_hit:
			placement.preview_at(center_hit, xr_camera.global_position)
		else:
			placement.hide_preview()
	if hud:
		hud.show_place_ui(has_center_hit and not (placement != null and placement.placed))
		hud.show_reset_ui(placement != null and placement.placed)
	status_label.text = "" if has_center_hit or not _touches.is_empty() else "Move the phone slowly to find surfaces."
	for event: Dictionary in frame["touches"]:
		var id := int(event["id"])
		var touch: SurfaceTouch = _touches.get(id)
		if touch == null:
			touch = SurfaceTouch.new()
			touch.id = id
			_touches[id] = touch
		touch.ray = room * _matrix_transform(event["ray"])
		touch.hits.clear()
		for hit: Array in event["hits"]:
			touch.hits.append(room * _matrix_transform(hit))
		match str(event["phase"]):
			"start":
				touch_started.emit(touch)
			"move":
				touch_moved.emit(touch)
			"end":
				_touches.erase(id)
				touch_ended.emit(touch)


## Drops every finger the content is following, as when the session ends or the
## camera takes the screen: the content stops moving where it is.
func _release_touches() -> void:
	for touch: SurfaceTouch in _touches.values():
		touch_ended.emit(touch)
	_touches.clear()


## Leaves the screen to the camera: the fingers on its buttons are not gestures on
## the content, and nothing the scene would draw belongs in the shot.
func _give_screen_to_capture() -> void:
	_release_touches()
	if placement:
		placement.hide_preview()
	status_label.text = ""


## Puts the content down where the middle of the screen points.
func _on_place_pressed() -> void:
	if not has_center_hit or placement == null:
		return
	var touch := SurfaceTouch.new()
	touch.ray = xr_camera.global_transform
	touch.hits.append(center_hit)
	placement.place_at(touch)


func _on_reset_pressed() -> void:
	if placement:
		placement.reset()


## The review screen after a capture taken in AR closed: the session ended for it,
## so start one again. A new session has a new origin, so content placed on a
## surface goes too.
func _on_review_closed() -> void:
	if placement:
		placement.reset()
	_on_start_pressed()


## A column-major 4x4 matrix, as WebXR gives them.
func _matrix_transform(m: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])),
		Vector3(m[12], m[13], m[14]))
