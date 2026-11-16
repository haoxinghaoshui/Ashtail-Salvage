extends RefCounted
class_name Z1LootCatalog

const Items := preload("res://scripts/core/content/m3_item_catalog.gd")
const COLLECTIBLE_WEIGHTS := [35, 20, 30, 15, 35, 30, 20, 15, 35, 30, 22, 13, 8, 25, 45, 22, 35, 12, 20, 33, 45, 30, 18, 7]
const ITEM_WEIGHTS := {
	"con_ration": 60, "con_tape_roll": 40, "con_med_patch": 70, "con_scan_pin": 30,
	"eq_edge_opener": 60, "eq_goggles": 40,
	"mon_old_gear_set": 35, "mon_broken_patrol_badge": 20, "mon_overheated_core": 15,
	"mon_loader_black_box": 18, "mon_abnormal_instruction": 12,
	# One fifth of the T5 group, whose four existing entries total 100.
	"col_folded_price_board": 25,
}
# Each row is search T2, chest T4, mechanism T5, altar T4/T5/T6.
const HIGH_TIER_SHARES := [
	[0.15, 0.20, 0.15, 0.20, 0.15, 0.05],
	[0.25, 0.35, 0.25, 0.35, 0.30, 0.15],
	[0.35, 0.50, 0.40, 0.50, 0.45, 0.30],
	[0.45, 0.65, 0.55, 0.65, 0.60, 0.45],
]


static func distribution(table_id: StringName, difficulty: StringName, altar_stage: int = 1, adjacent_mines: int = -1) -> Array[Dictionary]:
	var difficulty_index := int({&"simple": 0, &"easy": 0, &"normal": 1, &"standard": 1, &"hard": 2, &"hell": 3}.get(difficulty, 1))
	var shares: Array = HIGH_TIER_SHARES[difficulty_index]
	var groups: Array = []
	match table_id:
		&"search":
			groups = [
				[_collectibles(1, 4), 0.70 * (1.0 - shares[0])],
				[_collectibles(5, 8), 0.70 * shares[0]],
				[["con_ration", "con_tape_roll"], 0.25], [["eq_insulated_sleeve"], 0.05],
			]
		&"chest":
			groups = [
				[_collectibles(9, 12), 0.70 * (1.0 - shares[1])],
				[_collectibles(13, 16), 0.70 * shares[1]],
				[["con_med_patch", "con_scan_pin"], 0.20], [["eq_edge_opener", "eq_goggles"], 0.10],
			]
		&"monster":
			groups = [
				[["mon_old_gear_set", "mon_broken_patrol_badge", "mon_overheated_core", "mon_loader_black_box", "mon_abnormal_instruction"], 0.65],
				[["con_stabilizer"], 0.25], [["eq_old_vest"], 0.10],
			]
		&"event":
			groups = [
				[_collectibles(13, 16), 0.70 * (1.0 - shares[2])],
				[_collectibles(17, 20), 0.70 * shares[2]],
				[["con_calm_candy"], 0.20], [["eq_signal_pin"], 0.10],
			]
		&"altar":
			match clampi(altar_stage, 1, 5):
				1:
					groups = [[["sp_altar_residue"], 0.70], [["eq_recovery_bag"], 0.30]]
				2:
					groups = [[_collectibles(9, 12), 1.0 - shares[3]], [_collectibles(13, 16), shares[3]]]
				3:
					groups = [[_collectibles(13, 16), 1.0 - shares[4]], [_collectibles(17, 20), shares[4]]]
				4:
					groups = [[_collectibles(17, 20), 1.0 - shares[5]], [_collectibles(21, 24), shares[5]]]
				5:
					groups = [[_collectibles(21, 24), 0.85], [["sp_altar_residue"], 0.10], [["eq_recovery_bag"], 0.05]]
	_include_supplies(groups, table_id, altar_stage, adjacent_mines)
	var result: Array[Dictionary] = []
	for group in groups:
		var total_weight := 0.0
		for item_id in group[0]:
			total_weight += _weight(item_id)
		for item_id in group[0]:
			result.append({"item_id": item_id, "probability": float(group[1]) * _weight(item_id) / total_weight})
	return result


static func roll(table_id: StringName, pos: Vector2i, seed_value: int, difficulty: StringName, count: int = 1, altar_stage: int = 1, adjacent_mines: int = -1) -> Array[Dictionary]:
	var probabilities := distribution(table_id, difficulty, altar_stage, adjacent_mines)
	var result: Array[Dictionary] = []
	if probabilities.is_empty():
		return result
	var random := RandomNumberGenerator.new()
	random.seed = ("z1:%s:%d:%d:%d:%d" % [table_id, pos.x, pos.y, seed_value, altar_stage]).hash()
	var definitions := {}
	for item in Items.all_items():
		definitions[str(item["item_id"])] = item
	for _index in range(maxi(1, count)):
		var ticket := random.randf()
		var chosen: String = probabilities.back()["item_id"]
		for entry in probabilities:
			ticket -= float(entry["probability"])
			if ticket < 0.0:
				chosen = entry["item_id"]
				break
		var item: Dictionary = definitions[chosen].duplicate(true)
		item["drop_table_id"] = table_id
		item["source"] = Items.source_for_table(table_id)
		item["reward_location"] = &"room_floor"
		result.append(item)
	return result


static func _collectibles(first: int, last: int) -> Array[String]:
	var ids: Array[String] = []
	for index in range(first, last + 1):
		ids.append("col_%02d" % index)
	return ids


static func _weight(item_id: String) -> float:
	if item_id.begins_with("col_") and item_id.trim_prefix("col_").is_valid_int():
		return float(COLLECTIBLE_WEIGHTS[int(item_id.trim_prefix("col_")) - 1])
	return float(ITEM_WEIGHTS.get(item_id, 100))


static func _include_supplies(groups: Array, table_id: StringName, altar_stage: int, adjacent_mines: int) -> void:
	# Add within existing groups so each source's category/tier probability stays intact.
	match table_id:
		&"search":
			groups[0][0].append("col_missing_shift_roster")
			groups[2][0].append_array(["con_ledger_seal_paper", "con_range_powder"])
			groups[3][0].append("eq_seam_finder_pendant")
			if adjacent_mines >= 0 and adjacent_mines < 2:
				groups[3][0].append("eq_debris_brow_guard")
		&"chest":
			groups[0][0].append("col_clockwork_copper_dial")
			groups[2][0].append_array(["con_cooling_patch", "sp_transit_lead_seal"])
			groups[3][0].append_array(["eq_buffer_buckle", "eq_pressure_relief_wrench", "eq_etched_sleeve"])
		&"monster":
			groups[0][0].append_array(["sp_reset_spring", "col_missing_tooth_counter"])
			groups[1][0].append("con_hard_shell_patch")
		&"event":
			groups[2][0].append_array(["con_salvage_seal", "con_hemostatic_clasp", "sp_depressurized_valve_core"])
			groups[3][0].append("eq_strapped_backplate")
		&"altar":
			if altar_stage == 3:
				groups[1][0].append("col_folded_price_board")
			elif altar_stage == 4:
				groups[0][0].append("col_folded_price_board")
