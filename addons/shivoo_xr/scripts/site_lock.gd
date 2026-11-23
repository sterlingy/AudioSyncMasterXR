class_name SiteLock
extends Node3D
## Shared-space mode for co-located demos. Place this node on the scene floor
## where the site marker should be, under the content that sits on it, with its
## forward (-Z) the way that content faces.
##
## While an XR session runs, locomotion is off, and whenever the marker is tracked
## the XR origin is moved so the marker lands on this node, with the marker's top
## to bottom edge pointing along this node's forward. Every device that sees the
## same printed marker then shares one world frame: anything synced in world space
## (networked blocks, avatars) lines up in the room with no per-object conversion,
## whatever runtime the device uses.
##
## Only the horizontal position and the heading come from the marker. Height stays
## the headset's own floor, and the origin only turns about the vertical, so the
## world stays level and on the real floor. A marker on a wall has no level top to
## bottom edge; its face normal is the forward instead.

## Emitted the first time the marker places the origin in a session.
signal locked

## Lock locomotion and align to the marker during XR sessions.
@export var enabled := true
@export var start_xr: XRToolsStartXR
@export var image_tracking: ImageTracking
## The target, under image_tracking, that is the site marker.
@export var marker: ImageTarget
@export var origin: XROrigin3D
## Keep correcting drift while the marker stays in view. Off locks once per session.
@export var continuous := true
## Corrections smaller than these are skipped, so tracking noise does not shake the
## world.
@export_range(0.0, 0.2, 0.001, "suffix:m") var position_tolerance := 0.02
@export_range(0.0, 10.0, 0.1, "suffix:°") var angle_tolerance := 1.0

## True once the marker has placed the origin in the current session.
var is_locked := false

var _active := false
## Locomotion nodes switched off by this node, with their previous enabled state.
var _restore := {}


func _ready() -> void:
	if not enabled or start_xr == null or image_tracking == null or marker == null or origin == null:
		return
	image_tracking.target_posed.connect(_on_target_posed)
	start_xr.xr_started.connect(_on_xr_started)
	start_xr.xr_ended.connect(_on_xr_ended)
	# A scene can start XR before this node is ready (XRToolsStartXR auto-start).
	if XRToolsStartXR.is_xr_active():
		_on_xr_started.call_deferred()


func _on_xr_started() -> void:
	if _active:
		return
	_active = true
	is_locked = false
	_set_locomotion_locked(true)
	print("SiteLock: locomotion off, waiting for marker %s" % marker.name)


func _on_xr_ended() -> void:
	_active = false
	is_locked = false
	_set_locomotion_locked(false)


## The player body drives every XR Tools movement provider (stick move, snap turn,
## flat play); teleport moves the origin through it directly.
func _set_locomotion_locked(lock: bool) -> void:
	if lock:
		for node in origin.find_children("*", "", true, false):
			if node is XRToolsPlayerBody or node is XRToolsFunctionTeleport:
				_restore[node] = node.enabled
				node.enabled = false
		return
	for node in _restore:
		if is_instance_valid(node):
			node.enabled = _restore[node]
	_restore.clear()


func _on_target_posed(target: ImageTarget) -> void:
	if not _active or target != marker or (is_locked and not continuous):
		return
	var tracked := Transform3D(marker.global_basis.orthonormalized(), marker.global_position)
	var marker_forward := _level(tracked.basis.z)
	if marker_forward.length() < 0.2:
		marker_forward = _level(tracked.basis.y)
		if marker_forward.length() < 0.2:
			return
	var site_forward := _level(-global_basis.z)
	var yaw := marker_forward.signed_angle_to(site_forward, Vector3.UP)
	if is_locked and _level(tracked.origin).distance_to(_level(global_position)) < position_tolerance \
			and absf(rad_to_deg(yaw)) < angle_tolerance:
		return
	var turn := Basis(Vector3.UP, yaw)
	# Turning about the vertical keeps every height, and the shift is level, so
	# the headset's floor stays the world's floor.
	var correction := Transform3D(turn, _level(global_position - turn * tracked.origin))
	origin.global_transform = correction * origin.global_transform
	# The marker is not under the origin; move it with the room this frame too.
	marker.global_transform = correction * marker.global_transform
	if not is_locked:
		is_locked = true
		print("SiteLock: locked to %s" % marker.name)
		locked.emit()


static func _level(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
