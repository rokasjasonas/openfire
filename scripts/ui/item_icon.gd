class_name ItemIcon
extends RefCounted
## Draws an item's image into `rect` on any CanvasItem: the weapon preview render
## when available, otherwise a simple symbolic glyph per item kind. Shared by the
## backpack grid and the equipment panel so both show pictures, not bare rectangles.

static func draw(ci: CanvasItem, item: Dictionary, rect: Rect2, pad: float = 4.0) -> void:
	var r := Rect2(rect.position + Vector2(pad, pad), rect.size - Vector2(pad * 2.0, pad * 2.0))
	if r.size.x <= 1.0 or r.size.y <= 1.0:
		return
	var tex := ItemDB.icon_texture(item)
	if tex != null:
		var s: float = min(r.size.x, r.size.y)  # contain-fit the square preview
		var off := r.position + (r.size - Vector2(s, s)) * 0.5
		ci.draw_texture_rect(tex, Rect2(off, Vector2(s, s)), false)
		return
	var kind := String(item.get("kind", ""))
	var col := ItemDB.color_for(kind)
	var c := r.position + r.size * 0.5
	var s2: float = min(r.size.x, r.size.y) * 0.5
	match kind:
		"health":
			var t := s2 * 0.35
			ci.draw_rect(Rect2(c.x - t, c.y - s2, t * 2.0, s2 * 2.0), col, true)
			ci.draw_rect(Rect2(c.x - s2, c.y - t, s2 * 2.0, t * 2.0), col, true)
		"water":
			ci.draw_circle(c + Vector2(0, s2 * 0.25), s2 * 0.7, col)
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(0, -s2), c + Vector2(-s2 * 0.6, s2 * 0.1), c + Vector2(s2 * 0.6, s2 * 0.1)]), col)
		"food":
			ci.draw_rect(Rect2(c.x - s2 * 0.7, c.y - s2 * 0.85, s2 * 1.4, s2 * 1.7), col, true)
			ci.draw_rect(Rect2(c.x - s2 * 0.7, c.y - s2 * 0.2, s2 * 1.4, s2 * 0.4), col.darkened(0.35), true)
		"ammo":
			for i in 3:
				var bx := c.x + (i - 1) * s2 * 0.55
				ci.draw_rect(Rect2(bx - s2 * 0.16, c.y - s2 * 0.55, s2 * 0.32, s2 * 1.1), col, true)
				ci.draw_colored_polygon(PackedVector2Array([
					Vector2(bx - s2 * 0.16, c.y - s2 * 0.55), Vector2(bx + s2 * 0.16, c.y - s2 * 0.55),
					Vector2(bx, c.y - s2 * 0.9)]), col.lightened(0.3))
		"grenade":
			ci.draw_circle(c + Vector2(0, s2 * 0.15), s2 * 0.72, col.darkened(0.1))
			ci.draw_rect(Rect2(c.x - s2 * 0.2, c.y - s2 * 0.9, s2 * 0.4, s2 * 0.4), col.darkened(0.4), true)
		"armor":
			match String(item.get("id", "")):
				"helmet":
					# A domed helmet with a brim.
					ci.draw_circle(c + Vector2(0, s2 * 0.05), s2 * 0.72, col)
					ci.draw_rect(Rect2(c.x - s2 * 0.85, c.y + s2 * 0.02, s2 * 1.7, s2 * 0.28), col.darkened(0.25), true)
				"leg_armor":
					# Two greaves side by side.
					ci.draw_rect(Rect2(c.x - s2 * 0.6, c.y - s2 * 0.8, s2 * 0.45, s2 * 1.6), col, true)
					ci.draw_rect(Rect2(c.x + s2 * 0.15, c.y - s2 * 0.8, s2 * 0.45, s2 * 1.6), col, true)
				_:
					# Vest: a shield/torso plate.
					ci.draw_colored_polygon(PackedVector2Array([
						c + Vector2(-s2 * 0.8, -s2 * 0.7), c + Vector2(s2 * 0.8, -s2 * 0.7),
						c + Vector2(s2 * 0.8, s2 * 0.1), c + Vector2(0, s2 * 0.9), c + Vector2(-s2 * 0.8, s2 * 0.1)]), col)
		"gadget":
			# A small device: a body box + a lens/bulb.
			ci.draw_rect(Rect2(c.x - s2 * 0.6, c.y - s2 * 0.45, s2 * 1.2, s2 * 0.9), col, true)
			ci.draw_circle(c + Vector2(s2 * 0.35, 0), s2 * 0.3, col.lightened(0.4))
		"material":
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(-s2 * 0.7, s2 * 0.5), c + Vector2(-s2 * 0.4, -s2 * 0.6),
				c + Vector2(s2 * 0.5, -s2 * 0.4), c + Vector2(s2 * 0.7, s2 * 0.5)]), col)
		"money":
			ci.draw_rect(Rect2(c.x - s2 * 0.8, c.y - s2 * 0.45, s2 * 1.6, s2 * 0.9), col, true)
			ci.draw_rect(Rect2(c.x - s2 * 0.8, c.y - s2 * 0.1, s2 * 1.6, s2 * 0.2), col.darkened(0.3), true)
		"backpack":
			ci.draw_rect(Rect2(c.x - s2 * 0.7, c.y - s2 * 0.55, s2 * 1.4, s2 * 1.5), col, true)
			ci.draw_rect(Rect2(c.x - s2 * 0.4, c.y - s2 * 0.85, s2 * 0.8, s2 * 0.5), col.darkened(0.25), true)
		"weapon":
			ci.draw_rect(Rect2(c.x - s2 * 0.9, c.y - s2 * 0.18, s2 * 1.8, s2 * 0.36), col, true)
			ci.draw_rect(Rect2(c.x - s2 * 0.55, c.y, s2 * 0.4, s2 * 0.7), col, true)
		_:
			ci.draw_rect(r, col, true)
