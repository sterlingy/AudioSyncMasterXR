class_name RemoteAvatar
extends Node3D
## Placeholder avatar for a remote player: a head and two hands in their
## instrument's color, posed from Session.remote_pose() (already delayed to
## when their sound reaches you). Real avatar art comes later (M6).

@export var player_id := 0

var head: MeshInstance3D
var left: MeshInstance3D
var right: MeshInstance3D


func _ready() -> void:
	var p: Dictionary = Session.players.get(player_id, {})
	var color: Color = InstrumentRig.COLORS.get(p.get("instrument", ""), Color(0.8, 0.8, 0.85))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	var sphere := SphereMesh.new()
	sphere.radius = 0.11
	sphere.height = 0.24
	head = _part(sphere, mat)
	var box := BoxMesh.new()
	box.size = Vector3(0.08, 0.03, 0.12)
	left = _part(box, mat)
	right = _part(box, mat)
	visible = false


func _part(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	add_child(m)
	return m


func _process(_delta: float) -> void:
	var pose := Session.remote_pose(player_id)
	visible = not pose.is_empty()
	if pose.is_empty():
		return
	head.transform = pose.head
	left.transform = pose.left
	right.transform = pose.right
