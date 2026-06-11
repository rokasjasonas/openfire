shader_type canvas_item;
// Cinematic screen overlay: a soft dark vignette plus animated film grain.
// Composited on top of the 3D view by a full-screen HUD ColorRect.

uniform float vignette : hint_range(0.0, 1.0) = 0.45;
uniform float grain : hint_range(0.0, 0.2) = 0.05;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	// Radial darkening toward the corners.
	float d = distance(UV, vec2(0.5));
	float vig = smoothstep(0.42, 0.95, d) * vignette;
	// Per-pixel animated noise (shifts each frame via TIME).
	float n = hash(UV * vec2(1920.0, 1080.0) + fract(TIME) * 100.0);
	float g = (n - 0.5) * grain;
	// Output a translucent black layer: vignette darkens edges, grain adds speckle.
	float a = clamp(vig + abs(g), 0.0, 1.0);
	COLOR = vec4(vec3(0.0), a);
}
