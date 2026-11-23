extends Node
## Moves the player so the headset starts on the spawn point, facing the way the
## Player node faces. The play area is stage space, so otherwise the player starts
## offset by wherever they stand in the room, facing their real-world direction.

var _placed := false

@onready var _origin := get_parent() as XROrigin3D
@onready var _spawn := _origin.global_transform


func _ready() -> void:
	# Ahead of the player body, so it is already under the head when it moves.
	process_physics_priority = -110


func _physics_process(_delta: float) -> void:
	if _placed or not XRToolsStartXR.is_xr_active():
		return
	var head := XRServer.get_tracker(&"head") as XRPositionalTracker
	if head == null:
		return
	var pose := head.get_pose(&"default")
	if pose == null or not pose.has_tracking_data:
		return
	_placed = true
	_place_head_on_spawn(pose.get_adjusted_transform())


func _place_head_on_spawn(head: Transform3D) -> void:
	var forward := -head.basis.z
	var yaw := atan2(-forward.x, -forward.z) if Vector2(forward.x, forward.z).length() > 0.01 else 0.0
	var basis := _spawn.basis * Basis(Vector3.UP, -yaw)
	var offset := basis * Vector3(head.origin.x, 0.0, head.origin.z)
	_origin.global_transform = Transform3D(basis, _spawn.origin - offset)
	var body := XRToolsPlayerBody.find_instance(_origin)
	if body:
		body.global_transform = _spawn
