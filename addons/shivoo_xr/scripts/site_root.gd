class_name SiteRoot
extends Node3D
## The parent of a site's shared anchors. Put it under the ImageTarget that is the
## site marker; the marker's frame is the site frame, so each child's transform is
## its pose in that frame and no world-space conversion is needed.
##
## Anchors are created from the network registry, not authored in the scene, so
## every device builds the same set in its own marker frame.

## Content instantiated for each anchor. Its origin is the anchor point.
@export var anchor_scene: PackedScene

var _anchors := {}


## Add or move the anchor [param id] to [param pose] in the site frame.
func add_anchor(id: StringName, pose: Transform3D) -> void:
	var anchor: SiteAnchor = _anchors.get(id)
	if anchor == null:
		anchor = SiteAnchor.new()
		anchor.name = String(id)
		anchor.anchor_id = id
		add_child(anchor)
		if anchor_scene:
			anchor.add_child(anchor_scene.instantiate())
		_anchors[id] = anchor
	anchor.transform = pose


## Remove the anchor [param id].
func remove_anchor(id: StringName) -> void:
	var anchor: SiteAnchor = _anchors.get(id)
	if anchor == null:
		return
	_anchors.erase(id)
	anchor.queue_free()


## Remove every anchor.
func clear() -> void:
	for anchor in _anchors.values():
		if is_instance_valid(anchor):
			anchor.queue_free()
	_anchors.clear()


## The anchors currently placed, keyed by id.
func anchors() -> Dictionary:
	return _anchors
