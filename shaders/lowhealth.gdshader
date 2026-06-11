shader_type canvas_item;
// Red blood vignette that intensifies as health drops, with a subtle heartbeat pulse.

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float d = distance(UV, vec2(0.5));
	float v = smoothstep(0.2, 0.85, d);
	float a = v * intensity * (0.65 + 0.35 * pulse);
	COLOR = vec4(0.55, 0.0, 0.02, a);
}
