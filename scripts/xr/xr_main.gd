extends Node3D
## The headset version of the app (feature "xr"; also runs flat on desktop for
## testing). Passthrough shows your room; the whole app UI floats as a panel
## you poke with a fingertip or pinch with the laser; your instrument sits on a
## virtual table below it; remote players appear as avatars around you, with
## their instruments and their sound coming from where they are.
##
## Built in code so the layout lives in one place.

const PANEL_SIZE := Vector2(1.2, 0.675) # metres
const PANEL_PIXELS := Vector2(1600, 900)
# Placed relative to your head when XR starts (and on Recenter), so it fits
# seated or standing: the panel just below eye level, the table at hand height.
const PANEL_POS := Vector3(0, -0.12, -0.72)
const PANEL_TILT := -12.0 # degrees, top leans away
const TABLE_POS := Vector3(0, -0.58, -0.4)
const DEFAULT_HEAD := Vector3(0, 1.45, 0) # before tracking starts (and flat play)
const SEAT_RADIUS := 1.6

var player: XROrigin3D
var start_xr: Node
var panel: Node3D
var app: Control # the flat app (main.tscn) inside the panel
var table: Node3D
var workspace: Node3D # panel + table, moved as one by recenter()
var hand_player: HandPlayer
var _t_fps := 5.0
var _model: Node3D
var _avatars := {} # player id -> {seat, avatar, model}
var _shot := "" # dev: --xrshot=<path> saves a screenshot after a moment and quits
var _shot_t := 1.5


func _ready() -> void:
	Session.spatial = true
	_build_environment()
	start_xr = load("res://addons/godot-xr-tools/xr/start_xr.tscn").instantiate()
	add_child(start_xr)
	player = load("res://addons/shivoo_xr/player/player.tscn").instantiate()
	add_child(player)
	var pass_through: Node = load("res://addons/shivoo_xr/scripts/passthrough.gd").new()
	pass_through.name = "Passthrough"
	pass_through.set("start_xr", start_xr)
	add_child(pass_through)
	_build_floor()
	workspace = Node3D.new()
	workspace.name = "Workspace"
	workspace.position = DEFAULT_HEAD
	add_child(workspace)
	_build_panel()
	_build_table()
	_build_handles()
	start_xr.connect("xr_started", func(): get_tree().create_timer(0.6).timeout.connect(recenter))
	var openxr := XRServer.find_interface("OpenXR")
	if openxr and openxr.has_signal("pose_recentered"):
		openxr.connect("pose_recentered", recenter) # the headset's own recenter
	if app and app.has_method("add_top_button"):
		app.add_top_button("Recenter", "Move the panel and your instrument in front of you", recenter)
	_add_hand_tools.call_deferred()
	var wrist := WristButton.new()
	wrist.name = "WristReset"
	wrist.origin = player
	wrist.camera = player.get_node_or_null("Camera")
	wrist.pressed.connect(reset_position)
	add_child(wrist)
	Session.players_changed.connect(_sync_avatars)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--xrshot="):
			_shot = a.trim_prefix("--xrshot=")


func _build_environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.07, 0.075, 0.09)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.62, 0.68)
	e.ambient_light_energy = 0.5
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 0.9
	add_child(sun)


## Something to stand on (XR Tools' player body falls otherwise); invisible in passthrough.
func _build_floor() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.1, 20)
	shape.shape = box
	shape.position.y = -0.05
	body.add_child(shape)
	add_child(body)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(8, 8)
	floor.mesh = pm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.13, 0.135, 0.15)
	floor.material_override = m
	floor.add_to_group(&"hide_in_passthrough")
	add_child(floor)


func _build_panel() -> void:
	panel = load("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn").instantiate()
	panel.name = "AppPanel"
	panel.get_node("StaticBody3D").set_script(load("res://scripts/xr/panel_body.gd")) # mouse events only
	panel.position = PANEL_POS
	panel.rotation_degrees.x = PANEL_TILT
	workspace.add_child(panel) # in the tree first: its setters build the viewport
	panel.set("scene", load("res://scenes/main.tscn"))
	panel.set("viewport_size", PANEL_PIXELS)
	panel.set("screen_size", PANEL_SIZE)
	var vp := panel.find_child("Viewport", true, false) as SubViewport
	if vp == null:
		for c in panel.find_children("*", "SubViewport", true, false):
			vp = c
	if vp:
		vp.gui_embed_subwindows = true # dropdowns and dialogs open inside the panel
		vp.transparent_bg = false
		for c in vp.get_children():
			if c is Control:
				app = c


func _build_table() -> void:
	hand_player = HandPlayer.new()
	hand_player.name = "HandPlayer"
	hand_player.origin = player
	hand_player.rig = Session.local_rig
	add_child(hand_player)
	table = Node3D.new()
	table.name = "Table"
	table.position = TABLE_POS
	workspace.add_child(table)
	var top := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.9, 0.03, 0.45)
	top.mesh = bm
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.16, 0.16, 0.19, 0.6)
	tm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	top.material_override = tm
	top.position.y = -0.015
	table.add_child(top)
	if Session.local_rig:
		_show_instrument(Session.local_rig.instrument)
		Session.local_rig.instrument_changed.connect(_show_instrument)


## Grab bars: under the panel (moves the panel and instrument together) and
## at the front of the table (moves just the instrument).
func _build_handles() -> void:
	var cam := player.get_node_or_null("Camera") as Node3D
	var move_all := GrabHandle.new()
	move_all.name = "MoveHandle"
	move_all.target = workspace
	move_all.face = cam
	move_all.position = Vector3(0, -0.47, -0.67)
	workspace.add_child(move_all)
	var move_inst := GrabHandle.new()
	move_inst.name = "InstrumentHandle"
	move_inst.target = table
	move_inst.face = cam
	move_inst.length = 0.18
	move_inst.position = Vector3(0, -0.005, 0.26)
	table.add_child(move_inst)


func _show_instrument(type: String) -> void:
	if _model:
		_model.queue_free()
	_model = InstrumentModels.instantiate(type)
	if _model:
		table.add_child(_model)
	hand_player.setup(_model, type)


## Fingertip pokes on both hands (touch the panel) and a laser on each hand
## (point and pinch/trigger from a distance). Hands are created by the rig at
## runtime, so this runs deferred.
func _add_hand_tools() -> void:
	for side in ["LeftHand", "RightHand"]:
		var ctl := player.get_node_or_null(side) as XRController3D
		if ctl == null:
			continue
		# No teleporting: you play seated or standing in place.
		var teleport := ctl.get_node_or_null("FunctionTeleport")
		if teleport:
			teleport.set("enabled", false)
			teleport.queue_free()
		var pointer: Node3D = load("res://addons/godot-xr-tools/functions/function_pointer.tscn").instantiate()
		pointer.name = "FunctionPointer"
		pointer.set("show_laser", 2) # only while pointing at something
		ctl.add_child(pointer)
		var tip := _index_tip(ctl)
		var poke: Node3D = load("res://addons/godot-xr-tools/player/poke/poke.tscn").instantiate()
		poke.name = "Poke"
		if tip:
			tip.add_child(poke)
		else:
			poke.position = Vector3(0, -0.02, -0.11) # roughly where a fingertip is from the grip
			ctl.add_child(poke)


## A BoneAttachment3D on the hand model's index fingertip, or null.
func _index_tip(ctl: Node) -> Node3D:
	for sk in ctl.find_children("*", "Skeleton3D", true, false):
		var skel := sk as Skeleton3D
		for i in skel.get_bone_count():
			var n := skel.get_bone_name(i).to_lower()
			if "index" in n and ("tip" in n or "distal" in n):
				var att := BoneAttachment3D.new()
				att.bone_name = skel.get_bone_name(i)
				skel.add_child(att)
				return att
	return null


## The wrist button: the instrument back on its spot below the panel, and both
## in front of where you're looking.
func reset_position() -> void:
	table.transform = Transform3D(Basis.IDENTITY, TABLE_POS)
	recenter()


## Puts the panel and table in front of where you're looking, at your head height.
func recenter() -> void:
	var cam := player.get_node_or_null("Camera") as Node3D
	if cam == null:
		return
	var head := cam.global_transform
	var fwd := -head.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.1:
		fwd = Vector3.FORWARD
	workspace.global_transform = Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), head.origin)


func _process(delta: float) -> void:
	_t_fps -= delta
	if _t_fps <= 0.0:
		_t_fps = 5.0
		print("XR: %d fps, DSP %.1f%%" % [Engine.get_frames_per_second(), Session.local_rig.synth.get_cpu_load() * 100.0 if Session.local_rig else 0.0])
	if _shot != "":
		_shot_t -= delta
		if _shot_t <= 0.0:
			get_viewport().get_texture().get_image().save_png(_shot)
			print("screenshot: ", _shot)
			get_tree().quit()
	_send_pose()
	_place_remote_sound()


## Our head and hands, relative to our play space, for the others' avatars.
func _send_pose() -> void:
	var cam := player.get_node_or_null("Camera") as Node3D
	var l := player.get_node_or_null("LeftHand") as Node3D
	var r := player.get_node_or_null("RightHand") as Node3D
	if cam and l and r and Session.is_online():
		Session.set_local_pose(cam.transform, l.transform, r.transform)


# ---- Remote players

## Seats around you, facing you, in join order: across, then left and right.
static func seat_transform(index: int) -> Transform3D:
	var angles := [0.0, -50.0, 50.0, -100.0, 100.0]
	var a := deg_to_rad(angles[index % angles.size()])
	var pos := Vector3(sin(a) * SEAT_RADIUS, 0, -cos(a) * SEAT_RADIUS)
	# The seat's own -Z points at you (as a player faces their instrument).
	return Transform3D(Basis(Vector3.UP, a + PI), pos)


func _sync_avatars() -> void:
	var ids := Session.players.keys().filter(func(id): return Session.players[id].has("rig"))
	ids.sort()
	for id in _avatars.keys():
		if not id in ids:
			_avatars[id].seat.queue_free()
			_avatars.erase(id)
	for i in ids.size():
		var id: int = ids[i]
		if not _avatars.has(id):
			var seat := Node3D.new()
			seat.name = "Seat%d" % id
			add_child(seat)
			var av := RemoteAvatar.new()
			av.player_id = id
			seat.add_child(av)
			_avatars[id] = {"seat": seat, "avatar": av, "model": null, "type": ""}
		var a: Dictionary = _avatars[id]
		a.seat.transform = seat_transform(i)
		var type: String = Session.players[id].instrument
		if a.type != type:
			if a.model:
				a.model.queue_free()
			a.model = InstrumentModels.instantiate(type)
			if a.model:
				a.model.position = Vector3(0, 0.82, -0.45) # their table, in front of them
				a.seat.add_child(a.model)
			a.type = type


## Each remote player's instrument, audio loops and voice play from their table.
func _place_remote_sound() -> void:
	for id in _avatars:
		var p: Dictionary = Session.players.get(id, {})
		if not p.has("rig"):
			continue
		var at: Vector3 = (_avatars[id].seat as Node3D).to_global(Vector3(0, 1.0, -0.45))
		for node in [p.rig.player, p.rig.clip_player, p.get("voice")]:
			if node is Node3D:
				(node as Node3D).global_position = at
