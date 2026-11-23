class_name SurfacePlacement
extends Node3D
## Content the place button puts on real surfaces, under a SurfaceTracking node:
## dragging translates it along the surface from where it is, two fingers on the
## surface turn it and moving them together or apart sizes it, and three fingers
## dragged left or right turn the key light. Taps move nothing. Put the content under this node, standing on its origin with +Y up;
## its -Z side turns to face the phone when it is put down. Until it is placed it
## shows see-through wherever it would be put, so the place button only sets the
## position the preview already shows, and its animations hold at their first pose
## until it is placed. Hidden while no surface is under it.
## When the scene loads it draws its content once offscreen in its preview and
## placed states, so the first preview and first placement don't compile shaders
## or upload meshes on the frame they appear.

## Only surfaces at most this steep take it: 0 for level ones such as floors and
## tables, 90 to include walls.
@export_range(0.0, 90.0, 1.0, "suffix:°") var max_slope := 20.0
## Stand along the surface's normal rather than straight up.
@export var follow_normal := false
## How small two fingers may scale it.
@export_range(0.05, 10.0, 0.05) var min_scale := 0.25
## How large two fingers may scale it.
@export_range(0.05, 10.0, 0.05) var max_scale := 4.0
## How solid its see-through preview looks, from barely there to nearly placed.
@export_range(0.05, 1.0, 0.05) var preview_opacity := 0.4
## Draws the content once offscreen when the scene loads, in both its see-through
## preview and its placed look, so the first time either appears it does not
## compile shaders or upload its meshes on that frame.
@export var warm_up_on_load := true
## The light three fingers turn left and right; the first DirectionalLight3D in the
## tree when left empty.
@export var key_light: DirectionalLight3D
## Degrees the light turns per metre three fingers drag across the view.
@export var light_yaw_per_metre := 90.0

## Whether it has been put on a surface yet.
var placed := false

## Below this separation of the fingers the angle and ratio are too unstable.
const MIN_PINCH_SPAN := 0.01
## Side of the offscreen viewport the warm-up draws into.
const WARM_UP_SIZE := 128
## How far a finger must move before it drags rather than taps.
const TAP_SLOP := 0.01

var _tracking: SurfaceTracking
## Every finger down, by id.
var _fingers := {}
## The finger moving it, or 0.
var _touch_id := 0
## Where that finger first met a surface, and where it had it when the drag began.
var _drag_hit := Vector3.ZERO
var _drag_origin := Vector3.ZERO
var _has_drag_hit := false
## Whether that finger moved far enough to drag rather than tap.
var _dragged := false
## The two fingers turning and sizing it, or 0.
var _pinch_a := 0
var _pinch_b := 0
## Where those fingers were on the surface when the pinch began.
var _pinch_from := Vector3.ZERO
var _pinch_to := Vector3.ZERO
## Its basis when the pinch began, without scale.
var _pinch_basis := Basis.IDENTITY
## Its scale when the pinch began.
var _pinch_scale := 1.0
## Uniform scale it is drawn at.
var _scale := 1.0
## Whether three fingers have turned the light, so the fingers they leave behind do
## not start dragging, pinching or tapping it.
var _held_off := false
## Whether three fingers are turning the light, and where they started.
var _yawing := false
var _yaw_from := Vector3.ZERO
var _yaw_start := 0.0
## Every mesh under it, with the material it had in the scene, and the
## see-through one it previews with.
var _meshes: Array[MeshInstance3D] = []
var _mesh_materials: Array[Material] = []
var _preview_materials: Array[Material] = []
## Every AnimationPlayer under it, with the animation each would play.
var _players: Array[AnimationPlayer] = []
var _player_animations: Array[StringName] = []
## Whether a warm-up is already running, so a second call does not build a second viewport.
var _warming_up := false


func _ready() -> void:
	visible = false
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		# Surfaces drawn under it, such as its contact shadow, keep their material.
		if mesh.is_in_group(&"no_preview"):
			continue
		_meshes.append(mesh)
		_mesh_materials.append(mesh.material_override)
		_preview_materials.append(_preview_material(mesh))
	for node in find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		var animations := player.get_animation_list()
		if animations.is_empty():
			continue
		_players.append(player)
		_player_animations.append(
			player.autoplay if player.autoplay != &"" else StringName(animations[0]))
	_set_preview(true)
	_set_animated(false)
	var parent := get_parent()
	while parent and not parent is SurfaceTracking:
		parent = parent.get_parent()
	_tracking = parent as SurfaceTracking
	if _tracking == null:
		push_error("%s needs to be under a SurfaceTracking node." % name)
		return
	_tracking.touch_started.connect(_on_touch_started)
	_tracking.touch_moved.connect(_on_touch_moved)
	_tracking.touch_ended.connect(_on_touch_ended)
	if warm_up_on_load:
		warm_up.call_deferred()


func _on_touch_started(touch: SurfaceTouch) -> void:
	_fingers[touch.id] = touch
	if _fingers.size() == 1:
		_touch_id = touch.id
		_dragged = false
		_has_drag_hit = touch.has_hit()
		if _has_drag_hit:
			_drag_hit = touch.hit().origin
	if _fingers.size() == 3:
		_begin_yaw()
		return
	_begin_pinch()


func _on_touch_moved(touch: SurfaceTouch) -> void:
	_fingers[touch.id] = touch
	if _yawing:
		_update_yaw()
		return
	_begin_pinch()
	if _pinch_a != 0:
		_update_pinch()
	elif touch.id == _touch_id:
		_drag(touch)


func _on_touch_ended(touch: SurfaceTouch) -> void:
	_fingers.erase(touch.id)
	if _yawing and _fingers.size() < 3:
		_yawing = false
	if _fingers.is_empty():
		_held_off = false
	if touch.id == _pinch_a or touch.id == _pinch_b:
		_pinch_a = 0
		_pinch_b = 0
	if touch.id != _touch_id:
		return
	# Lifting without dragging is a tap, and a tap moves nothing: only dragging
	# translates it, and only the place button puts it down.
	_touch_id = 0


## Translates it by how far the finger moves along its surface, once the finger
## has clearly moved, so a finger waiting for a second one does not move it. It
## keeps the position it had, rather than jumping to the surface under the finger.
func _drag(touch: SurfaceTouch) -> void:
	if not placed or not touch.has_hit() or _held_off:
		return
	var at := touch.hit().origin
	if not _has_drag_hit:
		_drag_hit = at
		_has_drag_hit = true
		return
	if not _dragged:
		if at.distance_to(_drag_hit) <= TAP_SLOP:
			return
		_dragged = true
		_drag_origin = global_position
	var up := global_basis.y.normalized()
	global_position = _drag_origin + (at - _drag_hit).slide(up)


## Puts it on the first surface of the touch that it may stand on, turning its -Z
## side to the phone, as for a place button. A finger already down does not then
## drag it, so the tap that pressed the button moves nothing.
func place_at(touch: SurfaceTouch) -> void:
	for hit in touch.hits:
		if _pose(hit, touch.ray.origin):
			_set_preview(false)
			_set_animated(true)
			visible = true
			placed = true
			_touch_id = 0
			_dragged = false
			_has_drag_hit = false
			return


## Takes it off the surface and back to its see-through preview, at the size it
## had in the scene.
func reset() -> void:
	visible = false
	placed = false
	_touch_id = 0
	_pinch_a = 0
	_pinch_b = 0
	_scale = 1.0
	_dragged = false
	_has_drag_hit = false
	_yawing = false
	_held_off = false
	_set_preview(true)
	_set_animated(false)


## Shows it see-through where the place button would put it, turning its -Z side
## to the eye. Does nothing once it is placed.
func preview_at(hit: Transform3D, eye: Vector3) -> void:
	if placed:
		return
	if _pose(hit, eye):
		visible = true


## Hides the preview while nothing is under the cursor, unless it is placed.
func hide_preview() -> void:
	if not placed:
		visible = false


## Starts turning the light with three fingers on a surface, left and right.
func _begin_yaw() -> void:
	var light := _light()
	if light == null:
		return
	var middle := _finger_middle()
	if not middle.is_finite():
		return
	_pinch_a = 0
	_pinch_b = 0
	_touch_id = 0
	_yawing = true
	_held_off = true
	_yaw_from = middle
	_yaw_start = light.rotation.y


## Turns the light by how far three fingers have moved across the view since they
## went down, so dragging right or left swings it.
func _update_yaw() -> void:
	var light := _light()
	if light == null or _fingers.size() != 3:
		_yawing = false
		return
	var middle := _finger_middle()
	if not middle.is_finite():
		return
	var right := Vector3.RIGHT
	if _tracking and _tracking.xr_camera:
		right = _tracking.xr_camera.global_basis.x
	right.y = 0.0
	if right.length_squared() < 1.0e-6:
		return
	right = right.normalized()
	light.rotation.y = _yaw_start + (middle - _yaw_from).dot(right) * deg_to_rad(light_yaw_per_metre)


## Where the fingers meet, on the surfaces under them; INF when one has none.
func _finger_middle() -> Vector3:
	var total := Vector3.ZERO
	for touch: SurfaceTouch in _fingers.values():
		if not touch.has_hit():
			return Vector3.INF
		total += touch.hit().origin
	return total / float(_fingers.size())


## The light three fingers turn.
func _light() -> DirectionalLight3D:
	if is_instance_valid(key_light):
		return key_light
	var from: Node = get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().root
	if from:
		for node in from.find_children("*", "DirectionalLight3D", true, false):
			key_light = node as DirectionalLight3D
			return key_light
	return null


## Starts turning and sizing with two fingers on a surface.
func _begin_pinch() -> void:
	if not placed or _pinch_a != 0 or _fingers.size() != 2 or _held_off:
		return
	var pair: Array = _fingers.values()
	var a := pair[0] as SurfaceTouch
	var b := pair[1] as SurfaceTouch
	if a == null or b == null or not a.has_hit() or not b.has_hit():
		return
	if a.hit().origin.distance_to(b.hit().origin) < MIN_PINCH_SPAN:
		return
	_pinch_a = a.id
	_pinch_b = b.id
	_pinch_from = a.hit().origin
	_pinch_to = b.hit().origin
	_pinch_basis = global_basis.orthonormalized()
	_pinch_scale = _scale
	_touch_id = 0


## Turns it by how far the fingers turned around each other, and sizes it by how
## far apart they are from how far apart they began, both about its own up axis.
func _update_pinch() -> void:
	var a := _fingers.get(_pinch_a) as SurfaceTouch
	var b := _fingers.get(_pinch_b) as SurfaceTouch
	if a == null or b == null or not a.has_hit() or not b.has_hit():
		return
	var up := _pinch_basis.y
	var from := (_pinch_to - _pinch_from).slide(up)
	var to := (b.hit().origin - a.hit().origin).slide(up)
	if from.length() < MIN_PINCH_SPAN or to.length() < MIN_PINCH_SPAN:
		return
	var angle := atan2(up.dot(from.cross(to)), from.dot(to))
	_scale = clampf(_pinch_scale * to.length() / from.length(), min_scale, max_scale)
	var turned := Basis(up, angle) * _pinch_basis
	global_transform = Transform3D(turned.scaled(Vector3.ONE * _scale), global_transform.origin)


## Stands it on the surface of hit, with +Y out of it, its -Z side to the eye.
## False when the surface is too steep to stand on.
func _pose(hit: Transform3D, eye: Vector3) -> bool:
	var normal := hit.basis.y.normalized()
	if normal.dot(Vector3.UP) < cos(deg_to_rad(max_slope)) - 0.0001:
		return false
	var up := normal if follow_normal else Vector3.UP
	var forward := (eye - hit.origin).slide(up)
	if forward.length_squared() < 1.0e-6:
		forward = (-hit.basis.z).slide(up)
	global_transform = Transform3D(Basis.looking_at(forward, up).scaled(Vector3.ONE * _scale), hit.origin)
	return true


## Runs the animations it holds once it is placed, and holds them at their first
## pose until then and after a reset.
func _set_animated(on: bool) -> void:
	for i in _players.size():
		if on:
			_players[i].play(_player_animations[i])
		else:
			_players[i].stop()


## Draws it see-through, or as the scene has it.
func _set_preview(on: bool) -> void:
	for i in _meshes.size():
		_meshes[i].material_override = _preview_materials[i] if on else _mesh_materials[i]


## A copy of the material of mesh that keeps its colour but shows what is behind
## it. Meshes without a standard material preview as a plain see-through white.
func _preview_material(mesh: MeshInstance3D) -> Material:
	var material := StandardMaterial3D.new()
	var source := mesh.get_active_material(0)
	if source is StandardMaterial3D:
		material = source.duplicate() as StandardMaterial3D
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color.a = preview_opacity
	return material


## Draws the content once offscreen in both the see-through preview material and
## the opaque material the scene gives it, plays its animations once, then frees
## the warm-up objects. The web renderer compiles a material's pipeline on its
## first draw, so this moves that cost to the splash instead of the first AR frame.
func warm_up() -> void:
	if _warming_up or placed or _meshes.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		return
	_warming_up = true
	# A SubViewport under the scene root is independent of this node's
	# visible=false and of the main camera, so nothing of the warm-up is drawn on
	# screen.
	var host: Node = get_tree().current_scene
	if host == null:
		host = self
	var viewport := SubViewport.new()
	viewport.name = "WarmUp"
	viewport.size = Vector2i(WARM_UP_SIZE, WARM_UP_SIZE)
	viewport.msaa_3d = get_viewport().msaa_3d
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# A world of its own, so it stays out of the world the AR camera and the
	# shadow projector render. own_world_3d is not enough: it leaves world_3d
	# null.
	viewport.world_3d = World3D.new()
	host.add_child(viewport)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	viewport.world_3d.environment = environment
	# One directional light and no real-time shadows, matching the surface
	# tracking scene's DirectionalLight3D; the ShadowCatcher draws its own.
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	light.shadow_enabled = false
	viewport.add_child(light)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.cull_mask = 0xFFFFFFFF
	camera.near = 0.01
	viewport.add_child(camera)
	camera.current = true
	var content: Array[MeshInstance3D] = []
	var placed_materials: Array[Material] = []
	var skeletons := {}
	var box := AABB()
	var has_box := false
	for i in _meshes.size():
		var source := _meshes[i]
		if source.mesh == null:
			continue
		var proxy := _warm_up_proxy(source, _preview_materials[i])
		var skeleton := _warm_up_skeleton(source, skeletons, viewport)
		if skeleton:
			skeleton.add_child(proxy)
			proxy.skeleton = NodePath("..")
		else:
			viewport.add_child(proxy)
		content.append(proxy)
		placed_materials.append(_mesh_materials[i])
		var bounds := proxy.transform * proxy.get_aabb()
		box = bounds if not has_box else box.merge(bounds)
		has_box = true
	# The shadow plane keeps its own material (mesh.material_override set by
	# ShadowCatcher); drawing it here compiles that shader too.
	for node in find_children("*", "MeshInstance3D", true, false):
		var shadow := node as MeshInstance3D
		if not shadow.is_in_group(&"no_preview") or shadow.mesh == null:
			continue
		var proxy := _warm_up_proxy(shadow, shadow.material_override)
		viewport.add_child(proxy)
		var bounds := proxy.transform * proxy.get_aabb()
		box = bounds if not has_box else box.merge(bounds)
		has_box = true
	if has_box:
		var middle := box.get_center()
		var reach := maxf(maxf(box.size.x, box.size.y), box.size.z)
		reach = maxf(reach, 0.5)
		camera.size = reach * 1.5
		camera.position = middle + Vector3(0.0, reach, reach * 2.0 + 1.0)
		camera.far = maxf(4000.0, reach * 10.0 + 10.0)
		camera.look_at(middle, Vector3.UP)
	else:
		camera.size = 2.0
		camera.position = Vector3(0.0, 1.0, 3.0)
		camera.look_at(Vector3.ZERO, Vector3.UP)
	# The real players are hidden, but playing them once builds their animation
	# caches; stop() in _set_animated(false) returns the pose to the preview state.
	if not placed:
		for i in _players.size():
			_players[i].play(_player_animations[i])
	await RenderingServer.frame_post_draw
	if not is_instance_valid(viewport):
		_warming_up = false
		return
	for i in content.size():
		content[i].material_override = placed_materials[i]
	await RenderingServer.frame_post_draw
	if not is_instance_valid(viewport):
		_warming_up = false
		return
	if not placed:
		_set_animated(false)
		_set_preview(true)
		visible = false
	viewport.queue_free()
	_warming_up = false


## A throwaway draw proxy that shares the source mesh, skin and layer settings.
func _warm_up_proxy(source: MeshInstance3D, material: Material) -> MeshInstance3D:
	var proxy := MeshInstance3D.new()
	proxy.mesh = source.mesh
	proxy.skin = source.skin
	proxy.material_override = material
	proxy.transform = source.transform
	proxy.layers = source.layers
	proxy.cast_shadow = source.cast_shadow
	return proxy


## A throwaway copy of the skeleton a mesh deforms with, made once per source
## skeleton. Its mesh children are removed; the proxy meshes are added instead.
func _warm_up_skeleton(source: MeshInstance3D, copies: Dictionary, parent: Node) -> Skeleton3D:
	if source.skeleton.is_empty():
		return null
	var skeleton := source.get_node_or_null(source.skeleton) as Skeleton3D
	if skeleton == null:
		return null
	if copies.has(skeleton):
		return copies[skeleton]
	var copy := skeleton.duplicate() as Skeleton3D
	for child in copy.get_children():
		copy.remove_child(child)
		child.free()
	copy.transform = Transform3D.IDENTITY
	parent.add_child(copy)
	copies[skeleton] = copy
	return copy
