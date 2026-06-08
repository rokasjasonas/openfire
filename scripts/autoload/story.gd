extends Node
## Survival story generator (autoload "Story"). Produces the world's narrative AND
## names the NPCs from a player-entered theme.
##
## Backend priority: an EMBEDDED llama.cpp model (LLM autoload, in-process) if ready,
## else a local OpenAI-compatible HTTP server (LM Studio), else a deterministic
## offline story. The story and the (large) name list are generated as TWO separate
## requests so a truncated/failed names reply can't break the briefing.
##
## Output dict: { briefing, factions{name:lore}, greetings{name:line},
##               names{faction:[{name,trait}]}, outro }

signal story_ready(story: Dictionary)
signal phase_changed(text: String)   # human-readable loading-screen status

const SYS := "You write game content. Respond with ONLY a compact JSON object, no markdown, no prose."

var story: Dictionary = {}
var _theme: String = ""
var _facts: Dictionary = {}
var _http_story: HTTPRequest
var _http_names: HTTPRequest
var _story_part: Dictionary = {}
var _names_part: Dictionary = {}
var _story_pending: bool = false
var _names_pending: bool = false

func _ready() -> void:
	_http_story = _make_http()
	_http_names = _make_http()
	_http_story.request_completed.connect(_on_story_done)
	_http_names.request_completed.connect(_on_names_done)

func _make_http() -> HTTPRequest:
	var h := HTTPRequest.new()
	h.timeout = 60.0
	add_child(h)
	return h

func generate(theme: String, facts: Dictionary) -> void:
	_theme = theme.strip_edges()
	if _theme == "":
		_theme = "a harsh survival frontier"
	_facts = facts
	_story_part = {}
	_names_part = {}
	if LLM.embedded_ready():
		_generate_embedded()
	else:
		_generate_http()

# ---------------------------------------------------------------- embedded (llama.cpp)

func _generate_embedded() -> void:
	phase_changed.emit("Writing the world's story…")
	LLM.chat_done.connect(_on_embed_story, CONNECT_ONE_SHOT)
	if not LLM.chat(SYS, _story_prompt()):
		_story_part = _fallback_story()
		_names_part = {}
		_finish_embedded()

func _on_embed_story(text: String) -> void:
	_story_part = _parse_story_content(text)
	if _story_part.is_empty():
		_story_part = _fallback_story()
	phase_changed.emit("Naming the inhabitants…")
	LLM.chat_done.connect(_on_embed_names, CONNECT_ONE_SHOT)
	if not LLM.chat(SYS, _names_prompt()):
		_names_part = {}
		_finish_embedded()

func _on_embed_names(text: String) -> void:
	_names_part = _parse_names_content(text)
	_finish_embedded()

func _finish_embedded() -> void:
	story = _story_part.duplicate()
	story["names"] = _names_part
	story_ready.emit(story)

# ---------------------------------------------------------------- HTTP (LM Studio)

func _generate_http() -> void:
	phase_changed.emit("Writing the story & naming the world…")
	_story_pending = true
	_names_pending = true
	if _send(_http_story, _story_prompt(), 900) != OK:
		_story_part = _fallback_story()
		_story_pending = false
	if _send(_http_names, _names_prompt(), 2600) != OK:
		_names_pending = false
	_maybe_emit()

func _send(http: HTTPRequest, prompt: String, max_tokens: int) -> int:
	var body := JSON.stringify({
		"model": Settings.llm_model,
		"messages": [{"role": "system", "content": SYS}, {"role": "user", "content": prompt}],
		"temperature": 0.9,
		"max_tokens": max_tokens,
		"stream": false,
	})
	var headers := ["Content-Type: application/json"]
	if Settings.llm_api_key != "":
		headers.append("Authorization: Bearer %s" % Settings.llm_api_key)
	return http.request(Settings.llm_endpoint, headers, HTTPClient.METHOD_POST, body)

func _on_story_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var d := {}
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		d = _parse_story(body.get_string_from_utf8())
	_story_part = d if not d.is_empty() else _fallback_story()
	_story_pending = false
	_maybe_emit()

func _on_names_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		_names_part = _parse_names(body.get_string_from_utf8())
	_names_pending = false
	_maybe_emit()

func _maybe_emit() -> void:
	if _story_pending or _names_pending:
		return
	story = _story_part.duplicate()
	story["names"] = _names_part
	story_ready.emit(story)

# ---------------------------------------------------------------- prompts

func _faction_list() -> String:
	var s := ""
	for f in _facts.get("factions", []):
		s += "- %s\n" % String(f)
	return s

func _story_prompt() -> String:
	return ("Theme: %s\nFactions:\n%sThe player completes survival quests for points (target %d).\n"
		+ "JSON keys: \"briefing\" (2-3 vivid sentences on this theme), "
		+ "\"factions\" (object: each faction name -> one-sentence backstory), "
		+ "\"greetings\" (object: each faction name -> a short in-character line an NPC says to the player), "
		+ "\"outro\" (one victory sentence). Stay on theme.") % [_theme, _faction_list(), int(_facts.get("points", 10))]

func _names_prompt() -> String:
	var per := int(_facts.get("names_per_faction", 16))
	return ("Theme: %s\nInvent %d distinct people for EACH faction below. Every person's "
		+ "name MUST fit the theme \"%s\" (its language, culture and style) — not generic English.\n"
		+ "Factions (use these EXACT strings as the keys):\n%s"
		+ "Respond with ONLY a JSON object mapping each faction name (exactly as written) to an "
		+ "array of objects {\"name\": a themed personal name, \"trait\": a 2-4 word persona}.") % [_theme, per, _theme, _faction_list()]

# ---------------------------------------------------------------- parsing

## Extract a JSON object from a raw string (tolerating prose / code fences / junk).
func _json_obj(content: String):
	content = content.strip_edges()
	var a := content.find("{")
	var b := content.rfind("}")
	if a < 0 or b <= a:
		return null
	return JSON.parse_string(content.substr(a, b - a + 1))

## Pull the message content out of an OpenAI-style chat reply.
func _envelope_content(txt: String) -> String:
	var outer = JSON.parse_string(txt)
	if typeof(outer) != TYPE_DICTIONARY:
		return ""
	var choices = outer.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty():
		return ""
	return String(choices[0].get("message", {}).get("content", ""))

func _parse_story_content(content: String) -> Dictionary:
	var inner = _json_obj(content)
	if typeof(inner) != TYPE_DICTIONARY:
		return {}
	return {
		"briefing": String(inner.get("briefing", "")),
		"factions": inner.get("factions", {}),
		"greetings": inner.get("greetings", {}),
		"outro": String(inner.get("outro", "")),
	}

func _parse_names_content(content: String) -> Dictionary:
	var inner = _json_obj(content)
	return inner if typeof(inner) == TYPE_DICTIONARY else {}

# HTTP variants (envelope -> content). Also used by the smoke test.
func _parse_story(txt: String) -> Dictionary:
	return _parse_story_content(_envelope_content(txt))

func _parse_names(txt: String) -> Dictionary:
	return _parse_names_content(_envelope_content(txt))

func _fallback_story() -> Dictionary:
	var t := _theme
	var factions := {}
	var greetings := {}
	for f in _facts.get("factions", []):
		var name := String(f)
		factions[name] = "%s endure in a world of %s, trusting few and arming many." % [name, t]
		greetings[name] = "Hard times for %s, stranger. State your business." % name
	return {
		"briefing": "The world has fallen to %s. Scattered settlements cling to survival while raiders prowl the wastes — earn your place, or perish." % t,
		"factions": factions,
		"greetings": greetings,
		"outro": "Against all odds, you carved out survival in a world of %s." % t,
	}
