class_name XRButton
extends StaticBody3D
## A small 3D button you poke with a fingertip or click with the laser (pinch /
## trigger). XR Tools' pointers and pokes report to it through `pointer_event`,
## as they do to GrabHandle.

signal pointer_event(event)
signal pressed

const UI_LAYER := 1 << 22 # "UI Objects": what XR Tools' pointers and pokes hit

@export var text := "+"
@export var size := Vector2(0.045, 0.034) # metres

var _mat := StandardMaterial3D.new()
var _mesh: MeshInstance3D
var _hover := 0


func _ready() -> void:
	collision_layer = UI_LAYER
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, size.y, 0.03)
	shape.shape = box
	add_child(shape)
	_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, size.y, 0.008)
	_mesh.mesh = bm
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mesh.material_override = _mat
	add_child(_mesh)
	var label := Label3D.new()
	label.text = text
	label.pixel_size = 0.0007
	label.font_size = 40
	label.outline_size = 0
	label.modulate = Color(0.08, 0.09, 0.11)
	label.position.z = 0.0045
	add_child(label)
	pointer_event.connect(_on_pointer_event)
	_update_look()


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_hover += 1
		XRToolsPointerEvent.Type.EXITED:
			_hover = maxi(_hover - 1, 0)
		XRToolsPointerEvent.Type.PRESSED:
			pressed.emit()
	_update_look()


func _update_look() -> void:
	_mat.albedo_color = Color(0.85, 0.87, 0.92, 0.95 if _hover > 0 else 0.7)
	if _mesh:
		_mesh.scale = Vector3.ONE * (1.12 if _hover > 0 else 1.0)
