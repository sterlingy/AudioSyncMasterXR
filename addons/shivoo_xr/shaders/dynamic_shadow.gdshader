shader_type spatial;
// A patch on the surface under content that darkens only where the content blocks
// the light: the silhouette is rendered from the light into a small viewport and
// sampled here in the light's own frame. Invisible where nothing is cast.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// The silhouette, rendered from the light down onto this patch.
uniform sampler2D catcher : filter_linear, repeat_disable;
// The light's frame, and the middle of the patch in world space.
uniform vec3 right = vec3(1.0, 0.0, 0.0);
uniform vec3 up = vec3(0.0, 1.0, 0.0);
uniform vec3 origin = vec3(0.0);
// How much surface, in metres, the projection covers.
uniform float coverage = 1.0;
uniform float strength : hint_range(0.0, 1.0) = 0.45;

varying vec2 shadow_uv;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 across = vec2(dot(world - origin, right), dot(world - origin, up));
	shadow_uv = vec2(across.x, -across.y) / coverage + 0.5;
}

void fragment() {
	vec4 corner = texture(catcher, vec2(0.02, 0.02));
	vec4 cast = texture(catcher, shadow_uv);
	// A catcher that clears to transparent says what it caught in its alpha, which is
	// the cheap and exact mask. A catcher that comes back opaque (the web build does)
	// has no useful alpha, so fall back to how far the pixel is from its background.
	float mask = corner.a < 0.5 ? cast.a : smoothstep(0.04, 0.16, distance(cast.rgb, corner.rgb));
	ALBEDO = vec3(0.0);
	ALPHA = mask * strength;
}
