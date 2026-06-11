extends Node
## Lightweight fire-and-forget sound playback. Streams are cached on first use.
## play_3d() spawns a positional one-shot that frees itself; play_ui() is 2D.

var _cache: Dictionary = {}
var _sfx_bus: String = "Master"   # 3D SFX bus with a subtle reverb tail

func _ready() -> void:
	_setup_reverb_bus()

## A dedicated bus for positional SFX with a light reverb, so shots and impacts have
## a touch of space instead of sounding bone-dry. Fails over to Master if unavailable.
func _setup_reverb_bus() -> void:
	var idx := AudioServer.get_bus_count()
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "SFX3D")
	AudioServer.set_bus_send(idx, "Master")
	var rev := AudioEffectReverb.new()
	rev.room_size = 0.6
	rev.damping = 0.5
	rev.wet = 0.12
	rev.dry = 0.95
	rev.predelay_msec = 18.0
	AudioServer.add_bus_effect(idx, rev)
	_sfx_bus = "SFX3D"

func _get_stream(path: String) -> AudioStream:
	if not _cache.has(path):
		_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _cache[path]

## Positional one-shot at a world position (heard relative to the active camera).
## `max_dist` lets loud sounds (gunfire, blasts) carry further than incidental ones.
func play_3d(path: String, pos: Vector3, volume_db: float = 0.0, pitch_var: float = 0.0, max_dist: float = 90.0) -> void:
	var stream := _get_stream(path)
	if stream == null:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.volume_db = volume_db
	p.unit_size = 8.0
	p.max_distance = max_dist
	# Realistic rolloff + distance muffling: far sounds lose their highs.
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
	p.attenuation_filter_cutoff_hz = 3500.0
	p.attenuation_filter_db = -24.0
	p.bus = _sfx_bus
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
