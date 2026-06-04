extends Control
## Minimal vector crosshair drawn at the screen centre.

@export var gap: float = 6.0
@export var length: float = 10.0
@export var thickness: float = 2.0
@export var color: Color = Color(1, 1, 1, 0.85)
@export var hit_color: Color = Color(1, 0.25, 0.2)

const HIT_FLASH := 0.22
var _hit_t: float = 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)

## Flash a hitmarker (call when the local player lands a hit).
func hit() -> void:
	_hit_t = HIT_FLASH
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	_hit_t -= delta
	queue_redraw()
	if _hit_t <= 0.0:
		set_process(false)

func _draw() -> void:
	var c := size * 0.5
	draw_line(c + Vector2(-gap - length, 0), c + Vector2(-gap, 0), color, thickness)
	draw_line(c + Vector2(gap, 0), c + Vector2(gap + length, 0), color, thickness)
	draw_line(c + Vector2(0, -gap - length), c + Vector2(0, -gap), color, thickness)
	draw_line(c + Vector2(0, gap), c + Vector2(0, gap + length), color, thickness)
	draw_rect(Rect2(c - Vector2(1, 1), Vector2(2, 2)), color, true)
	# Hitmarker: four diagonal ticks that fade out.
	if _hit_t > 0.0:
		var a := clampf(_hit_t / HIT_FLASH, 0.0, 1.0)
		var hc := Color(hit_color.r, hit_color.g, hit_color.b, a)
		var inner := 5.0
		var outer := 11.0
		for d in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			draw_line(c + d * inner, c + d * outer, hc, thickness + 0.5)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
