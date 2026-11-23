@tool
class_name ShadowCatcher
extends MeshInstance3D
## A patch on the surface under content that darkens the way a shadow does and is
## see-through everywhere else. CONTACT draws a soft dark patch in the middle of
## it; DYNAMIC renders what sits on [member casters_layer] from the light into a
## small viewport and projects it onto the patch, so it follows the content's pose
## and animation.
##
## A DYNAMIC shadow is everything on [member casters_layer] between the light and
## this patch; put this patch on a layer of its own, so it never casts into its own
## projection. Without a light, DYNAMIC casts nothing.
##
## It is a tool script, so the editor previews the patch too: with DYNAMIC set, the
## scene's own light projects the content onto it before you press play. The
## projector nodes it makes belong to no owner, so they never end up in the saved
## scene.

enum Mode {
	## A soft patch centred under the content.
	CONTACT,
	## What the content casts from the light, projected onto the patch.
	DYNAMIC,
}

## How far above the patch the projecting camera sits, in metres.
const PROJECTOR_DISTANCE := 4.0
const CONTACT_PATH := ShivooXRPaths.ADDON_DIR + "/shaders/contact_shadow.gdshader"
const DYNAMIC_PATH := ShivooXRPaths.ADDON_DIR + "/shaders/dynamic_shadow.gdshader"

## How the shadow is drawn.
@export var mode := Mode.CONTACT:
	set(value):
		mode = value
		refresh()
## The shader that draws a CONTACT patch. Held here so the scene carries it into
## the export, which a preload in this script would not.
@export var contact_shader: Shader:
	set(value):
		contact_shader = value
		refresh()
## The shader that draws a DYNAMIC projection.
@export var dynamic_shader: Shader:
	set(value):
		dynamic_shader = value
		refresh()
## The light a DYNAMIC shadow is cast from; the first DirectionalLight3D in the
## tree when left empty.
@export var light: DirectionalLight3D:
	set(value):
		light = value
		refresh()
## Render layer the casters are on. This patch must not be on it.
@export_flags_3d_render var casters_layer := 1:
	set(value):
		casters_layer = value
		refresh()
## Side of the square the silhouette is rendered at.
@export_range(32, 4096, 32) var resolution := 128:
	set(value):
		resolution = value
		refresh()
## How much surface, in metres, a DYNAMIC projection covers.
@export_range(0.2, 4.0, 0.05) var coverage := 1.6:
	set(value):
		coverage = value
		refresh()
## How dark the middle gets, where the content touches the surface.
@export_range(0.0, 1.0) var strength := 0.45:
	set(value):
		strength = value
		refresh()
## How far a CONTACT patch reaches from the middle, in metres.
@export_range(0.05, 2.0, 0.05) var radius := 0.35:
	set(value):
		radius = value
		refresh()
## How much of the CONTACT patch is falloff rather than solid middle.
@export_range(0.01, 1.0) var softness := 0.45:
	set(value):
		softness = value
		refresh()

var _material: ShaderMaterial
var _viewport: SubViewport
var _projector: Camera3D
## The light last found for a DYNAMIC shadow, so the tree is not walked every frame.
var _found_light: DirectionalLight3D
## The material the scene itself carries, put back before the editor saves so the
## preview material never gets baked into the scene file.
var _scene_material: Material


func _ready() -> void:
	_scene_material = material_override
	refresh()


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		material_override = _scene_material
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		refresh()


## Rebuilds the patch for the settings it has now.
func refresh() -> void:
	if not is_node_ready():
		return
	if _viewport:
		_viewport.queue_free()
		_viewport = null
		_projector = null
	# The scene carries a material too, so the editor shows a patch rather than the
	# bare mesh; keep its shader if the exported one went missing.
	var saved := material_override as ShaderMaterial
	if contact_shader == null and saved:
		contact_shader = saved.shader
	if dynamic_shader == null and saved:
		dynamic_shader = saved.shader
	var shader := contact_shader if mode == Mode.CONTACT else dynamic_shader
	if shader == null:
		# Loaded by path rather than preloaded, so a build that did not pack the
		# shader leaves nothing drawn instead of failing this script.
		shader = load(CONTACT_PATH if mode == Mode.CONTACT else DYNAMIC_PATH) as Shader
	if shader == null:
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter(&"strength", strength)
	_material.set_shader_parameter(&"size", _plane_size())
	material_override = _material
	if mode == Mode.CONTACT:
		_material.set_shader_parameter(&"softness", softness)
		_material.set_shader_parameter(&"radius", radius)
		set_process(false)
		return
	_build_projector()
	set_process(true)


func _build_projector() -> void:
	_viewport = SubViewport.new()
	_viewport.owner = null
	_viewport.size = Vector2i(resolution, resolution)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	_projector = Camera3D.new()
	_projector.projection = Camera3D.PROJECTION_ORTHOGONAL
	_projector.size = coverage * _grown()
	_projector.near = 0.01
	_projector.far = PROJECTOR_DISTANCE * 2.0
	_projector.cull_mask = casters_layer
	# Its own environment, so the scene's background does not fill the silhouette
	# in and leave nothing to sample.
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_projector.environment = environment
	_viewport.add_child(_projector)
	_projector.current = true
	_material.set_shader_parameter(&"catcher", _viewport.get_texture())


func _process(_delta: float) -> void:
	if not is_inside_tree() or _projector == null or not _projector.is_inside_tree():
		return
	var source := light if light else _find_light()
	if source == null:
		return
	var basis := source.global_basis.orthonormalized()
	var right := basis.x.normalized()
	var up := basis.y.normalized()
	var travel := -basis.z.normalized()
	var middle := global_position
	# Looking down the light, square on, so the patch sees the same frame the
	# shader samples it in.
	_projector.global_transform = Transform3D(Basis(right, up, -travel),
		middle - travel * PROJECTOR_DISTANCE)
	_material.set_shader_parameter(&"right", right)
	_material.set_shader_parameter(&"up", up)
	_material.set_shader_parameter(&"origin", middle)
	# Grow the projection with the content, so a scaled-up model does not outgrow the
	# catcher and smear its own shadow across the patch.
	var reach := coverage * _grown()
	_projector.size = reach
	_material.set_shader_parameter(&"coverage", reach)


## How much bigger than its scene size the content is drawn, from the pinch.
func _grown() -> float:
	var scale := global_transform.basis.get_scale()
	return maxf(maxf(scale.x, scale.y), scale.z)


## Side of the square the mesh draws, which the shaders measure the patch in.
func _plane_size() -> float:
	if mesh is PlaneMesh:
		return (mesh as PlaneMesh).size.x
	if mesh is QuadMesh:
		return (mesh as QuadMesh).size.x
	return maxf(get_aabb().size.x, get_aabb().size.z)


func _find_light() -> DirectionalLight3D:
	if is_instance_valid(_found_light) and _found_light.is_inside_tree():
		return _found_light
	# In the editor the scene is not under the tree root, so look in what is edited.
	var from: Node = get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().root
	if from == null:
		return null
	for node in from.find_children("*", "DirectionalLight3D", true, false):
		_found_light = node as DirectionalLight3D
		return _found_light
	return null
