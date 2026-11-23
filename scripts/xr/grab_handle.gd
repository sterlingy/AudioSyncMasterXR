class_name GrabHandle
extends StaticBody3D
## A bar you grab with a fingertip (poke) or the laser (pinch / trigger) to
## move `target`: it follows your hand while held and turns to face you.
## Pointers and pokes from XR Tools report to it through `pointer_event`.

signal pointer_event(event)
signal moved

## The node to move (it keeps its offset from the hand at the moment of grabbing).
@export var target: Node3D
@export var length := 0.28
## Turn the target to face this node (the headset camera) while moving.
@export var face: Node3D

const UI_LAYER := 1 << 22 # "UI Objects": what XR Tools' pointers and pokes hit

var _mesh: MeshInstance3D
var _mat := StandardMaterial3D.new()
var _hover := 0
var _held_by: Node3D
var _laser_dist := 0.0
var _offset := Vector3.ZERO # target origin minus grab point, in world space


func _ready() -> void:
	collision_layer = UI_LAYER
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(length + 0.04, 0.05, 0.05) # a little bigger than it looks: easier to hit
	shape.shape = box
	add_child(shape)
	_mesh = MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.011
	cap.height = length
	_mesh.mesh = cap
	_mesh.rotation_degrees.z = 90
	_mat.albedo_color = Color(0.85, 0.87, 0.92, 0.55)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mesh.material_override = _mat
	add_child(_mesh)
	pointer_event.connect(_on_pointer_event)


func is_held() -> bool:
	return _held_by != null


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_hover += 1
		XRToolsPointerEvent.Type.EXITED:
			_hover = maxi(_hover - 1, 0)
		XRToolsPointerEvent.Type.PRESSED:
			if target and _held_by == null:
				_held_by = event.pointer
				_laser_dist = event.pointer.global_position.distance_to(event.position)
				_offset = target.global_position - _grab_point()
		XRToolsPointerEvent.Type.RELEASED:
			if event.pointer == _held_by:
				_held_by = null
	_update_look()


## Where the hand is "holding": the fingertip, or a point along the laser at
## the distance it first hit the handle.
func _grab_point() -> Vector3:
	if _held_by is XRToolsFunctionPointer:
		return _held_by.global_position - _held_by.global_basis.z * _laser_dist
	return _held_by.global_position


func _process(_delta: float) -> void:
	if _held_by == null or target == null:
		return
	if not is_instance_valid(_held_by):
		_held_by = null
		_update_look()
		return
	var pos := _grab_point() + _offset
	var basis := target.global_basis
	if face:
		var to_me := face.global_position - pos
		to_me.y = 0.0
		if to_me.length() > 0.2:
			basis = Basis.looking_at(-to_me.normalized(), Vector3.UP)
			# Keep the offset turning with the target, so it doesn't drift sideways.
	target.global_transform = Transform3D(basis, pos)
	moved.emit()


func _update_look() -> void:
	var a := 0.95 if _held_by else (0.8 if _hover > 0 else 0.55)
	_mat.albedo_color = Color(0.85, 0.87, 0.92, a)
	_mesh.scale = Vector3.ONE * (1.25 if _hover > 0 or _held_by else 1.0)
