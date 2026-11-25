extends Node3D
## The 3D instruments side by side, lit, for checking the models in the
## engine. Run: godot --path . res://scenes/instrument_gallery.tscn [-- --shot=path]

const ORDER := ["Pulsar", "Undertow", "Comet", "Lumen", "Prism", "Tangle", "Driftwood"]

var _shot := ""
var _frames := 20


func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.095, 0.11)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.62)
	e.ambient_light_energy = 0.25
	e.glow_enabled = true
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, 140, 0)
	fill.light_energy = 0.4
	add_child(fill)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(12, 8)
	floor.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.14, 0.145, 0.16)
	floor.material_override = fm
	add_child(floor)
	# Two rows of four, front row slightly lower in view.
	for i in ORDER.size():
		var m := InstrumentModels.instantiate(ORDER[i])
		if m == null:
			push_error("No model for " + ORDER[i])
			continue
		m.name = ORDER[i]
		m.position = Vector3((i % 4 - 1.5) * 1.0, 0, (i / 4) * 0.75 - 0.4)
		add_child(m)
	var cam := Camera3D.new()
	cam.fov = 38
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 2.2, 2.9), Vector3(0, 0.0, 0.0))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot = a.trim_prefix("--shot=")


func _process(_d: float) -> void:
	if _shot == "":
		return
	_frames -= 1
	if _frames <= 0:
		get_viewport().get_texture().get_image().save_png(_shot)
		print("screenshot: ", _shot)
		get_tree().quit()
