extends Node
## Lightweight fire-and-forget sound playback. Streams are cached on first use.
## play_3d() spawns a positional one-shot that frees itself; play_ui() is 2D.

var _cache: Dictionary = {}

func _get_stream(path: String) -> AudioStream:
	if not _cache.has(path):
		_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _cache[path]

## Positional one-shot at a world position (heard relative to the active camera).
func play_3d(path: String, pos: Vector3, volume_db: float = 0.0, pitch_var: float = 0.0) -> void:
	var stream := _get_stream(path)
	if stream == null:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.volume_db = volume_db
	p.unit_size = 10.0
	p.max_distance = 90.0
	if pitch_var > 0.0:
		p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	scene.add_child(p)
	p.global_position = pos
	p.play()
	p.finished.connect(p.queue_free)

## Non-positional UI sound.
func play_ui(path: String, volume_db: float = 0.0) -> void:
	var stream := _get_stream(path)
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = volume_db
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)
