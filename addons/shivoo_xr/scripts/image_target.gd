@tool
class_name ImageTarget
extends Node3D
## An image (web) or native OpenXR marker (QR/Aruco/AprilTag) that the ImageTracking
## node above it finds and follows. Put the content that goes on the image under
## this node: it is centered on the image, in meters, with +Y out of the image and
## -Z towards its top edge. The editor shows the image here at its printed size.
##
## Choosing an image compiles it in the background into the <image>.mind file next
## to it, which is what the tracker loads; Compile does it again. Compiling runs
## MindAR's compiler (the addon's tools/mindar) with Node.js, which only the editor
## needs.
##
## On OpenXR devices the same target can follow a native marker instead: set
## marker_payload to a QR code's text, or marker_id to an ArUco/AprilTag ID. The
## runtime tracks the marker and ImageTracking places this node on it.
##
## One printed sheet can serve both: natural-feature artwork for MindAR with the QR
## inside it. marker_width and marker_offset say where the QR is on the sheet, so
## both trackers put this node at the sheet's center. Generate Sheet draws such a
## sheet from sheet_artwork and marker_payload and uses it as the image, so the QR,
## its position and the compiled target always agree.

const COMPILER := ShivooXRPaths.ADDON_DIR + "/tools/mindar/compile/compile.js"
const COMPILER_PACKAGE := ShivooXRPaths.ADDON_DIR + "/tools/mindar"
## Fewer tracking features than this at either of the tracker's two scales, and the
## image is found slowly and lost easily.
const GOOD_TRACKING_FEATURES := 20
const POOR_TRACKING_FEATURES := 10

## The image as it is printed, or shown on a screen.
@export var image: Texture2D:
	set(value):
		image = value
		_update_preview()
		_compile_soon()
## Printed width in meters. With world tracking it is only a first guess, which
## ImageTracking corrects once the phone has moved around with the image in view.
@export_range(0.01, 10.0, 0.001, "or_greater", "suffix:m") var width := 0.2:
	set(value):
		width = value
		_update_preview()
## What the image's transparent parts are, as printed.
@export var background := Color.WHITE:
	set(value):
		background = value
		_compile_soon()
## Native OpenXR marker to follow this target: the payload text of a QR code.
## Leave empty to match by marker_id, or leave both unset to match any marker
## when this is the only ImageTarget.
@export var marker_payload := ""
## Native OpenXR marker ID for an ArUco or AprilTag marker, or -1 to match by
## marker_payload.
@export var marker_id := -1
## Printed width of the native marker's code itself (no quiet zone), in meters.
## 0 means the marker is the whole target, as wide as width.
@export_range(0.0, 10.0, 0.001, "or_greater", "suffix:m") var marker_width := 0.0
## Where the marker's center is on the target, in meters from the target's center:
## +X to the right, +Y towards the top edge.
@export var marker_offset := Vector2.ZERO
@export_group("Sheet")
## Artwork for Generate Sheet: detailed, high-contrast, varied, so MindAR has
## plenty to track. It is stretched to the sheet's aspect, and the QR is drawn
## over it at marker_offset, marker_width wide, in a white quiet zone.
@export var sheet_artwork: Texture2D
## Sheet height over width, for Generate Sheet.
@export_range(0.1, 10.0, 0.001) var sheet_aspect := 1.0
## Sheet resolution for Generate Sheet, in pixels across.
@export_range(256, 8192, 1) var sheet_pixels := 2048
@export_tool_button("Generate Sheet", "ImageTexture") var generate_sheet_button := generate_sheet
@export_group("")
## Show a see-through copy of the image on it while running, for checking that
## content lines up with it. The editor always shows it.
@export var show_image := false:
	set(value):
		show_image = value
		_update_preview()
@export_tool_button("Compile", "Reload") var compile_button := compile
## What the last compile found: the features the tracker finds and follows the
## image by, at each of the scales it looks at.
@export var compiled: String:
	get:
		return _describe()

## The image file and background the .mind file was compiled from.
@export_storage var _compiled_from := ""
@export_storage var _features := {}

var _preview: MeshInstance3D
var _thread: Thread
var _pid := 0
var _pixels_path := ""
var _busy := ""
var _error := ""
var _compile_queued := false
var _changes := 0


func _ready() -> void:
	_update_preview()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _thread:
		if _pid:
			OS.kill(_pid)
		_thread.wait_to_finish()


func _validate_property(property: Dictionary) -> void:
	if property.name == "compiled":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY


## Where the compiled target is: next to the image, as <image>.mind.
func compiled_path() -> String:
	return image.resource_path.get_basename() + ".mind" if image else ""


## Whether this target is configured to follow a native OpenXR marker.
func has_native_marker() -> bool:
	return not marker_payload.is_empty() or marker_id >= 0


## Width of the native marker's code, in meters.
func native_marker_width() -> float:
	return marker_width if marker_width > 0.0 else width


## The native marker's center and axes on this target, in its local space.
func marker_transform() -> Transform3D:
	return Transform3D(Basis(), Vector3(marker_offset.x, 0.0, -marker_offset.y))


## The sheet Generate Sheet prints: [param artwork] stretched to
## [param pixels] x [param pixels] * [param aspect], with the QR for
## [param payload] [param code_fraction] of the sheet's width across, centered at
## [param offset_fraction] (of the width, +Y up) from the middle, in a white quiet
## zone. Returns null if the QR does not fit at a whole number of pixels a module.
static func build_sheet(artwork: Image, payload: String, pixels: int, aspect: float,
		code_fraction: float, offset_fraction: Vector2) -> Image:
	var qr := ShivooQR.encode(payload)
	if qr == null:
		return null
	var module := floori(pixels * code_fraction / qr.size)
	if module < 2:
		return null
	var height := roundi(pixels * aspect)
	var sheet := artwork.duplicate() as Image
	if sheet.is_compressed():
		sheet.decompress()
	sheet.convert(Image.FORMAT_RGBA8)
	sheet.resize(pixels, height, Image.INTERPOLATE_LANCZOS)
	var code := qr.to_image(module)
	var center := Vector2(pixels * 0.5 + offset_fraction.x * pixels, height * 0.5 - offset_fraction.y * pixels)
	var corner := Vector2i(roundi(center.x - code.get_width() * 0.5), roundi(center.y - code.get_height() * 0.5))
	sheet.blit_rect(code, Rect2i(Vector2i.ZERO, code.get_size()), corner)
	return sheet


## Draws the sheet into <sheet_artwork>_<marker_payload>.png, makes it this
## target's image and compiles it. marker_width is set to the code width the whole
## pixels per module allow, so it matches the print exactly.
func generate_sheet() -> void:
	if sheet_artwork == null or marker_payload.is_empty() or marker_width <= 0.0:
		push_error("%s: Generate Sheet needs sheet_artwork, marker_payload and marker_width." % name)
		return
	var qr := ShivooQR.encode(marker_payload)
	var module := floori(sheet_pixels * marker_width / width / qr.size)
	# The source file, not the imported texture, which may be compressed.
	var sheet := build_sheet(Image.load_from_file(sheet_artwork.resource_path), marker_payload, sheet_pixels,
		sheet_aspect, marker_width / width, marker_offset / width)
	if sheet == null:
		push_error("%s: the QR does not fit; raise sheet_pixels or marker_width." % name)
		return
	var path := "%s_%s.png" % [sheet_artwork.resource_path.get_basename(), marker_payload.validate_filename()]
	var error := sheet.save_png(path)
	if error != OK:
		push_error("%s: couldn't write %s (%s)." % [name, path, error_string(error)])
		return
	marker_width = width * float(module * qr.size) / sheet_pixels
	if Engine.is_editor_hint():
		var filesystem = Engine.get_singleton("EditorInterface").get_resource_filesystem()
		filesystem.update_file(path)
		filesystem.reimport_files(PackedStringArray([path]))
	image = load(path)


## The image as printed, with its transparent parts filled with the background.
func printed_image() -> Image:
	return _printed(image.get_image())


func compile() -> void:
	_compile_queued = false
	if _thread:
		_compile_queued = true
		return
	# A native-only target has no image to compile; its marker data comes from
	# the runtime.
	if image == null:
		return
	_error = _image_problem()
	if _error.is_empty():
		_error = _read_only_problem()
	if not _error.is_empty():
		update_configuration_warnings()
		return
	var printed := _printed(Image.load_from_file(image.resource_path))
	_pixels_path = ProjectSettings.globalize_path("user://image_target_%d.rgba" % get_instance_id())
	var file := FileAccess.open(_pixels_path, FileAccess.WRITE)
	file.store_buffer(printed.get_data())
	file.close()
	var arguments := PackedStringArray([ProjectSettings.globalize_path(COMPILER), _pixels_path,
		str(printed.get_width()), str(printed.get_height()), ProjectSettings.globalize_path(compiled_path())])
	var install := not DirAccess.dir_exists_absolute(COMPILER_PACKAGE.path_join("node_modules"))
	_busy = "Compiling..."
	_thread = Thread.new()
	_thread.start(_run_compiler.bind(arguments, install, _source_hash()))
	update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	if image == null:
		return [] if has_native_marker() else ["Choose the image to track."]
	var problem := _image_problem()
	if not problem.is_empty():
		return [problem]
	if _thread:
		return []
	if not _error.is_empty():
		return ["Compiling failed: " + _error]
	if not FileAccess.file_exists(compiled_path()):
		return ["Not compiled yet: press Compile."]
	if _compiled_from != _source_hash():
		return [" ".join(PackedStringArray(["The image or background has changed since it was compiled, or it was "
			+ "compiled elsewhere: press Compile.", _read_only_problem()])).strip_edges()]
	if _fewest_tracking_features() < GOOD_TRACKING_FEATURES:
		return [("Little detail to track by (as few as %d tracking features, where %d or more is good), so it will be "
			+ "found slowly and lost easily. Fine, varied, high-contrast detail tracks best; flat colours, symmetry "
			+ "and repeating patterns don't.") % [_fewest_tracking_features(), GOOD_TRACKING_FEATURES]]
	return []


func _image_problem() -> String:
	if not image:
		return "" if has_native_marker() else "Choose the image to track."
	if image.resource_path.is_empty() or image.resource_path.contains("::"):
		return "The image needs to be a file in the project."
	return ""


func _read_only_problem() -> String:
	var path := compiled_path()
	if FileAccess.file_exists(path) and FileAccess.get_read_only_attribute(path):
		return ("%s is read-only: Git LFS keeps lockable files that way until you lock them. Lock it "
			+ "(git lfs lock %s), then compile again.") % [path, path.trim_prefix("res://")]
	return ""


## Compiles once changes settle, so that dragging the background colour around
## doesn't compile for every step.
func _compile_soon() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree() or not image:
		return
	_changes += 1
	var change := _changes
	await get_tree().create_timer(0.5).timeout
	if change == _changes:
		compile()


func _run_compiler(arguments: PackedStringArray, install: bool, source: String) -> void:
	if install:
		_set_busy.call_deferred("Installing the compiler's packages...")
		var package := ProjectSettings.globalize_path(COMPILER_PACKAGE)
		var output := []
		var code := OS.execute("cmd.exe", ["/c", "npm", "ci", "--prefix", package], output, true) \
			if OS.get_name() == "Windows" else OS.execute("npm", ["ci", "--prefix", package], output, true)
		if code != 0:
			_finished.call_deferred("Couldn't install the compiler's packages (npm ci in tools/mindar):\n"
				+ "".join(output).strip_edges(), {}, "")
			return
		_set_busy.call_deferred("Compiling...")
	var process := OS.execute_with_pipe("node", arguments)
	if process.is_empty():
		_finished.call_deferred("Couldn't run Node.js. Install it from nodejs.org, then restart Godot.", {}, "")
		return
	_pid = process.pid
	var stdio: FileAccess = process.stdio
	var result = null
	var error := "The compiler stopped without a result."
	while stdio.is_open() and stdio.get_error() == OK:
		var line := stdio.get_line()
		if line.begins_with("progress "):
			_set_busy.call_deferred("Compiling... %s%%" % line.trim_prefix("progress "))
		elif line.begins_with("result "):
			result = JSON.parse_string(line.trim_prefix("result "))
		elif line.begins_with("error "):
			error = line.trim_prefix("error ")
	_pid = 0
	if result is Dictionary:
		_finished.call_deferred("", result, source)
	else:
		_finished.call_deferred(error, {}, "")


func _set_busy(text: String) -> void:
	_busy = text


func _finished(error: String, result: Dictionary, source: String) -> void:
	_thread.wait_to_finish()
	_thread = null
	_busy = ""
	DirAccess.remove_absolute(_pixels_path)
	_error = error
	if error.is_empty():
		_features = {}
		for key in ["detection", "tracking"]:
			_features[key] = result.get(key, []).map(func(count): return int(count))
		_compiled_from = source
		print("Compiled %s. %s" % [compiled_path(), _describe()])
		if Engine.is_editor_hint():
			Engine.get_singleton("EditorInterface").mark_scene_as_unsaved()
	else:
		push_error("%s: %s" % [name, error])
	update_configuration_warnings()
	if _compile_queued:
		compile()


func _source_hash() -> String:
	if image == null:
		return ""
	return FileAccess.get_md5(image.resource_path) + background.to_html(false)


func _fewest_tracking_features() -> int:
	var tracking: Array = _features.get("tracking", [])
	return tracking.min() if not tracking.is_empty() else 0


func _describe() -> String:
	if not _busy.is_empty():
		return _busy
	if not _error.is_empty():
		return "Failed: " + _error
	var detection: Array = _features.get("detection", [])
	var tracking: Array = _features.get("tracking", [])
	if detection.is_empty() or tracking.is_empty():
		return "Not compiled"
	var fewest := _fewest_tracking_features()
	var rating := "Good" if fewest >= GOOD_TRACKING_FEATURES else "Weak" if fewest >= POOR_TRACKING_FEATURES else "Poor"
	return "%s: %d to %d features to detect it by, per scale; %s to track it by" % [rating, detection.min(),
		detection.max(), " and ".join(PackedStringArray(tracking.map(func(count): return str(count))))]


func _printed(source: Image) -> Image:
	if source.is_compressed():
		source.decompress()
	source.convert(Image.FORMAT_RGBA8)
	var printed := Image.create_empty(source.get_width(), source.get_height(), false, Image.FORMAT_RGBA8)
	printed.fill(Color(background, 1.0))
	printed.blend_rect(source, Rect2i(Vector2i.ZERO, source.get_size()), Vector2i.ZERO)
	return printed


func _update_preview() -> void:
	if not _preview:
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(1.0, 1.0, 1.0, 0.6)
		var plane := PlaneMesh.new()
		plane.material = material
		_preview = MeshInstance3D.new()
		_preview.mesh = plane
		add_child(_preview, false, INTERNAL_MODE_FRONT)
	var aspect := float(image.get_height()) / float(image.get_width()) if image else 1.0
	(_preview.mesh as PlaneMesh).size = Vector2(width, width * aspect)
	((_preview.mesh as PlaneMesh).material as StandardMaterial3D).albedo_texture = image
	_preview.visible = image != null and (show_image or Engine.is_editor_hint())
