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
signal model_progress(fraction: float, downloaded: int, total: int)
signal model_ready(ok: bool, message: String)
signal install_progress(stage: String, fraction: float)
signal install_done(ok: bool, message: String)

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

# img2img: re-theme an uploaded base image (%IMAGE%) while keeping its layout — a low denoise
# so a character/UV texture is recoloured, not redrawn. Used for template-based NPC skins.
const IMG2IMG_WORKFLOW := """{
  "10": {"class_type": "LoadImage", "inputs": {"image": "%IMAGE%"}},
  "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "%CKPT%"}},
  "11": {"class_type": "VAEEncode", "inputs": {"pixels": ["10", 0], "vae": ["4", 2]}},
  "3": {"class_type": "KSampler", "inputs": {"seed": %SEED%, "steps": %STEPS%, "cfg": 6.0, "sampler_name": "euler", "scheduler": "normal", "denoise": 0.55, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["11", 0]}},
  "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "%PROMPT%", "clip": ["4", 1]}},
  "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "%NEG%", "clip": ["4", 1]}},
  "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
  "9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "openfire", "images": ["8", 0]}}
}"""

# Fixed filename the 3D workflow's Save node writes (must match workflow_model.json save_path),
# so the game can fetch it from ComfyUI's output dir without it appearing in /history outputs.
const MODEL_OUTPUT_FILE := "openfire3d.glb"

var _post: HTTPRequest      # POST /prompt
var _hist: HTTPRequest      # GET /history/<id> (polling)
var _view: HTTPRequest      # GET /view?filename=... (download)
var _info: HTTPRequest      # GET /object_info (available checkpoints)
var _dl: HTTPRequest        # model download
var _dl_bundle: HTTPRequest # ComfyUI bundle download (auto-install)
var _upload: HTTPRequest    # POST /upload/image for img2img base images
var _upload_pending: Dictionary = {}   # {prompt, key} awaiting an upload to finish
var _downloading: bool = false
var _installing: bool = false
var _cur_retried: bool = false   # did we already auto-fix the checkpoint for this job?
var _poll: Timer
var _launched: bool = false
var _queue: Array = []      # pending [{prompt, key, kind, ext}]
var _cur: Dictionary = {}
var _cur_prompt_id: String = ""
var _polls_left: int = 0
var _bake_done: int = 0
var _bake_total: int = 0
var last_error: String = ""   # human-readable reason the last bake failed (for the UI)

func _ready() -> void:
	_post = _mk_http(_on_prompt_posted)
	_hist = _mk_http(_on_history)
	_view = _mk_http(_on_view_done)
	_info = _mk_http(_on_object_info)
	_dl = _mk_http(_on_model_downloaded)
	_dl_bundle = _mk_http(_on_bundle_downloaded)
	_upload = _mk_http(_on_image_uploaded)
	set_process(false)
	_poll = Timer.new()
	_poll.wait_time = 1.5
	_poll.one_shot = false
	add_child(_poll)
	_poll.timeout.connect(_tick_poll)
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	# Boot at game start (deferred): auto-install ComfyUI from a bundle if configured, else
	# launch a bundled one, else just health-check a reachable server. No-op if nothing applies.
	call_deferred("_boot")

func _mk_http(cb: Callable) -> HTTPRequest:
	var h := HTTPRequest.new()
	add_child(h)
	h.request_completed.connect(cb)
	return h

# ---------------------------------------------------------------- config / cache

## ComfyUI is a mandatory part of the game, shipped alongside the binary — always on.
func enabled() -> bool:
	return true

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

# ---------------------------------------------------------------- model download

## The standalone "comfyui" folder that ships next to the game binary (the ComfyUI portable
## / install lives here). In the editor the executable is Godot itself, so fall back to user://.
func comfyui_base_dir() -> String:
	var base := OS.get_executable_path().get_base_dir()
	if base == "" or OS.has_feature("editor"):
		return ProjectSettings.globalize_path("user://comfyui")
	return base.path_join("comfyui")

## Where the checkpoint is downloaded (under the bundled comfyui folder).
func checkpoints_dir() -> String:
	return comfyui_base_dir().path_join("models/checkpoints")

## Absolute path where the checkpoint should live (inside the bundled checkpoints folder).
func local_model_path() -> String:
	return checkpoints_dir().path_join(String(Settings.comfyui_model_file))

func model_paths_yaml() -> String:
	return comfyui_base_dir().path_join("extra_model_paths.yaml")

## Write a ComfyUI extra_model_paths.yaml pointing at the bundled models folder. Written both
## to the comfyui/ root (for `--extra-model-paths-config`) AND into the ComfyUI app dir if a
## portable layout exists (ComfyUI auto-reads extra_model_paths.yaml next to its main.py),
## so a bundled/portable ComfyUI finds the downloaded model with no launch flags.
func write_model_paths_yaml() -> void:
	var base := comfyui_base_dir()
	DirAccess.make_dir_recursive_absolute(base.path_join("models/checkpoints"))
	var yaml := "openfire:\n    base_path: %s\n    checkpoints: models/checkpoints/\n    vae: models/vae/\n    loras: models/loras/\n" % base
	var targets := [model_paths_yaml()]
	# Portable ComfyUI is usually at comfyui/ComfyUI/ — drop a copy there too if it exists.
	if DirAccess.dir_exists_absolute(base.path_join("ComfyUI")):
		targets.append(base.path_join("ComfyUI/extra_model_paths.yaml"))
	for t in targets:
		var f := FileAccess.open(t, FileAccess.WRITE)
		if f != null:
			f.store_string(yaml)
			f.close()

func has_local_model() -> bool:
	var p := local_model_path()
	return p != "" and FileAccess.file_exists(p)

## Download the configured checkpoint into the bundled checkpoints folder (next to the game
## binary) so generation works without a manual model install. Emits model_progress /
## model_ready. On success, points the checkpoint setting at it.
func download_model() -> void:
	if _downloading:
		return
	if has_local_model():
		Settings.comfyui_checkpoint = String(Settings.comfyui_model_file)
		Settings.save()
		model_ready.emit(true, "Model already present.")
		return
	if String(Settings.comfyui_model_url).strip_edges() == "":
		model_ready.emit(false, "No model URL configured.")
		return
	DirAccess.make_dir_recursive_absolute(checkpoints_dir())
	write_model_paths_yaml()   # so ComfyUI can be pointed at the model we're about to fetch
	_dl.download_file = local_model_path() + ".part"
	if _dl.request(String(Settings.comfyui_model_url)) != OK:
		model_ready.emit(false, "Couldn't start the download.")
		return
	_downloading = true
	set_process(true)

func _process(_delta: float) -> void:
	if _downloading:
		var dl := _dl.get_downloaded_bytes()
		var total := _dl.get_body_size()   # -1 / 0 when the server sends no Content-Length
		model_progress.emit((float(dl) / float(total)) if total > 0 else 0.0, dl, total)
	elif _installing:
		var bd := _dl_bundle.get_downloaded_bytes()
		var bt := _dl_bundle.get_body_size()
		install_progress.emit("Downloading ComfyUI…", (float(bd) / float(bt)) if bt > 0 else 0.0)

func _on_model_downloaded(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	if not _downloading:
		return
	_downloading = false
	set_process(false)
	var part := local_model_path() + ".part"
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		DirAccess.rename_absolute(part, local_model_path())
		Settings.comfyui_checkpoint = String(Settings.comfyui_model_file)
		Settings.save()
		write_model_paths_yaml()
		model_ready.emit(true, "Model downloaded. Point ComfyUI at %s (restart it if already running)." % model_paths_yaml())
	else:
		if FileAccess.file_exists(part):
			DirAccess.remove_absolute(part)
		model_ready.emit(false, "Download failed (HTTP %d / result %d)." % [code, result])

# ---------------------------------------------------------------- auto-install

## Startup: install (if a bundle is set and nothing's here yet) then launch, or just launch
## a present ComfyUI, or fall through to health-checking whatever's already running.
func _boot() -> void:
	if is_installed():
		ensure_server()
		return
	# Auto-install only in a real windowed build — never during headless smoke or the editor
	# (so tests and the editor don't pull a multi-GB bundle over the network).
	var real_build := not OS.has_feature("editor") and DisplayServer.get_name() != "headless"
	if real_build and String(Settings.comfyui_bundle_url).strip_edges() != "":
		ensure_installed()   # auto-download + extract + launch — "download game, play"
	else:
		ensure_server()

## True once a ready-to-run ComfyUI exists next to the game (a launcher is present).
func is_installed() -> bool:
	return _bundled_launcher() != ""

## "Download game, play": if no ComfyUI is bundled and a bundle URL is configured, download
## the ComfyUI .zip and extract it into comfyui/ so the game can launch it — all automatic.
## Emits install_progress / install_done. No-op when already installed or no URL is set.
func ensure_installed() -> void:
	if is_installed() or _installing:
		install_done.emit(is_installed(), "")
		return
	var url := String(Settings.comfyui_bundle_url).strip_edges()
	if url == "":
		install_done.emit(false, "No ComfyUI bundle configured to auto-install.")
		return
	_installing = true
	install_progress.emit("Downloading ComfyUI…", 0.0)
	var zip := comfyui_base_dir().path_join("_bundle.zip")
	DirAccess.make_dir_recursive_absolute(comfyui_base_dir())
	_dl_bundle.download_file = zip
	if _dl_bundle.request(url) != OK:
		_installing = false
		install_done.emit(false, "Couldn't start the ComfyUI download.")
		return
	set_process(true)

func _on_bundle_downloaded(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	if not _installing:
		return
	set_process(false)
	var zip := comfyui_base_dir().path_join("_bundle.zip")
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_installing = false
		install_done.emit(false, "ComfyUI download failed (HTTP %d)." % code)
		return
	install_progress.emit("Extracting ComfyUI…", 1.0)
	var ok := _extract_zip(zip, comfyui_base_dir())
	if FileAccess.file_exists(zip):
		DirAccess.remove_absolute(zip)
	_installing = false
	if ok and is_installed():
		install_done.emit(true, "ComfyUI installed. Starting it…")
		ensure_server()
	else:
		install_done.emit(false, "Extracted, but no launcher found in the bundle.")

## Extract a .zip into `dest` (Godot's ZIPReader handles .zip; the ComfyUI portable's .7z
## is not supported, hence the .zip bundle requirement). Returns true on success.
func _extract_zip(zip_path: String, dest: String) -> bool:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return false
	for name in reader.get_files():
		var out := dest.path_join(name)
		if name.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(out)
			continue
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f != null:
			f.store_buffer(reader.read_file(name))
			f.close()
	reader.close()
	return true

# ---------------------------------------------------------------- managed server

## Best-effort: if a launch command is configured and the server isn't up yet, start it.
## Then health-check either way. Emits server_checked(ok). Safe no-op when disabled.
func ensure_server() -> void:
	if not enabled():
		server_checked.emit(false)
		return
	var exec := String(Settings.get("comfyui_exec")).strip_edges()
	if exec == "":
		exec = _bundled_launcher()   # auto-detect a ComfyUI shipped next to the game
	if exec != "" and not _launched and FileAccess.file_exists(exec):
		var args := Array(String(Settings.get("comfyui_args")).strip_edges().split(" ", false))
		# Point the launched ComfyUI at the bundled model folder so it finds our download.
		if not args.has("--extra-model-paths-config"):
			write_model_paths_yaml()
			args.append("--extra-model-paths-config")
			args.append(model_paths_yaml())
		if OS.create_process(exec, PackedStringArray(args)) > 0:
			_launched = true
	_check_health()

## A ComfyUI launcher shipped in the game's own comfyui/ folder, if present. The game runs
## this automatically so ComfyUI is "embedded" from the player's side. The distribution is
## responsible for placing a ComfyUI + launcher script here (start.sh / start.bat).
func _bundled_launcher() -> String:
	var base := comfyui_base_dir()
	var names := ["start.bat", "run_nvidia_gpu.bat", "run_cpu.bat"] if OS.get_name() == "Windows" \
		else ["start.sh", "run.sh"]
	for n in names:
		var p := base.path_join(n)
		if FileAccess.file_exists(p):
			return p
	return ""

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

## Template reskin: re-theme an existing texture (res:// path) via img2img so the result keeps
## the original's UV layout — used for NPC skins. Uploads the base image to ComfyUI, then runs
## the img2img workflow. Emits asset_ready(key, path) with the reskinned PNG (cached).
func reskin(base_res_path: String, prompt: String, key: String) -> void:
	if not enabled():
		asset_failed.emit(key)
		return
	if has_asset(key):
		asset_ready.emit(key, cache_path(key, "png"))
		return
	var tex = load(base_res_path)
	if tex == null or not (tex is Texture2D):
		asset_failed.emit(key)
		return
	var img := (tex as Texture2D).get_image()
	if img == null:
		asset_failed.emit(key)
		return
	if img.is_compressed():
		img.decompress()
	var png := img.save_png_to_buffer()
	# Upload the base image, then (in _on_image_uploaded) queue the img2img job referencing it.
	_upload_pending = {"prompt": prompt, "key": key}
	var boundary := "openfireBoundary1234567890"
	var body := PackedByteArray()
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"image\"; filename=\"%s.png\"\r\nContent-Type: image/png\r\n\r\n" % [boundary, _safe_key(key)]).to_utf8_buffer())
	body.append_array(png)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	var headers := ["Content-Type: multipart/form-data; boundary=%s" % boundary]
	if _upload.request_raw(endpoint() + "/upload/image", headers, HTTPClient.METHOD_POST, body) != OK:
		_upload_pending = {}
		asset_failed.emit(key)

func _on_image_uploaded(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if _upload_pending.is_empty():
		return
	var pend := _upload_pending
	_upload_pending = {}
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		asset_failed.emit(String(pend.get("key", "")))
		return
	var d = JSON.parse_string(body.get_string_from_utf8())
	var name := ""
	if typeof(d) == TYPE_DICTIONARY:
		name = String(d.get("name", ""))
	if name == "":
		asset_failed.emit(String(pend.get("key", "")))
		return
	# Queue the img2img job carrying the uploaded image name.
	_queue.append({"prompt": String(pend["prompt"]), "key": String(pend["key"]), "kind": "reskin", "image": name})
	_pump()

func _pump() -> void:
	if not _cur.is_empty() or _queue.is_empty() or not enabled():
		return
	_cur = _queue.pop_front()
	last_error = ""
	_cur_retried = false
	_submit_current()

## Build + POST the current job's workflow. Reused for the auto-checkpoint retry.
func _submit_current() -> void:
	var kind := String(_cur.get("kind", "image"))
	var graph := _build_workflow(String(_cur["prompt"]), _stable_seed(String(_cur["key"])), kind)
	if graph == "":
		last_error = "No workflow for kind '%s' — add user://comfyui/workflow_%s.json." % [kind, kind]
		_fail_current()
		return
	if _cur.has("image"):
		graph = graph.replace("%IMAGE%", String(_cur["image"]))   # img2img base (reskin)
	if typeof(JSON.parse_string(graph)) != TYPE_DICTIONARY:
		_fail_current()   # sanity-check it parses, but DON'T re-stringify (see below)
		return
	# Send the ORIGINAL graph string, not a re-stringified parse. Godot's JSON roundtrip
	# turns every int into a float (e.g. a node slot ["5", 0] becomes ["5", 0.0]), and
	# ComfyUI's connection validation requires integer slot indices — floats 400 with
	# "tuple indices must be integers, not float". Concatenation keeps the int literals.
	var body := '{"prompt": %s, "client_id": "%s"}' % [graph, CLIENT_ID]
	_cur_prompt_id = ""
	if _post.request(endpoint() + "/prompt", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body) != OK:
		_fail_current()

## Deterministic seed from a key so re-baking the same key reproduces the same asset.
func _stable_seed(key: String) -> int:
	return abs(key.hash()) % 2147483647

## Path to the workflow template for `kind`, or "" if none. Search order: a user override at
## user://comfyui/workflow_<kind>.json, then the one shipped inside the ComfyUI bundle
## (comfyui/workflow_<kind>.json). The bundled one means text→3D works with zero user setup.
func workflow_template_path(kind: String) -> String:
	var user_tpl := "user://comfyui/workflow_%s.json" % kind
	if FileAccess.file_exists(user_tpl):
		return user_tpl
	var bundled := comfyui_base_dir().path_join("workflow_%s.json" % kind)
	if FileAccess.file_exists(bundled):
		return bundled
	return ""

## Is a workflow available for `kind`? (Built-in kinds always are.)
func has_workflow(kind: String) -> bool:
	if kind == "image" or kind == "reskin":
		return true
	return workflow_template_path(kind) != ""

## Build the ComfyUI API-format workflow string for `kind`, substituting placeholders.
## Uses a user/bundled template at workflow_<kind>.json when present, else the built-in image
## graph (returns "" if a non-image kind has no template — e.g. 3D without the bundle).
func _build_workflow(prompt: String, seed_val: int, kind: String) -> String:
	var tpl := ""
	var tpl_path := workflow_template_path(kind)
	if tpl_path != "":
		tpl = FileAccess.get_file_as_string(tpl_path)
	elif kind == "image":
		tpl = DEFAULT_IMAGE_WORKFLOW
	elif kind == "reskin":
		tpl = IMG2IMG_WORKFLOW
	else:
		return ""   # 3D/other kinds require a workflow template (bundled or user-provided)
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
	# A 400 is usually a checkpoint that isn't installed. Fetch the real list, fix the
	# setting, and retry once before giving up.
	if result == HTTPRequest.RESULT_SUCCESS and code == 400 and not _cur_retried and not _cur.is_empty():
		_cur_retried = true
		last_error = "ComfyUI rejected it (400): auto-detecting your installed checkpoint and retrying…"
		_info.cancel_request()
		if _info.request(endpoint() + "/object_info/CheckpointLoaderSimple") == OK:
			return
	# Surface WHY it failed so the UI can show something actionable.
	if result != HTTPRequest.RESULT_SUCCESS:
		last_error = "Can't reach ComfyUI at %s (network error %d) — is the server running there?" % [endpoint(), result]
	else:
		last_error = "ComfyUI rejected the workflow (HTTP %d): %s" % [code, _err_snippet(body)]
	_fail_current()

## Response to /object_info/CheckpointLoaderSimple: pick a valid checkpoint (the configured
## one if installed, else the first available) and re-submit the current job.
func _on_object_info(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var list := _checkpoint_list(JSON.parse_string(body.get_string_from_utf8()))
		if list.is_empty():
			# ComfyUI can see NO models — it's reading a different folder than where the game
			# downloaded one. Retrying won't help; point it at the config the game wrote.
			write_model_paths_yaml()
			last_error = "ComfyUI has no models. Launch it with:  --extra-model-paths-config \"%s\"  (or copy that file into your ComfyUI folder), then restart." % model_paths_yaml()
			_fail_current()
			return
		if not list.has(String(Settings.comfyui_checkpoint)):
			Settings.comfyui_checkpoint = String(list[0])
			Settings.save()
	if not _cur.is_empty():
		_submit_current()   # retry with the corrected checkpoint
	else:
		_fail_current()

## Extract the installed checkpoint names from a ComfyUI /object_info response.
func _checkpoint_list(info) -> Array:
	if typeof(info) != TYPE_DICTIONARY:
		return []
	var node = info.get("CheckpointLoaderSimple", {})
	if typeof(node) != TYPE_DICTIONARY:
		return []
	var req = node.get("input", {}).get("required", {})
	if typeof(req) != TYPE_DICTIONARY:
		return []
	var ck = req.get("ckpt_name", [])
	if typeof(ck) == TYPE_ARRAY and not ck.is_empty() and typeof(ck[0]) == TYPE_ARRAY:
		return ck[0]   # ComfyUI wraps the choices list: [ [name1, name2, ...], {...} ]
	return []

## Pull a short, human-readable reason out of a ComfyUI error body (which lists
## error.message and per-node errors, e.g. a checkpoint that isn't installed).
func _err_snippet(body: PackedByteArray) -> String:
	var txt := body.get_string_from_utf8()
	var d = JSON.parse_string(txt)
	if typeof(d) == TYPE_DICTIONARY:
		var err = d.get("error", {})
		if typeof(err) == TYPE_DICTIONARY and err.has("message"):
			var msg := String(err["message"])
			var ne = d.get("node_errors", {})
			if typeof(ne) == TYPE_DICTIONARY and not ne.is_empty():
				msg += " (check the checkpoint name matches an installed model)"
			return msg
	return txt.substr(0, 160)

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
	# The job may have run and ERRORED (bad workflow / missing model / OOM). Detect that
	# so we fail fast with a message instead of polling to the 3-minute timeout.
	if typeof(hist) == TYPE_DICTIONARY and hist.has(_cur_prompt_id):
		var status = (hist[_cur_prompt_id] as Dictionary).get("status", {})
		if typeof(status) == TYPE_DICTIONARY and String(status.get("status_str", "")) == "error":
			last_error = "ComfyUI failed to run the workflow (missing model, bad node, or out of memory) — see the ComfyUI console."
			_poll.stop()
			_fail_current()
			return
	# 3D jobs end with [Comfy3D] Save 3D Mesh, which writes a fixed GLB to the output dir but does
	# NOT surface it in /history outputs. So once the job appears in history (finished) without an
	# error, fetch that known filename directly instead of scanning outputs.
	if String(_cur.get("kind", "")) == "model":
		if typeof(hist) != TYPE_DICTIONARY or not hist.has(_cur_prompt_id):
			return   # not finished yet — keep polling
		_poll.stop()
		_cur["ext"] = "glb"
		_view.download_file = cache_path(String(_cur["key"]), "glb")
		if _view.request("%s/view?filename=%s&type=output" % [endpoint(), MODEL_OUTPUT_FILE.uri_encode()]) != OK:
			_fail_current()
		return
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
