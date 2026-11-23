extends Node
## Poses the XR Tools hands from tracked finger joints whenever a hand tracker is
## active (OpenXR hand tracking on desktop, WebXR hand input in the browser), and
## leaves them to the grip/trigger animations otherwise. Place under the XROrigin3D.


func _ready() -> void:
	var origin := get_parent() as XROrigin3D
	if origin:
		HandSkeleton.attach_to_hands(origin)
