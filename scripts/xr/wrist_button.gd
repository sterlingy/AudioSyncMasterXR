class_name WristButton
extends Node3D
## A button on the inside of your wrist: it shows when you turn either wrist
## palm-up toward your face, and pressing it (fingertip of the other hand, or
## the laser) calls `pressed`. Placed under the XROrigin3D's parent (world).

signal pressed

const UI_LAYER := 1 << 22 # what XR Tools' pokes and pointers hit
const SIZE := Vector2(0.075, 0.03)
const FACING := 0.55 # cos of the angle between the palm's normal and the way to your eyes
const IN_VIEW := 0.6 # cos of the angle off your gaze the wrist may be

@export var text := "Reset position"
var origin: XROrigin3D
var camera: Node3D

var _body: StaticBody3D
var _bg: StandardMaterial3D
var _hover := 0
var _cooldown := 0.0
var _side := -1 # which wrist it's showing on


func _ready() -> void:
	visible = false
	_body = StaticBody3D.new()
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.add_user_signal("pointer_event", [{"name": "event", "type": TYPE_OBJECT}])
	_body.connect("pointer_event", _on_pointer_event)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SIZE.x, SIZE.y, 0.02)
	shape.shape = box
	_body.add_child(shape)
	add_child(_body)
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = SIZE
	quad.mesh = qm
	_bg = StandardMaterial3D.new()
	_bg.albedo_color = Color(0.1, 0.55, 0.5, 0.9)
	_bg.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bg.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material_override = _bg
	add_child(quad)
	var label := Label3D.new()
	label.text = text
	label.font_size = 36
	label.pixel_size = 0.0004
	label.position.z = 0.001
	label.modulate = Color.WHITE
	label.outline_size = 0
	add_child(label)


## True when a wrist (play-space transform, palm normal +Z) is turned toward
## the eyes and roughly in view.
static func palm_faces(wrist: Transform3D, head: Transform3D) -> bool:
	var to_eyes := head.origin - wrist.origin
	if to_eyes.length() < 0.05:
		return false
	to_eyes = to_eyes.normalized()
	var palm := wrist.basis.z.normalized()
	var gaze := -head.basis.z.normalized()
	return palm.dot(to_eyes) > FACING and gaze.dot(-to_eyes) > IN_VIEW


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	var shown := -1
	var at := Transform3D()
	if origin and camera:
		var head := origin.global_transform.affine_inverse() * camera.global_transform
		for side in [0, 1]:
			var tr := XRServer.get_tracker("/user/hand_tracker/left" if side == 0 else "/user/hand_tracker/right") as XRHandTracker
			if tr == null or not tr.has_tracking_data:
				continue
			var w := tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
			if palm_faces(w, head) and (shown < 0 or side == _side):
				shown = side
				# Just above the inside of the wrist, toward the elbow, facing the eyes.
				var p := w.origin + w.basis.z.normalized() * 0.025 - w.basis.y.normalized() * 0.02
				at = origin.global_transform * Transform3D(Basis.IDENTITY, p)
	_side = shown
	visible = shown >= 0
	_body.collision_layer = UI_LAYER if visible else 0
	if visible:
		var look := camera.global_position - at.origin
		global_transform = Transform3D(Basis.looking_at(-look.normalized(), Vector3.UP), at.origin)


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_hover += 1
		XRToolsPointerEvent.Type.EXITED:
			_hover = maxi(_hover - 1, 0)
		XRToolsPointerEvent.Type.PRESSED:
			if visible and _cooldown <= 0.0:
				_cooldown = 1.0
				pressed.emit()
	_bg.albedo_color = Color(0.15, 0.7, 0.64, 0.95) if _hover > 0 else Color(0.1, 0.55, 0.5, 0.9)
