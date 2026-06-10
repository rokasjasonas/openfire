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
var _emitted: bool = false

# How long to wait on the HTTP LLM (LM Studio) before giving up and using the offline
# story — so a server that isn't running doesn't hang the loading screen.
const HTTP_TIMEOUT := 10.0
const HTTP_WATCHDOG := 12.0

func _ready() -> void:
	_http_story = _make_http()
	_http_names = _make_http()
	_http_story.request_completed.connect(_on_story_done)
	_http_names.request_completed.connect(_on_names_done)

func _make_http() -> HTTPRequest:
	var h := HTTPRequest.new()
	h.timeout = HTTP_TIMEOUT
	add_child(h)
	return h

func generate(theme: String, facts: Dictionary) -> void:
	_theme = theme.strip_edges()
	if _theme == "":
		_theme = "a harsh survival frontier"
	_facts = facts
	_story_part = {}
	_names_part = {}
	_emitted = false
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
	if not _has_briefing(_story_part):
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
	_emit()

## Emit the finished story exactly once (guards against a late HTTP reply arriving
## after the watchdog already fired the fallback).
func _emit() -> void:
	if _emitted:
		return
	_emitted = true
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
	# Safety net: if the server is unreachable/slow, fall back so we never hang.
	get_tree().create_timer(HTTP_WATCHDOG).timeout.connect(_on_http_watchdog)
	_maybe_emit()

func _on_http_watchdog() -> void:
	if _emitted:
		return
	if _story_part.is_empty():
		_story_part = _fallback_story()
	_emit()

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
	_story_part = d if _has_briefing(d) else _fallback_story()
	_story_pending = false
	_maybe_emit()

## A parsed story is only "good" if the model actually wrote a briefing.
func _has_briefing(d: Dictionary) -> bool:
	return not d.is_empty() and String(d.get("briefing", "")).strip_edges() != ""

func _on_names_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		_names_part = _parse_names(body.get_string_from_utf8())
	_names_pending = false
	_maybe_emit()

func _maybe_emit() -> void:
	if _story_pending or _names_pending:
		return
	_emit()

# ---------------------------------------------------------------- prompts

func _faction_list() -> String:
	var s := ""
	for f in _facts.get("factions", []):
		s += "- %s\n" % String(f)
	return s

func _story_prompt() -> String:
	return ("You are writing the lore bible for a game world themed: \"%s\".\n%s"
		+ "Factions in this world:\n%s"
		+ "Make EVERY line unmistakably about \"%s\" — use its specific places, names, tone, creatures and tropes; never generic post-apocalypse filler.\n"
		+ "Respond with ONLY a compact JSON object (no prose, no markdown) with keys: "
		+ "\"briefing\" (2-3 vivid sentences setting the scene, grounded in this theme), "
		+ "\"factions\" (object mapping each faction name to a one-sentence backstory that fits the theme), "
		+ "\"greetings\" (object mapping each faction name to a short in-character greeting an NPC says to the player), "
		+ "\"outro\" (one triumphant victory sentence).") % [_theme, _hero_line(), _faction_list(), _theme]

## Optional hero context from the chosen character (name + backstory) for the LLM.
func _hero_line() -> String:
	var h: Dictionary = _facts.get("hero", {})
	var nm := String(h.get("name", "")).strip_edges()
	var bio := String(h.get("bio", "")).strip_edges()
	if nm == "" and bio == "":
		return ""
	var line := ("The player's character is %s" % nm) if nm != "" else "The player's character"
	if bio != "":
		line += ": %s" % bio
	return line + ". Weave them into the briefing.\n"

func _names_prompt() -> String:
	var per := int(_facts.get("names_per_faction", 16))
	return ("Theme: %s\nInvent %d distinct people for EACH faction below. Every person's "
		+ "name MUST fit the theme \"%s\" (its language, culture and style) — not generic English.\n"
		+ "Factions (use these EXACT strings as the keys):\n%s"
		+ "Respond with ONLY a JSON object mapping each faction name (exactly as written) to an "
		+ "array of objects {\"name\": a themed personal name, \"trait\": a 2-4 word persona}.") % [_theme, per, _theme, _faction_list()]

# ---------------------------------------------------------------- parsing

## Extract a JSON object from a raw string, tolerating prose, code fences, trailing
## commas and a truncated tail (small models often produce all of these).
func _json_obj(content: String):
	content = content.strip_edges().replace("```json", "").replace("```", "")
	var a := content.find("{")
	if a < 0:
		return null
	var b := content.rfind("}")
	var s := content.substr(a, b - a + 1) if b > a else content.substr(a) + "}"
	var parsed = JSON.parse_string(s)
	if parsed == null:
		parsed = JSON.parse_string(_strip_trailing_commas(s))   # lenient retry
	return parsed

func _strip_trailing_commas(s: String) -> String:
	var re := RegEx.new()
	re.compile(",\\s*([}\\]])")
	return re.sub(s, "$1", true)

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

## Procedural fallback used when no LLM is reachable (or it returns nothing usable).
## Weaves the theme and the chosen character into the text so it still feels on-prompt.
func _fallback_story() -> Dictionary:
	var t := _theme
	var hero := String((_facts.get("hero", {}) as Dictionary).get("name", "")).strip_edges()
	var you := hero if hero != "" else "stranger"
	var factions := {}
	var greetings := {}
	for f in _facts.get("factions", []):
		var name := String(f)
		factions[name] = "The %s have carved out their corner of %s, wary of outsiders and quick to arm." % [name, t]
		greetings[name] = "You're far from safe ground, %s. State your business — this is %s." % [you, t]
	var lead := ("%s arrives in %s" % [hero, t]) if hero != "" else ("You arrive in %s" % t)
	return {
		"briefing": "%s — a land of scattered settlements, prowling raiders and few you can trust. Earn your place here, or be swallowed by it." % lead,
		"factions": factions,
		"greetings": greetings,
		"outro": "Against all odds, %s carved out a legend in %s." % [you, t],
	}
