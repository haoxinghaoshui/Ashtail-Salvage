extends RefCounted
class_name G41MonsterCatalog

const Z1Catalog := preload("res://scripts/gameplay/combat/z1_monster_catalog.gd")
const TYPE_SLIME := &"slime"
const TYPE_SLIMELING := &"slimeling"
const TYPE_BAT := &"bat"
const TYPE_DRONE := &"drone"
const ENTRY_GRACE_SECONDS := 0.45


static func definition(monster_type: StringName) -> Dictionary:
	if Z1Catalog.supports(monster_type):
		var extension := Z1Catalog.definition(monster_type)
		var result := definition(StringName(extension["base_type"]))
		result.merge(extension, true)
		return result
	match monster_type:
		TYPE_SLIME:
			return {
				"monster_type": TYPE_SLIME,
				"max_hp": 72,
				"move_speed": 0.18,
				"damage_multiplier": 1.30,
				"body_radius": 0.036,
				"attack_radius": 0.20,
				"idle_seconds": 1.10,
				"warning_seconds": 0.75,
				"active_seconds": 0.28,
				"cooldown_seconds": 0.55,
				"split_count": 2,
				"split_power_multiplier": 0.45,
			}
		TYPE_SLIMELING:
			return {
				"monster_type": TYPE_SLIMELING,
				"max_hp": 18,
				"move_speed": 0.30,
				"damage_multiplier": 0.60,
				"body_radius": 0.023,
				"attack_radius": 0.20,
				"idle_seconds": 1.10,
				"warning_seconds": 0.75,
				"active_seconds": 0.28,
				"cooldown_seconds": 0.55,
				"split_count": 0,
			}
		TYPE_BAT:
			return {
				"monster_type": TYPE_BAT,
				"max_hp": 48,
				"move_speed": 0.28,
				"damage_multiplier": 1.0,
				"body_radius": 0.038,
				"ideal_distance": 0.34,
				"aim_seconds": 0.50,
				"attack_interval": 1.50,
				"spread_count": 3,
				"spread_half_angle_degrees": 25.0,
			}
		TYPE_DRONE:
			return {
				"monster_type": TYPE_DRONE,
				"max_hp": 112,
				"move_speed": 0.10,
				"damage_multiplier": 1.50,
				"body_radius": 0.034,
				"ideal_distance": 0.50,
				"aim_seconds": 0.50,
				"attack_interval": 2.50,
				"laser_seconds": 1.20,
				"laser_tick_seconds": 0.30,
				"laser_turn_speed_degrees": 24.0,
				"dash_seconds": 0.50,
				"dash_speed_multiplier": 2.0,
			}
	return {}


static func default_encounter() -> Array[StringName]:
	return [TYPE_SLIME, TYPE_BAT, TYPE_DRONE]


static func all_runtime_types() -> Array[StringName]:
	var result: Array[StringName] = [TYPE_SLIME, TYPE_SLIMELING, TYPE_BAT, TYPE_DRONE]
	result.append_array(Z1Catalog.all_runtime_types())
	return result


static func base_damage(_player_power: int, monster_type: StringName) -> int:
	var multiplier := float(definition(monster_type).get("damage_multiplier", 1.0))
	return maxi(1, int(round(5.0 * multiplier)))


static func damage_for_power(enemy_power: int, monster_type: StringName) -> int:
	var damage_base := maxi(4, maxi(0, enemy_power) / 3)
	var multiplier := float(definition(monster_type).get("damage_multiplier", 1.0))
	return maxi(1, int(round(float(damage_base) * multiplier)))


static func runtime_profile(monster_type: StringName, enemy_power: int, enemy_name: String) -> Dictionary:
	var monster_definition := definition(monster_type)
	var clamped_power := maxi(0, enemy_power)
	var result := {
		"monster_type": monster_type,
		"enemy_name": enemy_name,
		"enemy_power": clamped_power,
		"max_hp": int(monster_definition.get("max_hp", 1)) + clamped_power * 2,
		"damage": damage_for_power(clamped_power, monster_type),
	}
	if Z1Catalog.supports(monster_type):
		result["max_hp"] = Z1Catalog.max_hp(monster_type, clamped_power)
		result["base_power"] = clamped_power
		result["enemy_name"] = String(monster_definition["display_name"])
	return result


static func pick_type_for_cell(run_seed: int, pos: Vector2i, _adjacent_mines: int = 0, include_z1: bool = true) -> StringName:
	var hash := ((run_seed & 0xffffffff) * 2654435761) & 0xffffffff
	hash = (hash ^ (((int(pos.x) & 0xffffffff) * 73856093) & 0xffffffff)) & 0xffffffff
	hash = (hash ^ (((int(pos.y) & 0xffffffff) * 19349663) & 0xffffffff)) & 0xffffffff
	var encounter_pool: Array[StringName] = [TYPE_SLIME, TYPE_BAT, TYPE_DRONE]
	if include_z1:
		encounter_pool.append_array(Z1Catalog.all_runtime_types())
	return encounter_pool[hash % encounter_pool.size()]
