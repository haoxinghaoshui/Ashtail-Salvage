extends RefCounted
class_name Z1MonsterVisualCatalog

const MonsterCatalog := preload("res://scripts/gameplay/combat/z1_monster_catalog.gd")
const TextureCache := preload("res://scripts/presentation/runtime_texture_cache.gd")
const ASSET_ROOT := "res://assets/z1/monsters/"


static func supports(subject: StringName) -> bool:
	return MonsterCatalog.supports(subject)


static func texture_path(subject: StringName, runtime_state: StringName, frame_index: int = 0, _visual_variant: StringName = &"base") -> String:
	if not supports(subject):
		return ""
	var directory := ASSET_ROOT + String(subject).trim_prefix("z1_monster_") + "/"
	match runtime_state:
		&"dead", &"defeated":
			return directory + "dead_%d.png" % clampi(frame_index, 0, 4)
		&"hurt":
			return directory + "hurt.png"
		&"warning", &"aim":
			return directory + "warning.png"
		&"active", &"fire":
			return directory + "attack.png"
	return directory + "idle_%d.png" % posmod(frame_index, 2)


static func texture_for(subject: StringName, runtime_state: StringName, frame_index: int = 0, visual_variant: StringName = &"base") -> Texture2D:
	return TextureCache.texture(texture_path(subject, runtime_state, frame_index, visual_variant))


static func frame_count(subject: StringName, runtime_state: StringName, _visual_variant: StringName = &"base") -> int:
	if not supports(subject):
		return 0
	if runtime_state in [&"dead", &"defeated"]:
		return 5
	if runtime_state in [&"warning", &"aim", &"active", &"fire", &"hurt"]:
		return 1
	return 2


static func frame_duration(runtime_state: StringName) -> float:
	if runtime_state in [&"dead", &"defeated"]:
		return 0.09
	if runtime_state in [&"warning", &"aim", &"active", &"fire"]:
		return 0.11
	return 0.14


static func loops(runtime_state: StringName) -> bool:
	return runtime_state not in [&"dead", &"defeated"]


static func reduced_motion_frame(_subject: StringName, runtime_state: StringName, _visual_variant: StringName = &"base") -> int:
	return 4 if runtime_state in [&"dead", &"defeated"] else 0


static func visual_scale(subject: StringName, _visual_variant: StringName = &"base") -> float:
	match StringName(MonsterCatalog.definition(subject).get("base_type", &"")):
		&"bat": return 0.40
		&"drone": return 0.45
	return 0.44


static func visual_offset(subject: StringName) -> Vector2:
	var airborne := StringName(MonsterCatalog.definition(subject).get("base_type", &"")) == &"bat" or subject == &"z1_monster_m12"
	var hover := 12.0 if airborne else 0.0
	return Vector2(0, 4.0 - 48.0 * visual_scale(subject) - hover)


static func health_bar_y(subject: StringName) -> float:
	return visual_offset(subject).y - 34.0


static func production_texture_paths() -> Array[String]:
	var result: Array[String] = []
	for subject in MonsterCatalog.all_runtime_types():
		for state: StringName in [&"idle", &"warning", &"active", &"hurt", &"dead"]:
			for frame_index in range(frame_count(subject, state)):
				result.append(texture_path(subject, state, frame_index))
	return result
