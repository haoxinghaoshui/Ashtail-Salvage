extends RefCounted
## A run-owned arsenal. The combat simulator still owns every attack and hit.

const AXE := &"axe"
const RIFLE := &"rifle"
const SCATTER := &"scattergun"
const INITIAL_RESERVE := 24
const PROFILES := {
	RIFLE: {"name": "回收卡宾枪", "range": 0.59, "magazine": 6, "reload": 0.88, "cooldown": 0.48, "power": 1.00, "rays": [0.0]},
	SCATTER: {"name": "岩盐霰弹枪", "range": 0.41, "magazine": 3, "reload": 1.21, "cooldown": 0.76, "power": 0.44, "rays": [-0.16, -0.08, 0.0, 0.08, 0.16]},
}


static func initial_state() -> Dictionary:
	return {"selected": AXE, "reserve": INITIAL_RESERVE, "magazines": {String(RIFLE): 6, String(SCATTER): 3}, "reload": 0.0}


static func valid(state: Variant) -> bool:
	if not state is Dictionary or state.size() != 4:
		return false
	if not valid_weapon(state.get("selected")):
		return false
	var reserve = state.get("reserve")
	var reload = state.get("reload")
	var magazines = state.get("magazines")
	if not reserve is int or reserve < 0 or not reload is float or not is_finite(reload) or reload < 0.0:
		return false
	if not magazines is Dictionary or magazines.size() != PROFILES.size():
		return false
	for weapon in PROFILES:
		var rounds = magazines.get(String(weapon))
		if not rounds is int or rounds < 0 or rounds > int(PROFILES[weapon]["magazine"]):
			return false
	return true


static func valid_weapon(weapon: Variant) -> bool:
	return (weapon is String or weapon is StringName) and StringName(weapon) in [AXE, RIFLE, SCATTER]
