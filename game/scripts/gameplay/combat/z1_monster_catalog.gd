extends RefCounted
class_name Z1MonsterCatalog

const DEFINITIONS := {
	&"z1_monster_m01": {"source_id": "M01", "display_name": "余振史莱姆", "base_type": &"slime", "behavior_id": &"aftershock", "base_hp": 72, "hp_multiplier": 0.9, "sample_hp": 90},
	&"z1_monster_m02": {"source_id": "M02", "display_name": "回丝蝙蝠", "base_type": &"bat", "behavior_id": &"return_projectile", "base_hp": 48, "hp_multiplier": 1.0, "sample_hp": 76},
	&"z1_monster_m03": {"source_id": "M03", "display_name": "卡轨巡检机", "base_type": &"drone", "behavior_id": &"rail_charge", "base_hp": 112, "hp_multiplier": 0.85, "sample_hp": 119},
	&"z1_monster_m04": {"source_id": "M04", "display_name": "闸门工偶", "base_type": &"drone", "behavior_id": &"directional_guard", "base_hp": 112, "hp_multiplier": 0.75, "sample_hp": 105},
	&"z1_monster_m05": {"source_id": "M05", "display_name": "错页归档台", "base_type": &"drone", "behavior_id": &"delayed_archive", "base_hp": 112, "hp_multiplier": 0.85, "sample_hp": 119},
	&"z1_monster_m06": {"source_id": "M06", "display_name": "反冲校验秤", "base_type": &"drone", "behavior_id": &"hit_counter", "base_hp": 112, "hp_multiplier": 0.8, "sample_hp": 112},
	&"z1_monster_m07": {"source_id": "M07", "display_name": "四路配电桩", "base_type": &"drone", "behavior_id": &"four_way_laser", "base_hp": 112, "hp_multiplier": 1.0, "sample_hp": 140},
	&"z1_monster_m08": {"source_id": "M08", "display_name": "磁拖回收机", "base_type": &"slime", "behavior_id": &"magnetic_pull", "base_hp": 72, "hp_multiplier": 1.1, "sample_hp": 110},
	&"z1_monster_m09": {"source_id": "M09", "display_name": "记责广播箱", "base_type": &"slime", "behavior_id": &"pressure_pulse", "base_hp": 72, "hp_multiplier": 0.8, "sample_hp": 80},
	&"z1_monster_m10": {"source_id": "M10", "display_name": "回插急修工", "base_type": &"drone", "behavior_id": &"socket_repair", "base_hp": 112, "hp_multiplier": 0.8, "sample_hp": 112},
	&"z1_monster_m11": {"source_id": "M11", "display_name": "逆送带轮", "base_type": &"bat", "behavior_id": &"conveyor", "base_hp": 48, "hp_multiplier": 1.1, "sample_hp": 84},
	&"z1_monster_m12": {"source_id": "M12", "display_name": "吊柜索机", "base_type": &"drone", "behavior_id": &"live_cable", "base_hp": 112, "hp_multiplier": 0.9, "sample_hp": 126},
	&"z1_monster_m13": {"source_id": "M13", "display_name": "贴壁栖团", "base_type": &"slime", "behavior_id": &"marked_jump", "base_hp": 72, "hp_multiplier": 1.0, "sample_hp": 100},
	&"z1_monster_m14": {"source_id": "M14", "display_name": "漏光倒影", "base_type": &"bat", "behavior_id": &"attack_echo", "base_hp": 48, "hp_multiplier": 1.2, "sample_hp": 91},
}


static func supports(monster_type: StringName) -> bool:
	return DEFINITIONS.has(monster_type)


static func definition(monster_type: StringName) -> Dictionary:
	if not supports(monster_type):
		return {}
	var result: Dictionary = DEFINITIONS[monster_type].duplicate(true)
	result["monster_type"] = monster_type
	result["visual_key"] = StringName("z1.monster.%s" % String(result["source_id"]).to_lower())
	result["max_hp"] = int(result["sample_hp"])
	match result["behavior_id"]:
		&"rail_charge":
			result.merge({"warning_seconds": 0.60, "active_seconds": 0.50, "cooldown_seconds": 1.0, "charge_speed": 0.90}, true)
		&"directional_guard":
			result.merge({"warning_seconds": 0.75, "active_seconds": 0.28, "cooldown_seconds": 0.55, "attack_radius": 0.20, "guard_multiplier": 0.25}, true)
		&"delayed_archive":
			result.merge({"warning_seconds": 0.65, "active_seconds": 0.20, "cooldown_seconds": 2.50}, true)
		&"hit_counter":
			result.merge({"warning_seconds": 0.50, "active_seconds": 0.28, "cooldown_seconds": 0.55, "counter_window_seconds": 1.20}, true)
		&"four_way_laser", &"live_cable":
			result.merge({"warning_seconds": 0.50, "active_seconds": 1.20, "cooldown_seconds": 2.50}, true)
		&"magnetic_pull":
			result.merge({"warning_seconds": 0.75, "active_seconds": 1.0, "cooldown_seconds": 0.55, "attack_radius": 0.42}, true)
		&"pressure_pulse":
			result.merge({"warning_seconds": 0.50, "active_seconds": 0.12, "cooldown_seconds": 1.50}, true)
		&"marked_jump":
			result.merge({"warning_seconds": 0.60, "active_seconds": 0.25, "cooldown_seconds": 1.0, "attack_radius": 0.13}, true)
		&"attack_echo":
			result.merge({"warning_seconds": 0.50, "active_seconds": 0.12, "cooldown_seconds": 0.55}, true)
	return result


static func all_runtime_types() -> Array[StringName]:
	var result: Array[StringName] = []
	for monster_type: StringName in DEFINITIONS:
		result.append(monster_type)
	return result


static func max_hp(monster_type: StringName, encounter_power: int) -> int:
	var entry := definition(monster_type)
	if entry.is_empty():
		return 0
	return maxi(1, int(round(
		(float(entry["base_hp"]) + float(maxi(0, encounter_power)) * 2.0)
		* float(entry["hp_multiplier"])
	)))
