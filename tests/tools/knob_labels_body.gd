extends Node
func _ready() -> void:
	_run.call_deferred()
func _run() -> void:
	var w := Node3D.new()
	add_child(w)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.25, 0.25, 0.27)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	env.environment = e
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, -20, 0)
	w.add_child(sun)
	var x := -0.25
	for t in ["Undertow", "Comet"]:
		var rig := InstrumentRig.new()
		rig.instrument = t
		rig.local_input = false
		w.add_child(rig)
		var m := InstrumentModels.instantiate(t)
		m.position = Vector3(x, 0, 0)
		w.add_child(m)
		var hp := HandPlayer.new()
		hp.rig = rig
		w.add_child(hp)
		hp.setup(m, t)
		x += 0.5
	var cam := Camera3D.new()
	cam.fov = 45
	w.add_child(cam)
	cam.look_at_from_position(Vector3(0, 0.38, 0.42), Vector3(0, 0.03, -0.02))
	for i in 10:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[0])
	get_tree().quit()
