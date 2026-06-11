extends Node
## Embedded LLM service (autoload "LLM"). Runs a GGUF model IN-PROCESS via the
## NobodyWho GDExtension (which wraps llama.cpp) when that addon is installed and a
## model file is present. The model is DOWNLOADED on first use into user://models/.
##
## Everything is guarded by `embedded_available()` (the NobodyWho class existing),
## so without the addon this autoload does nothing and Story falls back to the local
## HTTP server (LM Studio) and then offline generation. See docs/llm.md.

signal download_progress(fraction: float)
signal model_ready(ok: bool)
signal chat_done(text: String)

const MODEL_DIR := "user://models/"

var downloading: bool = false
var _dl: HTTPRequest
var _model_node: Node = null
var _chat_node: Node = null
var _busy: bool = false
var _started: bool = false
var _worker_ready: bool = false
var _pending: String = ""
var _system: String = ""   # system prompt currently loaded in the chat context

func _ready() -> void:
	_dl = HTTPRequest.new()
	add_child(_dl)
	_dl.request_completed.connect(_on_download_done)
	set_process(false)

func model_path() -> String:
	return MODEL_DIR + Settings.llm_model_file

## Human-readable name of the embedded model (the GGUF filename without extension),
## e.g. "Qwen2.5-1.5B-Instruct-Q4_K_M". Shown on the loading screen.
func model_name() -> String:
	return Settings.llm_model_file.get_basename()

## NobodyWho (llama.cpp) GDExtension installed?
func embedded_available() -> bool:
	return ClassDB.class_exists("NobodyWhoModel")

func has_model() -> bool:
	return FileAccess.file_exists(model_path())

## Can we run an embedded model right now (addon + downloaded model)?
func embedded_ready() -> bool:
	return embedded_available() and has_model()

# ---------------------------------------------------------------- model download

## Make sure the model file exists, downloading it on first use. Emits model_ready
## (false means: no addon / no URL / download failed -> caller uses HTTP/offline).
func ensure_model() -> void:
	if not embedded_available():
		model_ready.emit(false)
		return
	if has_model():
		model_ready.emit(true)
		return
	if Settings.llm_model_url.strip_edges() == "":
		model_ready.emit(false)
		return
	DirAccess.make_dir_recursive_absolute(MODEL_DIR)
	_dl.download_file = model_path() + ".part"
	if _dl.request(Settings.llm_model_url) != OK:
		model_ready.emit(false)
		return
	downloading = true
	set_process(true)

func _process(_delta: float) -> void:
	if downloading and _dl.get_body_size() > 0:
		download_progress.emit(float(_dl.get_downloaded_bytes()) / float(_dl.get_body_size()))

func _on_download_done(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	if not downloading:
		return
	downloading = false
	set_process(false)
	var part := model_path() + ".part"
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		DirAccess.rename_absolute(part, model_path())
		model_ready.emit(has_model())
	else:
		if FileAccess.file_exists(part):
			DirAccess.remove_absolute(part)
		model_ready.emit(false)

# ---------------------------------------------------------------- embedded chat

func _ensure_nodes(system: String) -> bool:
	if not embedded_ready():
		return false
	if _model_node == null:
		_model_node = ClassDB.instantiate("NobodyWhoModel")
		_model_node.set("model_path", ProjectSettings.globalize_path(model_path()))
		add_child(_model_node)
	if _chat_node == null:
		_chat_node = ClassDB.instantiate("NobodyWhoChat")
		_chat_node.set("model_node", _model_node)
		_chat_node.set("system_prompt", system)
		_system = system
		_chat_node.set("context_length", 4096)
		add_child(_chat_node)
		_chat_node.connect("response_finished", _on_chat_finished)
		if _chat_node.has_signal("worker_failed"):
			_chat_node.connect("worker_failed", _on_worker_failed)
		if _chat_node.has_signal("worker_started"):
			_chat_node.connect("worker_started", _on_worker_started)
	if not _started:
		_chat_node.call("start_worker")  # loads the model on a worker thread
		_started = true
	return true

## Start one embedded generation. Returns false if unavailable/busy; otherwise
## emits chat_done(text) when finished (or chat_done("") on failure). One at a time.
func chat(system: String, user: String) -> bool:
	if _busy or not _ensure_nodes(system):
		return false
	# The chat node keeps its system prompt + history across calls; when a different
	# caller needs a different persona (story JSON vs an NPC speaking in character),
	# swap the system prompt and reset the context so the old one doesn't bleed in.
	if system != _system:
		_system = system
		_chat_node.set("system_prompt", system)
		if _chat_node.has_method("reset_context"):
			_chat_node.call("reset_context")
		elif _chat_node.has_method("reset"):
			_chat_node.call("reset")
	_busy = true
	if _worker_ready:
		_chat_node.call("say", user)
	else:
		_pending = user  # say once the worker has loaded the model
	return true

func _on_worker_started() -> void:
	_worker_ready = true
	if _pending != "":
		var u := _pending
		_pending = ""
		_chat_node.call("say", u)

func _on_chat_finished(text: String) -> void:
	if not _busy:
		return
	_busy = false
	chat_done.emit(text)

func _on_worker_failed(_msg: String) -> void:
	if not _busy:
		return
	_busy = false
	chat_done.emit("")  # let Story fall back
