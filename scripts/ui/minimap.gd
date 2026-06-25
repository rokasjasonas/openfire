extends Control
## Player-centred top-down minimap. Rotates so the local player always faces up.
## Dots: self (white arrow), allies (team blue), enemies (red), control points
## (owner colour), vehicles (yellow), objective zones (cyan).

const RANGE := 60.0   # world metres shown from centre to edge
var _radius := 88.0
var _t := 0.0         # animation clock for the active-objective pulse

func _ready() -> void:
	# Anchor a concrete 190x190 box in the top-right corner. A free Control isn't
	# sized by custom_minimum_size, so set explicit anchors + offsets or _draw gets
	# a zero size and the minimap is invisible.
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 0.0
	offset_left = -206.0
	offset_top = 16.0
	offset_right = -16.0
	offset_bottom = 206.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)

func _process(delta: float) -> void:
	_t += delta
	queue_redraw()

func _local_player() -> Node3D:
	for p in get_tree().get_nodes_in_group("player"):
		if p.is_multiplayer_authority():
			return p
	return null

func _draw() -> void:
	var c := size * 0.5
	_radius = minf(size.x, size.y) * 0.5 - 4.0
	# Backdrop
	draw_circle(c, _radius, Color(0.05, 0.06, 0.08, 0.55))
	draw_arc(c, _radius, 0, TAU, 48, Color(0.5, 0.6, 0.7, 0.5), 1.5)

	var me := _local_player()
	if me == null:
		return
	var ppos: Vector3 = me.global_position
	var my_team: int = int(me.get("team"))
	var fwd := -me.global_transform.basis.z
	fwd = Vector3(fwd.x, 0, fwd.z).normalized()
	var right := Vector3(-fwd.z, 0, fwd.x)  # player's right (= basis.x); was mirrored
	var scale := _radius / RANGE

	# Objective zones (reach/defend/etc.) + control points.
	for z in get_tree().get_nodes_in_group("zone"):
		_blip(c, z.global_position - ppos, fwd, right, scale, Color(0.3, 0.9, 1.0, 0.8), 2.5, true)
	for cp in get_tree().get_nodes_in_group("control_point"):
		var col := Game.team_color(cp.owner_team) if cp.get("owner_team") != null and cp.owner_team >= 0 else Color(0.7, 0.7, 0.7)
		_blip(c, cp.global_position - ppos, fwd, right, scale, col, 4.0, true)
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v.get("destroyed"):
			continue
		_blip(c, v.global_position - ppos, fwd, right, scale, Color(1, 0.9, 0.3), 2.5, false)
	# Co-op objective entities: destructible quest targets + the escort VIP. Harvestable
	# props (trees/rocks) and salvage (trash/barrels/wrecks) are also "destructible" but
	# must NOT clutter the minimap.
	for t in get_tree().get_nodes_in_group("destructible"):
		if t.get("destroyed") or t.is_in_group("tree") or t.is_in_group("rock") \
				or t.is_in_group("trash") or t.is_in_group("barrel") or t.is_in_group("wreck"):
			continue
		_blip(c, t.global_position - ppos, fwd, right, scale, Color(1, 0.3, 0.2), 4.0, true)
	for e in get_tree().get_nodes_in_group("escort"):
		_blip(c, e.global_position - ppos, fwd, right, scale, Color(0.4, 1.0, 0.55), 3.5, false)

	# Survival mission points (village/quest POIs). Those tied to an active quest get
	# a pulsing ring + label so the objective is unmistakable; the rest are dim. Far
	# targets clamp to the edge with an arrow pointing the way.
	var active_pois := {}        # poi -> quest title to show
	var active_factions := {}    # faction name -> true (hunt / clear_camp targets)
	var assassinate := {}        # combatant_id -> quest title (single named target)
	var qm := get_tree().get_first_node_in_group("quest_manager")
	if qm != null:
		for q in qm.quests:
			if q.get("state", "") == "active":
				if q.has("poi"):
					active_pois[q["poi"]] = String(q.get("title", ""))
				if q.has("dest") and not active_pois.has(q["dest"]):
					active_pois[q["dest"]] = String(q.get("title", ""))
				if q.has("faction"):
					active_factions[String(q["faction"])] = true
				if q.has("target_id"):
					assassinate[int(q["target_id"])] = String(q.get("title", ""))
	# Dim (non-objective) POIs first, so the active one always draws on top.
	for poi in get_tree().get_nodes_in_group("poi_site"):
		if not active_pois.has(poi):
			_blip(c, poi.global_position - ppos, fwd, right, scale, Color(0.8, 0.7, 0.3, 0.7), 3.5, true)
	for poi in active_pois:
		if is_instance_valid(poi):
			_draw_objective(c, poi.global_position - ppos, fwd, right, scale, String(active_pois[poi]))
	# Assassinate targets: a single named boss — draw their LIVE position as an
	# objective (edge-clamped + label) so you can find them from across the map.
	if not assassinate.is_empty():
		for cm in get_tree().get_nodes_in_group("combatant"):
			if cm.get("dead") or cm.get("fully_dead"):
				continue
			var cid := int(cm.get("combatant_id"))
			if assassinate.has(cid):
				_draw_objective(c, cm.global_position - ppos, fwd, right, scale, String(assassinate[cid]))

	# Combatants. Quest-focus enemies (hunt a faction / assassinate a target) glow gold.
	# In Adventure, NPCs are coloured by their stance toward you (hostile = red,
	# friendly = green, neutral = grey) so actual enemies stand out from villagers;
	# other modes use the plain enemy/ally team colours.
	var is_adv := Game.is_adventure()
	# Scanner / binoculars: briefly reveal every hostile, even off the visible area.
	var revealing: bool = bool(me.get("glassing")) or int(me.get("reveal_until")) > Time.get_ticks_msec()
	for cm in get_tree().get_nodes_in_group("combatant"):
		if cm == me or cm.get("dead") or cm.get("fully_dead"):
			continue
		if cm.is_in_group("animal"):
			# Wildlife: a small muted dot, only when nearby (no faction/objective logic).
			_blip(c, cm.global_position - ppos, fwd, right, scale, Color(0.7, 0.75, 0.5, 0.7), 2.0, false, false)
			continue
		var enemy := int(cm.get("team")) != my_team
		var is_objective: bool = enemy and (active_factions.has(String(cm.get("faction"))) or assassinate.has(int(cm.get("combatant_id"))))
		if is_objective:
			_blip(c, cm.global_position - ppos, fwd, right, scale, Color(1.0, 0.85, 0.3), 4.0, true, false)
			continue
		var col: Color
		var hostile := false
		if is_adv and cm.is_in_group("bot"):
			var fac := String(cm.get("faction"))
			var stance := String(Game.adventure_stance.get(fac, "neutral"))
			if fac == Game.RAIDER_FACTION or stance == "hostile":
				col = Color(1.0, 0.3, 0.25)     # hostile
				hostile = true
			elif stance == "friendly":
				col = Color(0.3, 0.9, 0.4)      # friendly villager
			else:
				col = Color(0.72, 0.74, 0.78)   # neutral villager
		else:
			col = Color(1, 0.35, 0.3) if enemy else Color(0.4, 0.7, 1.0)
			hostile = enemy
		if cm.get("downed"):
			col = col.darkened(0.4)
		# Combatants are only ever drawn inside the visible area — never pinned to the
		# rim (that's reserved for quest objectives). Scanner/binoculars just brighten
		# and enlarge the hostiles already in range.
		if revealing and hostile:
			_blip(c, cm.global_position - ppos, fwd, right, scale, Color(1.0, 0.5, 0.2), 4.5, false, false)
		else:
			_blip(c, cm.global_position - ppos, fwd, right, scale, col, 3.0, false, false)

	# Self (arrow pointing up).
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -7), c + Vector2(-5, 5), c + Vector2(5, 5)]),
		Color(1, 1, 1, 0.95))

## The active objective POI: bright square + an expanding "radar ping" ring, a
## direction arrow when it's off the edge, and a short label.
func _draw_objective(c: Vector2, rel: Vector3, fwd: Vector3, right: Vector3, scale: float, title: String) -> void:
	var lx := rel.dot(right)
	var lz := rel.dot(fwd)
	var p := Vector2(lx, -lz) * scale
	var clamped := p.length() > _radius - 2.0
	if clamped:
		p = p.normalized() * (_radius - 2.0)
	var sp := c + p
	var gold := Color(1.0, 0.85, 0.3)

	# Expanding ping ring (one pulse per second) so the eye is drawn to it.
	var ph: float = fmod(_t, 1.0)
	var ring_r: float = 5.0 + ph * 11.0
	var ring_col := Color(1.0, 0.9, 0.4, (1.0 - ph) * 0.85)
	draw_arc(sp, ring_r, 0, TAU, 24, ring_col, 2.0)

	# The marker itself.
	draw_rect(Rect2(sp - Vector2(5, 5), Vector2(10, 10)), gold, true)
	draw_rect(Rect2(sp - Vector2(5, 5), Vector2(10, 10)), Color(0.2, 0.15, 0, 0.9), false, 1.0)

	# Off-map: a triangle at the edge pointing toward the target.
	if clamped:
		var dir := p.normalized()
		var tip := sp + dir * 9.0
		var side := Vector2(-dir.y, dir.x) * 5.0
		draw_colored_polygon(PackedVector2Array([tip, sp - dir * 2.0 + side, sp - dir * 2.0 - side]), gold)

	# Short label, kept inside the minmap box.
	var font := get_theme_default_font()
	if font != null and title != "":
		var lbl := title if title.length() <= 16 else title.substr(0, 15) + "…"
		var w := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		var lp := Vector2(clampf(sp.x - w * 0.5, 2.0, size.x - w - 2.0), clampf(sp.y - 9.0, 11.0, size.y - 2.0))
		draw_string(font, lp + Vector2(1, 1), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0, 0, 0, 0.8))
		draw_string(font, lp, lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, gold)

## `clamp_edge`: POIs/objectives pin to the rim as direction cues; combatants pass
## false so out-of-range NPCs simply aren't drawn (no corner clutter).
func _blip(c: Vector2, rel: Vector3, fwd: Vector3, right: Vector3, scale: float, col: Color, r: float, square: bool, clamp_edge: bool = true) -> void:
	var lx := rel.dot(right)
	var lz := rel.dot(fwd)
	var p := Vector2(lx, -lz) * scale
	if p.length() > _radius - 2.0:
		if not clamp_edge:
			return  # off the minimap — don't draw it on the edge
		p = p.normalized() * (_radius - 2.0)  # clamp to edge
		col.a *= 0.6
	var sp := c + p
	if square:
		draw_rect(Rect2(sp - Vector2(r, r), Vector2(r * 2, r * 2)), col, true)
	else:
		draw_circle(sp, r, col)
