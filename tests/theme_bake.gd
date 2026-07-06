extends SceneTree

# Live check: fire the five theme texture bakes against the running ComfyUI and confirm
# each one comes back as a real PNG. Run: .tools/godot --headless --path . tests/theme_bake.gd
func _init() -> void:
	_run()

func _run() -> void:
	var theme := "candy mountains"
	var specs := {
		"tex_ground_": "seamless tileable top-down ground texture of %s, aerial overhead view, repeating pattern, natural detail",
		"tex_water_": "seamless tileable water surface of %s, top-down, ripples and reflections, repeating pattern",
		"tex_sky_": "panoramic sky of %s, wide horizon, clouds, atmospheric, matte painting",
		"tex_boundary_": "seamless tileable rocky cliff wall texture of %s, vertical stone face, weathered, repeating pattern",
		"tex_building_": "seamless tileable building facade wall texture of %s, architectural surface, repeating pattern, weathered detail",
	}
	var got := {}
	ComfyUI.asset_ready.connect(func(key: String, path: String):
		got[key] = path
		print("BAKE ready: %s -> %s" % [key, path]))
	for prefix in specs:
		ComfyUI.bake((specs[prefix] as String) % theme, prefix + theme, "image")
	# Poll up to ~90s for all five.
	var waited := 0.0
	while got.size() < specs.size() and waited < 90.0:
		await create_timer(1.0).timeout
		waited += 1.0
	var ok := true
	for prefix in specs:
		var key := prefix + theme
		var good := got.has(key) and String(got[key]).to_lower().ends_with(".png") and FileAccess.file_exists(got[key])
		print("BAKE %s = %s" % [key, "OK" if good else "MISSING"])
		ok = ok and good
	print("THEME_BAKE: DONE ok=%s (%d/%d in %ds)" % [ok, got.size(), specs.size(), int(waited)])
	quit(0 if ok else 1)
