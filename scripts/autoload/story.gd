extends Node
## Survival story generator (autoload "Story"). Calls a LOCAL, OpenAI-compatible
## chat endpoint (LM Studio / Ollama / etc. — default http://localhost:1234) over
## HTTP to write the world's narrative from a player-entered theme. If the server
## is unreachable or returns junk, it falls back to a deterministic offline story so
## the game always has flavour. Host generates; the world replicates the result.
##
## Output dict: { "briefing": String, "factions": {name: String}, "greetings":
##               {name: String}, "outro": String }

signal story_ready(story: Dictionary)

var story: Dictionary = {}
var _http: HTTPRequest
var _theme: String = ""
var _facts: Dictionary = {}

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 60.0  # local models can be slow when also naming every NPC
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

## Kick off generation. Emits story_ready (possibly with the offline fallback).
func generate(theme: String, facts: Dictionary) -> void:
	_theme = theme.strip_edges()
	if _theme == "":
		_theme = "a harsh survival frontier"
	_facts = facts
	var body := JSON.stringify({
		"model": Settings.llm_model,
		"messages": [
			{"role": "system", "content": "You are a game narrative designer for a survival shooter. Respond with ONLY a compact JSON object, no markdown, no prose."},
			{"role": "user", "content": _build_prompt()},
		],
		"temperature": 0.9,
		"max_tokens": 3500,
		"stream": false,
	})
	var headers := ["Content-Type: application/json"]
	if Settings.llm_api_key != "":
		headers.append("Authorization: Bearer %s" % Settings.llm_api_key)
	var err := _http.request(Settings.llm_endpoint, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_finish(_fallback())

func _build_prompt() -> String:
	var fac_lines := ""
	for f in _facts.get("factions", []):
		fac_lines += "- %s\n" % String(f)
	var per := int(_facts.get("names_per_faction", 30))
	return ("Theme: %s\nFactions in this world:\n%sThe player earns points by completing survival quests (target %d).\n"
		+ "Write a JSON object with keys: \"briefing\" (2-3 vivid sentences setting the scene on this theme), "
		+ "\"factions\" (object mapping each faction name above to a one-sentence backstory), "
		+ "\"greetings\" (object mapping each faction name to a short in-character line an NPC of that faction says to the player), "
		+ "\"names\" (object mapping each faction name to an array of %d distinct people as objects {\"name\": on-theme person name, \"trait\": 2-4 word persona}), "
		+ "\"outro\" (one sentence shown when the player wins). Stay on theme. Output only JSON.") % [_theme, fac_lines, int(_facts.get("points", 10)), per]

func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish(_fallback())
		return
	var parsed := _parse(body.get_string_from_utf8())
	_finish(parsed if not parsed.is_empty() else _fallback())

## Parse an OpenAI-style chat response whose message content is our story JSON.
func _parse(txt: String) -> Dictionary:
	var outer = JSON.parse_string(txt)
	if typeof(outer) != TYPE_DICTIONARY:
		return {}
	var choices = outer.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty():
		return {}
	var content := String(choices[0].get("message", {}).get("content", ""))
	content = content.strip_edges()
	# Tolerate markdown code fences around the JSON.
	if content.begins_with("```"):
		content = content.trim_prefix("```json").trim_prefix("```").trim_suffix("```").strip_edges()
	var inner = JSON.parse_string(content)
	if typeof(inner) != TYPE_DICTIONARY:
		return {}
	return {
		"briefing": String(inner.get("briefing", "")),
		"factions": inner.get("factions", {}),
		"greetings": inner.get("greetings", {}),
		"names": inner.get("names", {}),
		"outro": String(inner.get("outro", "")),
	}

## Deterministic offline story (used when no local LLM is reachable).
func _fallback() -> Dictionary:
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

func _finish(s: Dictionary) -> void:
	story = s
	story_ready.emit(s)
