extends SceneTree
## Renders Undertow and Comet with their knob labels from a seated viewpoint: godot --path . -s res://tests/tools/knob_labels_shot.gd -- out.png
func _initialize() -> void:
	root.add_child.call_deferred(load("res://tests/tools/knob_labels_body.gd").new())
