extends Node
## ComfyUI bridge (autoload "ComfyUI"). OPT-IN and off by default.
##
## ComfyUI cannot run in-process like the tiny llama.cpp text model (it's a Python +
## PyTorch + GPU stack), so this talks to a LOCAL ComfyUI server over HTTP — the same
## pattern the Story system uses for LM Studio. The game can also LAUNCH a managed
## ComfyUI process (Settings.comfyui_exec) so it feels built-in.
##
## It PRE-BAKES themed assets (textures / billboard sprites by default, or GLB models when
## a 3D workflow is configured) into user://generated/, which the world then draws from.
## Baking at world-creation is impractical (seconds-to-minutes per asset, GPU-gated), so a
## one-time library bake is the intended flow. Everything degrades gracefully: when
## disabled / unreachable / mid-bake, callers fall back to the procedural object library —
## nothing here is ever on the critical path of a match. See docs/comfyui.md.

signal server_checked(ok: bool)
signal asset_ready(key: String, path: String)
signal asset_failed(key: String)
signal bake_progress(done: int, total: int)
signal bake_finished()

const CACHE_DIR := "user://generated/"
const CLIENT_ID := "openfire"

# A minimal SD1.5/SDXL text->image workflow in ComfyUI API format. Placeholders
# (%PROMPT% %NEG% %SEED% %WIDTH% %HEIGHT% %CKPT% %STEPS%) are substituted before POST.
# Drop a file at user://comfyui/workflow_image.json (or _model.json) to override with your
# own graph — that's how a 3D (ComfyUI-3D-Pack) workflow is plugged in without code changes.
const DEFAULT_IMAGE_WORKFLOW := """{
  "3": {"class_type": "KSampler", "inputs": {"seed": %SEED%, "steps": %STEPS%, "cfg": 7.0, "sampler_name": "euler", "scheduler": "normal", "denoise": 1.0, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["5", 0]}},
  "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "%CKPT%"}},
  "5": {"class_type": "EmptyLatentImage", "inputs": {"width": %WIDTH%, "height": %HEIGHT%, "batch_size": 1}},
  "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "%PROMPT%", "clip": ["4", 1]}},
  "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "%NEG%", "clip": ["4", 1]}},
  "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
  "9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "openfire", "images": ["8", 0]}}
}"""

var _post: HTTPRequest      # POST /prompt
var _hist: HTTPRequest      # GET /history/<id> (polling)
var _view: HTTPRequest      # GET /view?filename=... (download)
var _poll: Timer
var _launched: bool = false
var _queue: Array = []      # pending [{prompt, key, kind, ext}]
var _cur: Dictionary = {}
var _cur_prompt_id: String = ""
var _polls_left: int = 0
var _bake_done: int = 0
var _bake_total: int = 0

func _ready() -> void:
	_post = _mk_http(_on_prompt_posted)
	_hist = _mk_http(_on_history)
	_view = _mk_http(_on_view_done)
	_poll = Timer.new()
	_poll.wait_time = 1.5
	_poll.one_shot = false
	add_child(_poll)
	_poll.timeout.connect(_tick_poll)
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)

func _mk_http(cb: Callable) -> HTTPRequest:
	var h := HTTPRequest.new()
	add_child(h)
	h.request_completed.connect(cb)
	return h

# ---------------------------------------------------------------- config / cache

func enabled() -> bool:
	return bool(Settings.get("comfyui_enabled"))

func endpoint() -> String:
	var e := String(Settings.get("comfyui_endpoint")).strip_edges()
	return e if e != "" else "http://127.0.0.1:8188"

## Sanitise an asset key into a safe cache filename (lowercase, [a-z0-9_-], capped).
func _safe_key(key: String) -> String:
	var s := key.strip_edges().to_lower()
	var out := ""
	for i in s.length():
		var ch := s[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
		else:
			out += "_"
	return out.substr(0, 48) if out.length() > 48 else out

func cache_path(key: String, ext: String = "png") -> String:
	return CACHE_DIR + _safe_key(key) + "." + ext

## A cached asset already exists for this key (png image, or glb model).
func has_asset(key: String) -> bool:
	return FileAccess.file_exists(cache_path(key, "png")) or FileAccess.file_exists(cache_path(key, "glb"))

## Load a cached image asset as a texture (or null). GLB models are loaded by the world
## via GLTFDocument from cache_path(key, "glb").
func asset_texture(key: String) -> Texture2D:
	var p := cache_path(key, "png")
	if not FileAccess.file_exists(p):
		return null
	var img := Image.new()
	if img.load(p) != OK:
		return null
	return ImageTexture.create_from_image(img)

# ---------------------------------------------------------------- managed server

## Best-effort: if a launch command is configured and the server isn't up yet, start it.
## Then health-check either way. Emits server_checked(ok). Safe no-op when disabled.
func ensure_server() -> void:
	if not enabled():
		server_checked.emit(false)
		return
	var exec := String(Settings.get("comfyui_exec")).strip_edges()
	if exec != "" and not _launched and FileAccess.file_exists(exec):
		var args := String(Settings.get("comfyui_args")).strip_edges().split(" ", false)
		if OS.create_process(exec, args) > 0:
			_launched = true
	_check_health()

func _check_health() -> void:
	# /system_stats returns 200 when ComfyUI is up. Reuse the history node (idle here).
	_hist.cancel_request()
	if _hist.request(endpoint() + "/system_stats") != OK:
		server_checked.emit(false)

# ---------------------------------------------------------------- baking

## Queue one asset generation. Returns immediately; emits asset_ready(key, path) when the
## file lands in the cache (or asset_failed(key)). Skips instantly if already cached.
func bake(prompt: String, key: String, kind: String = "image") -> void:
	if not enabled():
		asset_failed.emit(key)
		return
	if has_asset(key):
		asset_ready.emit(key, cache_path(key, "png"))
		return
	_queue.append({"prompt": prompt, "key": key, "kind": kind})
	_pump()

## Queue a whole library: an array of {prompt, key, kind?}. Emits bake_progress / bake_finished.
func bake_library(specs: Array) -> void:
	_bake_done = 0
	_bake_total = specs.size()
	for s in specs:
		if typeof(s) == TYPE_DICTIONARY and s.has("prompt") and s.has("key"):
			bake(String(s["prompt"]), String(s["key"]), String(s.get("kind", "image")))
	if _bake_total == 0:
		bake_finished.emit()

## A starter set of themed prop prompts to bake, so a user can verify their ComfyUI setup
## end-to-end and seed the cache. Keys are stable so worlds can later look assets up by key.
func sample_library() -> Array:
	var style := ", isometric low-poly video-game prop, centered, plain flat background, clean"
	var out: Array = []
	for e in [
		["circus_bigtop", "a red and white striped circus big-top tent"],
		["circus_wagon", "an ornate painted circus caravan wagon"],
		["circus_cannon", "a human-cannonball circus cannon on wheels"],
		["city_bench", "a green city park bench"],
		["city_hydrant", "a red fire hydrant"],
		["city_phonebooth", "a red telephone booth"],
		["city_dumpster", "a rusty steel dumpster"],
		["forest_log", "a mossy fallen tree log"],
		["forest_mushroom", "a giant red toadstool mushroom"],
		["forest_beehive", "a wooden beehive box"],
		["industrial_container", "a rusty shipping container"],
		["industrial_generator", "an industrial diesel generator"],
	]:
		out.append({"prompt": String(e[1]) + style, "key": String(e[0]), "kind": "image"})
	return out

func _pump() -> void:
	if not _cur.is_empty() or _queue.is_empty() or not enabled():
		return
	_cur = _queue.pop_front()
	var graph := _build_workflow(String(_cur["prompt"]), _stable_seed(String(_cur["key"])), String(_cur.get("kind", "image")))
	if graph == "":
		_fail_current()
		return
	var parsed = JSON.parse_string(graph)
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail_current()
		return
	var body := JSON.stringify({"prompt": parsed, "client_id": CLIENT_ID})
	_cur_prompt_id = ""
	if _post.request(endpoint() + "/prompt", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body) != OK:
		_fail_current()

## Deterministic seed from a key so re-baking the same key reproduces the same asset.
func _stable_seed(key: String) -> int:
	return abs(key.hash()) % 2147483647

## Build the ComfyUI API-format workflow string for `kind`, substituting placeholders.
## Uses a user template at user://comfyui/workflow_<kind>.json when present, else the
## built-in image graph (returns "" if a non-image kind has no template configured).
func _build_workflow(prompt: String, seed_val: int, kind: String) -> String:
	var tpl := ""
	var user_tpl := "user://comfyui/workflow_%s.json" % kind
	if FileAccess.file_exists(user_tpl):
		tpl = FileAccess.get_file_as_string(user_tpl)
	elif kind == "image":
		tpl = DEFAULT_IMAGE_WORKFLOW
	else:
		return ""   # 3D/other kinds require a user-provided workflow template
	return _apply_placeholders(tpl, prompt, seed_val)

func _apply_placeholders(tpl: String, prompt: String, seed_val: int) -> String:
	var ckpt := String(Settings.get("comfyui_checkpoint")).strip_edges()
	var esc := prompt.replace("\"", "'").replace("\n", " ")
	return tpl \
		.replace("%PROMPT%", esc) \
		.replace("%NEG%", "blurry, low quality, watermark, text") \
		.replace("%SEED%", str(seed_val)) \
		.replace("%WIDTH%", "512") \
		.replace("%HEIGHT%", "512") \
		.replace("%STEPS%", "20") \
		.replace("%CKPT%", ckpt)

# ---------------------------------------------------------------- HTTP callbacks

func _on_prompt_posted(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var d = JSON.parse_string(body.get_string_from_utf8())
		if typeof(d) == TYPE_DICTIONARY and d.has("prompt_id"):
			_cur_prompt_id = String(d["prompt_id"])
			_polls_left = 120   # ~3 min at 1.5s before giving up
			_poll.start()
			return
	_fail_current()

func _tick_poll() -> void:
	if _cur_prompt_id == "":
		_poll.stop()
		return
	_polls_left -= 1
	if _polls_left <= 0:
		_poll.stop()
		_fail_current()
		return
	_hist.cancel_request()
	_hist.request(endpoint() + "/history/" + _cur_prompt_id)

func _on_history(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	# Also serves the /system_stats health check (no current job): treat 200 as "up".
	if _cur.is_empty():
		server_checked.emit(result == HTTPRequest.RESULT_SUCCESS and code == 200)
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return   # keep polling
	var hist = JSON.parse_string(body.get_string_from_utf8())
	var ref := _extract_output_ref(hist, _cur_prompt_id)
	if ref.is_empty():
		return   # not finished yet — keep polling
	_poll.stop()
	# Fetch the produced file via /view.
	var q := "%s/view?filename=%s&subfolder=%s&type=%s" % [endpoint(),
		String(ref["filename"]).uri_encode(), String(ref.get("subfolder", "")).uri_encode(), String(ref.get("type", "output")).uri_encode()]
	var ext := "glb" if String(ref["filename"]).to_lower().ends_with(".glb") else "png"
	_cur["ext"] = ext
	_view.download_file = cache_path(String(_cur["key"]), ext)
	if _view.request(q) != OK:
		_fail_current()

## Pull the first produced file (image or model) out of a /history response, or {} if the
## job isn't finished. ComfyUI shape: {id: {outputs: {node: {images|gltf: [{filename,...}]}}}}.
func _extract_output_ref(hist, prompt_id: String) -> Dictionary:
	if typeof(hist) != TYPE_DICTIONARY or not hist.has(prompt_id):
		return {}
	var outs = (hist[prompt_id] as Dictionary).get("outputs", {})
	if typeof(outs) != TYPE_DICTIONARY:
		return {}
	for node_id in outs:
		var node = outs[node_id]
		if typeof(node) != TYPE_DICTIONARY:
			continue
		for field in ["images", "gltf", "3d", "meshes"]:
			var arr = node.get(field, [])
			if typeof(arr) == TYPE_ARRAY and not arr.is_empty() and typeof(arr[0]) == TYPE_DICTIONARY and arr[0].has("filename"):
				return arr[0]
	return {}

func _on_view_done(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	var key := String(_cur.get("key", ""))
	var ext := String(_cur.get("ext", "png"))
	var ok := result == HTTPRequest.RESULT_SUCCESS and code == 200
	if ok and FileAccess.file_exists(cache_path(key, ext)):
		asset_ready.emit(key, cache_path(key, ext))
	else:
		asset_failed.emit(key)
	_advance()

func _fail_current() -> void:
	_poll.stop()
	if not _cur.is_empty():
		asset_failed.emit(String(_cur.get("key", "")))
	_advance()

func _advance() -> void:
	_cur = {}
	_cur_prompt_id = ""
	_bake_done += 1
	bake_progress.emit(_bake_done, _bake_total)
	if _queue.is_empty():
		if _bake_total > 0:
			bake_finished.emit()
	else:
		_pump()
