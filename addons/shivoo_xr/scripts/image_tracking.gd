class_name ImageTracking
extends Node3D
## Image and marker tracking. On phone browsers, web/image_tracking.js runs MindAR,
## in a worker, on the camera feed shown behind the transparent canvas; this node
## matches the camera's field of view to that feed and moves each ImageTarget node
## under it onto its image, showing it while the image is tracked.
##
## On native OpenXR devices the same node uses the runtime's spatial marker
## tracking: each ImageTarget follows the QR code whose marker_payload it names, or
## the ArUco/AprilTag whose marker_id it names. Support is runtime-dependent:
## Quest 3 on Horizon OS v83+ and Android XR track QR codes; Steam Frame and PCVR
## currently do not. Native scenes still start XR through their player rig.
##
## Add ?source=synthetic to the page URL to track a rendered target instead of the
## camera, for testing on a desktop.
##
## With persist_in_world, where the browser offers a WebXR immersive-ar session
## with camera access (Chrome on Android), MindAR tracks that session's camera
## instead, and targets are placed in the room the phone tracks, so they stay where
## their image was when it is lost.
##
## With follow_session, the scene starts the WebXR session itself (XRToolsStartXR
## with passthrough, as phones do): this node asks that session for camera access
## and tracks its camera while it runs, with no Start button, status label or HUD
## of its own.

## Emitted each frame a target is placed from a fresh tracked pose (not when a
## lost target is held where it was), after its global transform is set.
signal target_posed(target: ImageTarget)

const TRACKING_JS := ShivooXRPaths.ADDON_DIR + "/web/image_tracking.js"
const MINDAR_JS := ShivooXRPaths.ADDON_DIR + "/web/mindar_image.js"
## Target content is authored with +Y out of the image and -Z towards its top edge,
## where MindAR uses +Z out of the image and +Y towards the top edge.
const IMAGE_TO_ANCHOR := Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.0, -1.0, 0.0))
## While the room is tracked, a lost target is kept for the rest of the session.
const WORLD_HOLD_MS := 1.0e9
## Runtime permissions for spatial data, which marker tracking reads: Meta's, and
## Android XR's.
const SPATIAL_PERMISSIONS := ["com.oculus.permission.USE_SCENE", "android.permission.SCENE_UNDERSTANDING_COARSE"]

@export var camera: Camera3D
@export var start_button: Button
@export var status_label: Label
## The splash, status and permission screens.
@export var hud: TrackingHud
## Keep targets where their images are in the room, using the phone's world
## tracking where the browser offers it. Elsewhere targets show only while their
## image is tracked.
@export var persist_in_world := false
## Used while persist_in_world has a WebXR session running.
@export var xr_origin: XROrigin3D
@export var xr_camera: XRCamera3D
## Run MindAR in the web export. Native always uses the runtime's markers;
## scenes that only use the native marker can turn the web half off.
@export var web_enabled := true
## Web: track the camera of the immersive-ar session the scene's player rig
## starts, instead of starting one from start_button. Needs xr_origin.
@export var follow_session := false
## With follow_session, the node that starts that session and reports when it is
## running: a godot-xr-tools StartXR. Needed where the page starts the session
## itself (its two-pass stereo path), which Godot's WebXR interface never sees.
@export var start_xr: Node

var _tracking: JavaScriptObject
## The first one's image is what the synthetic test feed shows, and what WebXR
## sessions register so the camera can autofocus on it where the browser allows.
var _targets: Array[ImageTarget] = []
var _dimensions: Array = []
var _last_frame := ""
var _webxr: WebXRInterface
var _world_tracking_offered := false
var _in_xr := false
var _msaa_outside_xr := Viewport.MSAA_DISABLED
## Whether this run uses the runtime's marker trackers instead of MindAR.
var _native := false
## Tracker name -> the XRAnchor3D that follows it.
var _native_anchors := {}
## Tracker name -> the ImageTarget placed on it.
var _native_targets := {}
## Trackers whose first placement has been logged.
var _native_placed := {}


func _ready() -> void:
	_targets.assign(find_children("*", "ImageTarget", true, false))
	for target in _targets:
		target.visible = false
	set_process(false)
	# XRNode3D updates its transform earlier in the frame, so read it after.
	process_priority = 100
	if OS.has_feature("web"):
		if web_enabled:
			_setup_web()
		else:
			set_process(false)
	else:
		_setup_native()


func _setup_web() -> void:
	if _targets.is_empty():
		_set_status("Add an ImageTarget node under %s." % name)
		if start_button:
			start_button.disabled = true
		return
	JavaScriptBridge.eval(FileAccess.get_file_as_string(TRACKING_JS), true)
	_tracking = JavaScriptBridge.get_interface("ShivooImageTracking")
	# MindAR runs in a worker that image_tracking.js makes from this source.
	_tracking.library = FileAccess.get_file_as_string(MINDAR_JS)
	if follow_session:
		_setup_follow_session()
		return
	start_button.pressed.connect(_on_start_pressed)
	if hud:
		hud.review_closed.connect(_on_review_closed)
	_set_status("Press Start, then point the camera at the image.")
	_webxr = XRServer.find_interface("WebXR") as WebXRInterface
	if persist_in_world and _webxr and xr_origin and xr_camera:
		# Lets ARCore autofocus on it, where the browser can.
		_tracking.setXRTrackedImage(_png_base64(_targets[0].printed_image()), _targets[0].width)
		_webxr.session_supported.connect(_on_session_supported)
		_webxr.session_started.connect(_on_session_started)
		_webxr.session_ended.connect(_on_session_ended)
		_webxr.session_failed.connect(_on_session_failed)
		_webxr.is_session_supported("immersive-ar")


## Tracks the camera of the session the scene starts. prepareXR() has to run before
## that session is requested: it adds camera access to the request.
func _setup_follow_session() -> void:
	_webxr = XRServer.find_interface("WebXR") as WebXRInterface
	if _webxr == null or xr_origin == null:
		push_error("%s: follow_session needs WebXR and xr_origin." % name)
		return
	_tracking.setXRTrackedImage(_png_base64(_targets[0].printed_image()), _targets[0].width)
	_tracking.prepareXR()
	# The entry point reports when the session it started is running, whichever
	# side owns it: Godot's WebXR interface, or the page's own stereo path.
	if start_xr and start_xr.has_signal("xr_started"):
		start_xr.connect("xr_started", _on_session_started)
		if start_xr.has_signal("xr_ended"):
			start_xr.connect("xr_ended", _on_session_ended)
		return
	_webxr.session_started.connect(_on_session_started)
	_webxr.session_ended.connect(_on_session_ended)


func _setup_native() -> void:
	_native = true
	if start_button:
		start_button.visible = false
	if _targets.is_empty():
		_set_native_status("Add an ImageTarget node under %s." % name)
		return
	if xr_origin == null:
		_set_native_status("Set XR Origin, so marker poses have a tracking space.")
		return
	var openxr := XRServer.find_interface("OpenXR")
	if openxr == null:
		_set_native_status("Native marker tracking runs in an OpenXR headset.")
		return
	_request_spatial_permission()
	XRServer.tracker_added.connect(_on_native_tracker_added)
	XRServer.tracker_removed.connect(_on_native_tracker_removed)
	set_process(true)
	for tracker in XRServer.get_trackers(XRServer.TRACKER_ANCHOR).values():
		if tracker.get_class() == "OpenXRMarkerTracker":
			_add_native_tracker(tracker)
	if openxr.is_initialized():
		_check_native_capability()
	else:
		# The runtime only reports marker support once its session has begun.
		openxr.connect("session_begun", _check_native_capability, CONNECT_ONE_SHOT)
		_set_native_status("Start the XR session, then point at the marker.")


func _check_native_capability() -> void:
	if not _native_marker_supported():
		_set_native_status("This runtime does not support QR, ArUco or AprilTag markers.")
		return
	_set_native_status("Point at the marker.")


func _native_marker_supported() -> bool:
	var capability = Engine.get_singleton("OpenXRSpatialMarkerTrackingCapability")
	if capability == null:
		print("ImageTracking: no OpenXR marker tracking capability")
		return false
	var qr: bool = capability.is_qrcode_supported()
	var micro_qr: bool = capability.is_micro_qrcode_supported()
	var aruco: bool = capability.is_aruco_supported()
	var april_tag: bool = capability.is_april_tag_supported()
	print("ImageTracking: markers QR=%s MicroQR=%s ArUco=%s AprilTag=%s" % [qr, micro_qr, aruco, april_tag])
	return qr or micro_qr or aruco or april_tag


func _request_spatial_permission() -> void:
	if OS.get_name() != "Android":
		return
	var granted := OS.get_granted_permissions()
	for permission: String in SPATIAL_PERMISSIONS:
		if not granted.has(permission):
			OS.request_permission(permission)


func _on_native_tracker_added(tracker_name: StringName, type: int) -> void:
	if type != XRServer.TRACKER_ANCHOR:
		return
	var tracker := XRServer.get_tracker(tracker_name)
	if tracker.get_class() == "OpenXRMarkerTracker":
		_add_native_tracker(tracker)


func _add_native_tracker(tracker) -> void:
	if _native_anchors.has(tracker.name):
		return
	var target := _match_native_target(tracker)
	if target == null:
		print("ImageTracking: marker %s type=%s id=%s data=%s matches no ImageTarget" % [tracker.name,
			tracker.get_marker_type(), tracker.get_marker_id(), _marker_payload(tracker.get_marker_data())])
		_set_native_status("Found a marker, but no ImageTarget matches it.")
		return
	print("ImageTracking: marker %s type=%s id=%s data=%s -> %s" % [tracker.name,
		tracker.get_marker_type(), tracker.get_marker_id(),
		_marker_payload(tracker.get_marker_data()), target.name])
	var anchor := XRAnchor3D.new()
	anchor.name = "Marker_%s" % tracker.name
	anchor.tracker = tracker.name
	anchor.pose = &"default"
	anchor.show_when_tracked = true
	xr_origin.add_child(anchor)
	_native_anchors[tracker.name] = anchor
	_native_targets[tracker.name] = target
	_set_native_status("")


func _match_native_target(tracker) -> ImageTarget:
	var payload := _marker_payload(tracker.get_marker_data())
	var id: int = tracker.get_marker_id()
	for target in _targets:
		if not target.marker_payload.is_empty() and target.marker_payload == payload:
			return target
		if target.marker_id >= 0 and target.marker_id == id:
			return target
	# A single target with no marker fields is the simple one-marker setup.
	if _targets.size() == 1 and not _targets[0].has_native_marker():
		return _targets[0]
	return null


func _marker_payload(data: Variant) -> String:
	if data is String:
		return data
	if data is PackedByteArray:
		return data.get_string_from_utf8()
	return ""


func _on_native_tracker_removed(tracker_name: StringName, type: int) -> void:
	if type != XRServer.TRACKER_ANCHOR:
		return
	var anchor: XRAnchor3D = _native_anchors.get(tracker_name)
	var target: ImageTarget = _native_targets.get(tracker_name)
	if anchor:
		anchor.queue_free()
	_native_anchors.erase(tracker_name)
	_native_targets.erase(tracker_name)
	_native_placed.erase(tracker_name)
	if target and not persist_in_world:
		target.visible = false


func _process_native() -> void:
	for tracker_name in _native_anchors:
		var anchor: XRAnchor3D = _native_anchors[tracker_name]
		var target: ImageTarget = _native_targets.get(tracker_name)
		if target == null:
			continue
		if not anchor.get_has_tracking_data():
			if not persist_in_world:
				target.visible = false
			continue
		var tracker := XRServer.get_tracker(tracker_name)
		var scale := 1.0
		var marker_width := target.native_marker_width()
		if tracker and marker_width > 0.0:
			var size: Vector2 = tracker.get_bounds_size()
			if size.x > 0.0:
				scale = size.x / marker_width
		# The marker's pose, then back from the marker to the sheet's center.
		var pose := anchor.global_transform * Transform3D(IMAGE_TO_ANCHOR, Vector3.ZERO)
		pose.basis = pose.basis * Basis.from_scale(Vector3.ONE * scale)
		pose = pose * target.marker_transform().affine_inverse()
		target.global_transform = pose
		target.visible = true
		target_posed.emit(target)
		if not _native_placed.has(tracker_name):
			_native_placed[tracker_name] = true
			print("ImageTracking: %s at %s scale %.3f" % [tracker_name, pose.origin, scale])


func _set_native_status(text: String) -> void:
	_set_status(text)


func _set_status(text: String) -> void:
	if status_label:
		status_label.text = text


func _exit_tree() -> void:
	if not _native:
		return
	if XRServer.tracker_added.is_connected(_on_native_tracker_added):
		XRServer.tracker_added.disconnect(_on_native_tracker_added)
	if XRServer.tracker_removed.is_connected(_on_native_tracker_removed):
		XRServer.tracker_removed.disconnect(_on_native_tracker_removed)
	for anchor in _native_anchors.values():
		if is_instance_valid(anchor):
			anchor.queue_free()
	_native_anchors.clear()
	_native_targets.clear()
	_native_placed.clear()


func _on_start_pressed() -> void:
	start_button.visible = false
	if _world_tracking_offered:
		_tracking.prepareXR()
		_webxr.session_mode = "immersive-ar"
		# MindAR needs the camera images, which only camera-access gives.
		_webxr.required_features = "local, camera-access"
		_webxr.optional_features = ""
		_webxr.requested_reference_space_types = "local"
		if _webxr.initialize():
			_set_status("Starting world tracking...")
			return
	_start_tracking({})


func _start_tracking(extra: Dictionary) -> void:
	var targets := []
	var widths := []
	for target in _targets:
		var compiled := FileAccess.get_file_as_bytes(target.compiled_path())
		if compiled.is_empty():
			_set_status("%s isn't compiled: press Compile on it in the editor." % target.name)
			if start_button:
				start_button.visible = true
			return
		targets.append(Marshalls.raw_to_base64(compiled))
		widths.append(target.width)
	var options := {"maxTrack": _targets.size(), "targetWidths": widths}
	options.merge(extra, true)
	if not _in_xr:
		options["syntheticImage"] = _png_base64(_targets[0].printed_image())
	_tracking.start(JSON.stringify(targets), JSON.stringify(options))
	set_process(true)


func _png_base64(image: Image) -> String:
	return Marshalls.raw_to_base64(image.save_png_to_buffer())


func _on_session_supported(session_mode: String, supported: bool) -> void:
	if session_mode == "immersive-ar":
		_world_tracking_offered = supported


func _on_session_started() -> void:
	_in_xr = true
	# With follow_session the rig's XRToolsStartXR owns the viewport and its MSAA.
	if not follow_session:
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
	_start_tracking({"source": "xr", "referenceSpace": _webxr.reference_space_type, "holdTime": WORLD_HOLD_MS})


func _on_session_ended() -> void:
	_in_xr = false
	_tracking.stop()
	set_process(false)
	_last_frame = ""
	for target in _targets:
		target.visible = false
	if follow_session:
		return
	get_viewport().use_xr = false
	get_viewport().msaa_3d = _msaa_outside_xr
	camera.current = true
	start_button.visible = true
	if hud:
		hud.set_capture_in_xr(false)
		hud.set_capture_available(true)
		hud.refresh_layout.call_deferred()


func _on_session_failed(message: String) -> void:
	_set_status("No world tracking (%s)" % message)
	_start_tracking({})


## The review screen after a capture taken in AR closed: the session ended for it,
## so start one again, from the press that closed the review.
func _on_review_closed() -> void:
	_on_start_pressed()


func _process(_delta: float) -> void:
	if _native:
		_process_native()
		return
	var state := str(_tracking.state)
	if state != "running":
		_set_status("Image tracking: " + state)
		if state.begins_with("error"):
			if start_button:
				start_button.visible = true
			if hud and (state.contains("NotAllowedError") or state.to_lower().contains("permission")):
				hud.show_permission_error()
			set_process(false)
		return
	_set_status("")
	if not _in_xr:
		_update_fov()
	var json := str(_tracking.frameJson)
	if json == _last_frame or json.is_empty():
		return
	_last_frame = json
	if _dimensions.is_empty():
		_dimensions = JSON.parse_string(str(_tracking.dimensionsJson))
	var frame = JSON.parse_string(json)
	if not frame is Dictionary:
		return
	var poses: Array = frame["poses"]
	# With WebXR, poses are from where the camera was in the room for that frame.
	var room := Transform3D.IDENTITY
	if _in_xr and frame.get("camera") is Array:
		room = xr_origin.global_transform * _matrix_transform(frame["camera"])
	var scales: Array = frame.get("pixelsPerMeter", [])
	for i in _targets.size():
		var pose = poses[i] if i < poses.size() else null
		_targets[i].visible = pose != null
		if pose == null:
			continue
		var pixels_per_meter := float(scales[i]) if i < scales.size() and scales[i] != null else 0.0
		if _in_xr:
			_targets[i].global_transform = room * _target_transform(pose, i, pixels_per_meter)
			target_posed.emit(_targets[i])
		else:
			_targets[i].transform = _target_transform(pose, i, pixels_per_meter)
	# Shows the camera frame these poses came from, so they line up on screen.
	_tracking.present()


## The feed fills the screen like CSS object-fit: cover, so the visible part is the
## centered crop and the camera only needs a vertical field of view.
func _update_fov() -> void:
	var view := get_viewport().get_visible_rect().size
	var source := Vector2(float(_tracking.sourceWidth), float(_tracking.sourceHeight))
	var focal := float(_tracking.focal)
	if source.x <= 0.0 or focal <= 0.0:
		return
	var scale := maxf(view.x / source.x, view.y / source.y)
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = rad_to_deg(2.0 * atan(view.y * 0.5 / (focal * scale)))


## A column-major 4x4 matrix, as WebXR gives them.
func _matrix_transform(m: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])),
		Vector3(m[12], m[13], m[14]))


## MindAR poses are in target image pixels with the origin at the image's bottom
## left corner. Targets get the image's center, in meters. When world tracking has
## shown the image to be bigger or smaller than its width says, the target is
## scaled to match, so content made for that width still fits the image.
func _target_transform(m: Array, index: int, pixels_per_meter: float) -> Transform3D:
	var size: Array = _dimensions[index]
	var basis := Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10]))
	var center: Vector3 = basis * Vector3(size[0] * 0.5, size[1] * 0.5, 0.0) + Vector3(m[12], m[13], m[14])
	var width := _targets[index].width
	var meters_per_pixel := 1.0 / pixels_per_meter if pixels_per_meter > 0.0 else width / float(size[0])
	var scale := meters_per_pixel * float(size[0]) / width
	return Transform3D(basis.orthonormalized() * IMAGE_TO_ANCHOR * Basis.from_scale(Vector3.ONE * scale),
		center * meters_per_pixel)
