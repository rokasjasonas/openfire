extends Control
## Minimal vector crosshair drawn at the screen centre.

@export var gap: float = 6.0
@export var length: float = 10.0
@export var thickness: float = 2.0
@export var color: Color = Color(1, 1, 1, 0.85)

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var c := size * 0.5
	draw_line(c + Vector2(-gap - length, 0), c + Vector2(-gap, 0), color, thickness)
	draw_line(c + Vector2(gap, 0), c + Vector2(gap + length, 0), color, thickness)
	draw_line(c + Vector2(0, -gap - length), c + Vector2(0, -gap), color, thickness)
	draw_line(c + Vector2(0, gap), c + Vector2(0, gap + length), color, thickness)
	draw_rect(Rect2(c - Vector2(1, 1), Vector2(2, 2)), color, true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
