extends Node
## Survival story generator (autoload "Story"). Calls a LOCAL, OpenAI-compatible
## chat endpoint (LM Studio / Ollama, default http://localhost:1234) to write the
## world's narrative AND name the NPCs from a player-entered theme.
##
## The story and the (large) name lists are fetched in TWO separate requests, so a
## truncated/failed names reply can't break the briefing, and neither response is
## overloaded. Anything unreachable or malformed falls back to a deterministic
## offline story / the procedural name pools.
##
## Output dict: { briefing, factions{name:lore}, greetings{name:line},
##               names{faction:[{name,trait}]}, outro }

signal story_ready(story: Dictionary)

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
		"messages": [
			{"role": "system", "content": "You write game content. Respond with ONLY a compact JSON object, no markdown, no prose."},
			{"role": "user", "content": prompt},
		],
		"temperature": 0.9,
		"max_tokens": max_tokens,
		"stream": false,
	})
	var headers := ["Content-Type: application/json"]
	if Settings.llm_api_key != "":
		headers.append("Authorization: Bearer %s" % Settings.llm_api_key)
	return http.request(Settings.llm_endpoint, headers, HTTPClient.METHOD_POST, body)

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
	return ("Theme: %s\nFor each faction below, invent %d distinct on-theme people.\nFactions:\n%s"
		+ "Respond with ONLY a JSON object mapping each faction name to an array of "
		+ "objects {\"name\": a person's name fitting the theme, \"trait\": a 2-4 word persona}.") % [_theme, per, _faction_list()]

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

# ---------------------------------------------------------------- parsing

## Pull the message content out of an OpenAI-style reply, then the JSON object/array
## out of that content (tolerating prose / code fences / truncation noise).
func _content_json(txt: String, open_ch: String, close_ch: String):
	var outer = JSON.parse_string(txt)
	if typeof(outer) != TYPE_DICTIONARY:
		return null
	var choices = outer.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty():
		return null
	var content := String(choices[0].get("message", {}).get("content", "")).strip_edges()
	var a := content.find(open_ch)
	var b := content.rfind(close_ch)
	if a < 0 or b <= a:
		return null
	return JSON.parse_string(content.substr(a, b - a + 1))

func _parse_story(txt: String) -> Dictionary:
	var inner = _content_json(txt, "{", "}")
	if typeof(inner) != TYPE_DICTIONARY:
		return {}
	return {
		"briefing": String(inner.get("briefing", "")),
		"factions": inner.get("factions", {}),
		"greetings": inner.get("greetings", {}),
		"outro": String(inner.get("outro", "")),
	}

func _parse_names(txt: String) -> Dictionary:
	var inner = _content_json(txt, "{", "}")
	return inner if typeof(inner) == TYPE_DICTIONARY else {}

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
