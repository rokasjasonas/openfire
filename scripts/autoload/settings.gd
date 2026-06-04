extends Node
## Persistent user settings (mouse sensitivity, volume, FOV).
## Saved to user://settings.cfg and applied globally.

const PATH := "user://settings.cfg"

signal changed

var mouse_sensitivity: float = 1.0   # multiplier (0.2 .. 3.0)
var master_volume: float = 0.8       # linear 0 .. 1
var fov: float = 75.0                # degrees (60 .. 110)

func _ready() -> void:
	load_settings()
	apply()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		mouse_sensitivity = clampf(cfg.get_value("input", "mouse_sensitivity", mouse_sensitivity), 0.2, 3.0)
		master_volume = clampf(cfg.get_value("audio", "master_volume", master_volume), 0.0, 1.0)
		fov = clampf(cfg.get_value("video", "fov", fov), 60.0, 110.0)

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("video", "fov", fov)
	cfg.save(PATH)

## Apply settings that affect global systems (audio bus). Per-player look/FOV are
## read live from this singleton by the player.
func apply() -> void:
	var db := -80.0 if master_volume <= 0.001 else linear_to_db(master_volume)
	AudioServer.set_bus_volume_db(0, db)
	changed.emit()
