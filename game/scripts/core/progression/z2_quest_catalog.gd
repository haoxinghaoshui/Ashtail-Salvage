extends RefCounted
class_name Z2QuestCatalog

const Catalog := preload("res://scripts/core/progression/z2_goals/goal_catalog.gd")

# Existing panels consume this projection of the single canonical catalog.
static func definitions(kind: String = "") -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for row in Catalog.definitions(kind):
		rows.append(_panel_definition(row))
	return rows

static func definition(id: String) -> Dictionary:
	var row := Catalog.definition(id)
	return {} if row.is_empty() else _panel_definition(row)

static func _panel_definition(row: Dictionary) -> Dictionary:
	var result := row.duplicate(true)
	result["description"] = row.condition
	result["target"] = row.milestones.back().target
	result["reward_steps"] = row.milestones.duplicate(true)
	result["reward"] = {"exp": 0, "gold": 0}
	result["tier"] = 1
	for step: Dictionary in row.milestones:
		result.reward.exp += int(step.reward.exp)
		result.reward.gold += int(step.reward.gold)
	return result
