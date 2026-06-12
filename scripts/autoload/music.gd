extends Node
## Adaptive music: a calm exploration bed and a tense combat layer, always both
## playing but crossfaded by set_combat(). Routed to its own bus under Master so it
## sits below SFX. Call start()/stop() around a match.

var _calm: AudioStreamPlayer = null
var _combat: AudioStreamPlayer = null
var _combat_amt: float = 0.0      # 0 calm .. 1 combat (smoothed)
var _target: float = 0.0
var _bus := "Master"
var _on: bool = false

const CALM_DB := -16.0
const COMBAT_DB := -12.0

func _ready() -> void:
	_setup_bus()
	_calm = _make_player("res://assets/audio/music_calm.wav")
	_combat = _make_player("res://assets/audio/music_combat.wav")
	set_process(true)

func _setup_bus() -> void:
	var idx := AudioServer.get_bus_count()
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Music")
	AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, -3.0)
	_bus = "Music"

func _make_player(path: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var st = load(path) if ResourceLoader.exists(path) else null
	if st is AudioStreamWAV:
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_end = st.data.size() / 2   # 16-bit mono frames
	p.stream = st
	p.bus = _bus
	p.volume_db = -80.0
	add_child(p)
	return p

## Begin playing the adaptive score (call when a match starts).
func start() -> void:
	if _on:
		return
	_on = true
	if _calm.stream:
		_calm.play()
	if _combat.stream:
		_combat.play()

func stop() -> void:
	_on = false
	_calm.stop()
	_combat.stop()

## Drive the calm<->combat blend. Pass true while enemies are engaging the player.
func set_combat(active: bool) -> void:
	_target = 1.0 if active else 0.0

func _process(delta: float) -> void:
	if not _on:
		return
	_combat_amt = lerpf(_combat_amt, _target, clampf((2.5 if _target > _combat_amt else 1.0) * delta, 0.0, 1.0))
	# Equal-ish power crossfade between the two beds.
	_calm.volume_db = lerpf(-80.0, CALM_DB, clampf(1.0 - _combat_amt, 0.0, 1.0))
	_combat.volume_db = lerpf(-80.0, COMBAT_DB, clampf(_combat_amt, 0.0, 1.0))
