extends Node
## Procedural NPC name generator (autoload "NameGen"). Names are drawn from per-
## faction pools using a seeded RNG so a given world seed always produces the same
## people (deterministic for co-op + saves). The host generates names at spawn and
## replicates them, so clients see identical names.

var _rng := RandomNumberGenerator.new()

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

func npc_name(faction: String) -> String:
	var pool: Dictionary = POOLS.get(faction, POOLS["raiders"])
	var firsts: Array = pool["first"]
	var lasts: Array = pool["last"]
	var f: String = String(firsts[_rng.randi() % firsts.size()])
	var l: String = String(lasts[_rng.randi() % lasts.size()])
	return "%s %s" % [f, l]
