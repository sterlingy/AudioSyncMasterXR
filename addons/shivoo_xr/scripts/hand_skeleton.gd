class_name HandSkeleton
extends SkeletonModifier3D
## Poses an XR Tools hand from the XRHandTracker for its side while that hand is
## tracked, and leaves it to the grip/trigger animation otherwise. The tracker comes
## from OpenXR on desktop and from scripts/webxr_stereo.gd in the browser.
##
## Godot's XRHandModifier3D only reads humanoid rigs (LeftIndexDistal). XR Tools
## hands use OpenXR joint names (Index_Distal_L) with their own bone axes, so each
## tracked joint is turned into the model's bone axes first.
##
## The wrist is placed in world space every frame. XR Tools moves the hand node in
## the physics step, so following the tracker here keeps the hand smooth.

const JOINT_BONES: PackedStringArray = [
	"Palm", "Wrist",
	"Thumb_Metacarpal", "Thumb_Proximal", "Thumb_Distal", "Thumb_Tip",
	"Index_Metacarpal", "Index_Proximal", "Index_Intermediate", "Index_Distal", "Index_Tip",
	"Middle_Metacarpal", "Middle_Proximal", "Middle_Intermediate", "Middle_Distal", "Middle_Tip",
	"Ring_Metacarpal", "Ring_Proximal", "Ring_Intermediate", "Ring_Distal", "Ring_Tip",
	"Little_Metacarpal", "Little_Proximal", "Little_Intermediate", "Little_Distal", "Little_Tip",
]
## Tracker joints use Godot's humanoid axes: +Y toward the fingertip, -Z out of the
## back of the hand. XR Tools finger bones also run along +Y, but the back of the
## hand is -X on the left model and +X on the right. These map one to the other.
const LEFT_FINGER_AXES := Basis(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 1.0, 0.0), Vector3(-1.0, 0.0, 0.0))
const RIGHT_FINGER_AXES := Basis(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0), Vector3(1.0, 0.0, 0.0))
## Chrome hides the player's hand size. When the headset runtime can't rescale the
## hand itself (SteamVR can't), Chrome keeps each bone's direction but sets its
## length from a fixed Quest hand. On SteamVR's joint layout that splays the palm,
## so those frames keep the model's lengths. Metacarpal joint to knuckle, in meters:
const CHROME_STANDARD_METACARPALS := {
	XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL: 0.0597,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL: 0.0616,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL: 0.0457,
}

@export_enum("Left", "Right") var hand := 0:
	set(value):
		hand = value
		_map_bones()

## Moves finger bones to the tracked joint positions, so the model takes the
## player's finger lengths. Off keeps the model's proportions and only rotates.
@export var update_bone_positions := true

var _bones := PackedInt32Array()
var _parents := PackedInt32Array()
var _axes: Array[Basis] = []
var _origin: XROrigin3D


## Adds a HandSkeleton to every OpenXR-rig hand under the controllers of an origin.
static func attach_to_hands(xr_origin: XROrigin3D) -> void:
	for controller: XRController3D in xr_origin.find_children("*", "XRController3D", false, false):
		var side := 0 if controller.tracker == &"left_hand" else 1
		for skeleton: Skeleton3D in controller.find_children("*", "Skeleton3D", true, false):
			if skeleton.find_bone("Wrist_L" if side == 0 else "Wrist_R") == -1:
				continue
			if skeleton.get_children().any(func(child: Node) -> bool: return child is HandSkeleton):
				continue
			var modifier := HandSkeleton.new()
			modifier.name = "HandSkeleton"
			modifier.hand = side
			skeleton.add_child(modifier)


func _ready() -> void:
	_map_bones()


func _skeleton_changed(_old: Skeleton3D, _new: Skeleton3D) -> void:
	_map_bones()


func _map_bones() -> void:
	_bones.resize(XRHandTracker.HAND_JOINT_MAX)
	_bones.fill(-1)
	_parents.resize(XRHandTracker.HAND_JOINT_MAX)
	_parents.fill(-1)
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	var suffix := "_L" if hand == 0 else "_R"
	for joint in XRHandTracker.HAND_JOINT_MAX:
		_bones[joint] = skeleton.find_bone(JOINT_BONES[joint] + suffix)
	for joint in XRHandTracker.HAND_JOINT_MAX:
		if _bones[joint] == -1:
			continue
		var parent_bone := skeleton.get_bone_parent(_bones[joint])
		if parent_bone != -1:
			_parents[joint] = _bones.find(parent_bone)

	# The wrist and palm bones point elsewhere. Tracked wrist and palm joints are
	# aligned with the middle metacarpal (Godot's WebXR palm copies it), so their
	# bone axes are measured against that bone in the model's rest pose.
	var finger_axes := LEFT_FINGER_AXES if hand == 0 else RIGHT_FINGER_AXES
	_axes.resize(XRHandTracker.HAND_JOINT_MAX)
	_axes.fill(finger_axes)
	var metacarpal := _bones[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL]
	if metacarpal != -1:
		var hand_rest := skeleton.get_bone_global_rest(metacarpal).basis.orthonormalized() * finger_axes.inverse()
		for joint in [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_WRIST]:
			if _bones[joint] != -1:
				_axes[joint] = hand_rest.inverse() * skeleton.get_bone_global_rest(_bones[joint]).basis.orthonormalized()


func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null or _bones.is_empty() or _axes.is_empty():
		return
	var tracker := XRServer.get_tracker("/user/hand_tracker/left" if hand == 0 else "/user/hand_tracker/right") as XRHandTracker
	if tracker == null or not tracker.has_tracking_data:
		return
	if not is_instance_valid(_origin):
		_origin = _find_origin()
		if _origin == null:
			return

	var joints: Array[Transform3D] = []
	joints.resize(XRHandTracker.HAND_JOINT_MAX)
	var valid := PackedByteArray()
	valid.resize(XRHandTracker.HAND_JOINT_MAX)
	for joint in XRHandTracker.HAND_JOINT_MAX:
		var flags := tracker.get_hand_joint_flags(joint)
		if flags & XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID and flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID:
			var transform := tracker.get_hand_joint_transform(joint)
			transform.basis = transform.basis * _axes[joint]
			joints[joint] = transform
			valid[joint] = 1

	# Tracking space to skeleton space, including world scale and the hand's offsets.
	var world_scale := XRServer.world_scale
	var to_skeleton := skeleton.global_transform.affine_inverse() * _origin.global_transform
	var skeleton_rotation := to_skeleton.basis.orthonormalized()
	var length_scale := world_scale * skeleton.motion_scale / skeleton.global_basis.get_scale().x
	var move_bones := update_bone_positions and not _has_chrome_standard_lengths(tracker)

	for joint in XRHandTracker.HAND_JOINT_MAX:
		var bone := _bones[joint]
		if bone == -1 or not valid[joint]:
			continue
		var parent := _parents[joint]
		if parent == -1:
			var tracked := joints[joint]
			skeleton.set_bone_pose_position(bone, to_skeleton * (tracked.origin * world_scale))
			skeleton.set_bone_pose_rotation(bone, Quaternion((skeleton_rotation * tracked.basis).orthonormalized()))
		elif valid[parent]:
			var relative := joints[parent].affine_inverse() * joints[joint]
			if move_bones:
				skeleton.set_bone_pose_position(bone, relative.origin * length_scale)
			skeleton.set_bone_pose_rotation(bone, Quaternion(relative.basis.orthonormalized()))


func _has_chrome_standard_lengths(tracker: XRHandTracker) -> bool:
	if not OS.has_feature("web"):
		return false
	for metacarpal: int in CHROME_STANDARD_METACARPALS:
		var length := tracker.get_hand_joint_transform(metacarpal).origin.distance_to(
				tracker.get_hand_joint_transform(metacarpal + 1).origin)
		if absf(length - CHROME_STANDARD_METACARPALS[metacarpal]) > 0.0002:
			return false
	return true


func _find_origin() -> XROrigin3D:
	var node := get_parent()
	while node:
		if node is XROrigin3D:
			return node
		node = node.get_parent()
	return null
