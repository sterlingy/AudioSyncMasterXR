class_name InstrumentModels
extends RefCounted
## The stylized 3D instruments (modeled in Blender, assets/instruments/*.glb),
## one per instrument type, for the XR stage and the avatars' instruments.

const DIR := "res://assets/instruments/"


static func path_for(instrument: String) -> String:
	return DIR + instrument + ".glb"


static func has_model(instrument: String) -> bool:
	return ResourceLoader.exists(path_for(instrument))


## A new instance of the instrument's model (null if there's none).
static func instantiate(instrument: String) -> Node3D:
	if not has_model(instrument):
		return null
	var scene: PackedScene = load(path_for(instrument))
	return scene.instantiate() if scene else null
