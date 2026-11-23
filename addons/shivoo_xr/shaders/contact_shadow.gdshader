shader_type spatial;
// A patch on the surface under content that darkens it the way a soft cast shadow
// would, and is invisible everywhere else. Unshaded, because the shadow is drawn
// rather than received: shadow_to_opacity does not do this in this build.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Side of the square the patch is drawn on, in metres.
uniform float size = 0.9;
// How far the darkening reaches from the middle, in metres.
uniform float radius = 0.35;
// How dark the middle gets, where the content touches the surface.
uniform float strength : hint_range(0.0, 1.0) = 0.45;
// How much of the patch is falloff rather than solid middle.
uniform float softness : hint_range(0.01, 1.0) = 0.45;

void fragment() {
	float reach = length(UV - vec2(0.5)) * size / radius;
	ALBEDO = vec3(0.0);
	ALPHA = strength * (1.0 - smoothstep(1.0 - softness, 1.0, reach));
}
