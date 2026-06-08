extends Node
## Procedural NPC name generator (autoload "NameGen"). Names are drawn from per-
## faction pools using a seeded RNG so a given world seed always produces the same
## people (deterministic for co-op + saves). The host generates names at spawn and
## replicates them, so clients see identical names.

var _rng := RandomNumberGenerator.new()
# LLM-generated people, per faction: Array of { "name": String, "trait": String }.
# Drawn in order so each NPC is unique; falls back to the built-in pools when empty.
var _pools: Dictionary = {}
var _idx: Dictionary = {}

const POOLS := {
	"Ridgeback Clan": {
		"first": ["Bjorn", "Kara", "Sten", "Inga", "Rurik", "Hilda", "Magnus", "Sigrid", "Torvald", "Greta"],
		"last": ["Ridge", "Stone", "Frost", "Bjornsson", "Highcliff", "Ironhand", "Stormborn", "Vale"],
	},
	"Verdant Pact": {
		"first": ["Fern", "Rowan", "Willow", "Aspen", "Linden", "Hazel", "Cedar", "Iris", "Briar", "Sage"],
		"last": ["Thorne", "Greenleaf", "Hollow", "Wilds", "Mossfoot", "Riversong", "Underwood", "Bramble"],
	},
	"Ashfall Brotherhood": {
		"first": ["Corvin", "Mara", "Ash", "Dren", "Vesna", "Kael", "Lse", "Soot", "Ember", "Nyx"],
		"last": ["Cinder", "Ashford", "Blackmoor", "Emberfall", "Grimsoul", "Char", "Duskbane", "Pyre"],
	},
	"raiders": {
		"first": ["Scar", "Vex", "Grim", "Razor", "Tusk", "Snake", "Bones", "Crank", "Mauler", "Skiv"],
		"last": ["the Hound", "Two-Tooth", "the Cleaver", "Half-Ear", "the Mad", "Ironjaw", "the Quick", "Bloodnail"],
	},
}

func reseed(s: int) -> void:
	_rng.seed = s

func _key(s: String) -> String:
	return s.strip_edges().to_lower()

## Install LLM-generated people pools: { faction: [ {name, trait}, ... ] }. Keys are
## normalised (case-insensitive) so e.g. "Raiders" still matches the "raiders" faction.
func set_pools(pools: Dictionary) -> void:
	_pools = {}
	_idx = {}
	for fac in pools:
		var arr: Array = []
		if typeof(pools[fac]) == TYPE_ARRAY:
			for e in pools[fac]:
				if typeof(e) == TYPE_DICTIONARY and e.has("name"):
					arr.append({"name": String(e["name"]), "trait": String(e.get("trait", ""))})
				elif typeof(e) == TYPE_STRING:
					arr.append({"name": String(e), "trait": ""})
		if not arr.is_empty():
			_pools[_key(String(fac))] = arr

func clear_pools() -> void:
	_pools = {}
	_idx = {}

## A unique person for a faction: LLM-generated if a pool entry remains, else a
## procedurally-built name with no persona.
func npc_person(faction: String) -> Dictionary:
	var k := _key(faction)
	var pool: Array = _pools.get(k, [])
	var i: int = int(_idx.get(k, 0))
	if i < pool.size():
		_idx[k] = i + 1
		return pool[i]
	return {"name": npc_name(faction), "trait": ""}

func npc_name(faction: String) -> String:
	var pool: Dictionary = POOLS.get(faction, POOLS["raiders"])
	var firsts: Array = pool["first"]
	var lasts: Array = pool["last"]
	var f: String = String(firsts[_rng.randi() % firsts.size()])
	var l: String = String(lasts[_rng.randi() % lasts.size()])
	return "%s %s" % [f, l]
