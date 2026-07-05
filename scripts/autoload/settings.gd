extends Node
## Persistent user settings (mouse sensitivity, volume, FOV).
## Saved to user://settings.cfg and applied globally.

const PATH := "user://settings.cfg"

signal changed

var mouse_sensitivity: float = 1.0   # multiplier (0.2 .. 3.0)
var master_volume: float = 0.8       # linear 0 .. 1
var fov: float = 75.0                # degrees (60 .. 110)
var inventory_keycode: int = KEY_TAB # Adventure: key that opens the backpack
var quality: int = 2                 # graphics: 0 Low, 1 Medium, 2 High (cinematic effects)
var debug_mode: bool = false         # enables the in-game [0] debug/cheat menu (solo only)
const QUALITY_NAMES := ["Low", "Medium", "High"]

func quality_label() -> String:
	return QUALITY_NAMES[clampi(quality, 0, 2)]
# Local LLM (Survival story). Defaults to LM Studio's OpenAI-compatible server.
var llm_endpoint: String = "http://localhost:1234/v1/chat/completions"
var llm_model: String = "local-model"
var llm_api_key: String = ""
# Embedded llama.cpp model (downloaded on first use into user://models/).
var llm_model_url: String = "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
var llm_model_file: String = "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
# ComfyUI asset bridge. ComfyUI ships alongside the game (mandatory), so there's no
# enable toggle or folder to configure — the checkpoints folder is derived from the game
# binary's location and the model auto-downloads there.
var comfyui_endpoint: String = "http://127.0.0.1:8188"
var comfyui_checkpoint: String = "v1-5-pruned-emaonly.safetensors"   # the ComfyUI model to use
var comfyui_exec: String = ""    # optional launch command so the game can start ComfyUI
var comfyui_args: String = "--listen 127.0.0.1 --port 8188"
var comfyui_model_url: String = "https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
var comfyui_model_file: String = "v1-5-pruned-emaonly.safetensors"
# Expected download size in bytes — the % is computed against this because HuggingFace's
# LFS redirects make the HTTP Content-Length unreliable. ~4.27 GB for SD 1.5 emaonly.
var comfyui_model_size: int = 4265146304

func _ready() -> void:
	load_settings()
	apply()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		mouse_sensitivity = clampf(cfg.get_value("input", "mouse_sensitivity", mouse_sensitivity), 0.2, 3.0)
		master_volume = clampf(cfg.get_value("audio", "master_volume", master_volume), 0.0, 1.0)
		fov = clampf(cfg.get_value("video", "fov", fov), 60.0, 110.0)
		quality = clampi(int(cfg.get_value("video", "quality", quality)), 0, 2)
		debug_mode = bool(cfg.get_value("misc", "debug_mode", debug_mode))
		inventory_keycode = int(cfg.get_value("input", "inventory_key", inventory_keycode))
		llm_endpoint = String(cfg.get_value("ai", "endpoint", llm_endpoint))
		llm_model = String(cfg.get_value("ai", "model", llm_model))
		llm_api_key = String(cfg.get_value("ai", "api_key", llm_api_key))
		llm_model_url = String(cfg.get_value("ai", "model_url", llm_model_url))
		llm_model_file = String(cfg.get_value("ai", "model_file", llm_model_file))
		comfyui_endpoint = String(cfg.get_value("comfyui", "endpoint", comfyui_endpoint))
		comfyui_checkpoint = String(cfg.get_value("comfyui", "checkpoint", comfyui_checkpoint))
		comfyui_exec = String(cfg.get_value("comfyui", "exec", comfyui_exec))
		comfyui_args = String(cfg.get_value("comfyui", "args", comfyui_args))
		comfyui_model_url = String(cfg.get_value("comfyui", "model_url", comfyui_model_url))
		comfyui_model_file = String(cfg.get_value("comfyui", "model_file", comfyui_model_file))
		comfyui_model_size = int(cfg.get_value("comfyui", "model_size", comfyui_model_size))

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("input", "inventory_key", inventory_keycode)
	cfg.set_value("ai", "endpoint", llm_endpoint)
	cfg.set_value("ai", "model", llm_model)
	cfg.set_value("ai", "api_key", llm_api_key)
	cfg.set_value("ai", "model_url", llm_model_url)
	cfg.set_value("ai", "model_file", llm_model_file)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("video", "fov", fov)
	cfg.set_value("video", "quality", quality)
	cfg.set_value("misc", "debug_mode", debug_mode)
	cfg.set_value("comfyui", "endpoint", comfyui_endpoint)
	cfg.set_value("comfyui", "checkpoint", comfyui_checkpoint)
	cfg.set_value("comfyui", "exec", comfyui_exec)
	cfg.set_value("comfyui", "args", comfyui_args)
	cfg.set_value("comfyui", "model_url", comfyui_model_url)
	cfg.set_value("comfyui", "model_file", comfyui_model_file)
	cfg.set_value("comfyui", "model_size", comfyui_model_size)
	cfg.save(PATH)

## Apply settings that affect global systems (audio bus). Per-player look/FOV are
## read live from this singleton by the player.
func apply() -> void:
	var db := -80.0 if master_volume <= 0.001 else linear_to_db(master_volume)
	AudioServer.set_bus_volume_db(0, db)
	changed.emit()
