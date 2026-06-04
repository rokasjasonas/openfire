extends Control
## Red arc around the crosshair pointing toward whoever last damaged the player.
## angle: 0 = directly ahead, positive = to the right (player-relative).

const DURATION := 1.1
const RADIUS := 95.0

var _angle: float = 0.0
var _t: float = 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)

func show_from(angle: float) -> void:
	_angle = angle
	_t = DURATION
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	_t -= delta
	queue_redraw()
	if _t <= 0.0:
		set_process(false)

func _draw() -> void:
	if _t <= 0.0:
		return
	var a := clampf(_t / DURATION, 0.0, 1.0)
	var c := size * 0.5
	# Screen: up (front) is -PI/2; add the player-relative angle.
	var base := -PI * 0.5 + _angle
	draw_arc(c, RADIUS, base - 0.38, base + 0.38, 16, Color(1.0, 0.2, 0.2, a), 6.0, true)
