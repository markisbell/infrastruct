class_name WorldModel
extends RefCounted
## Logical world model — single source of truth (ADR-002).
## TileMapLayers are views of this model, never the model itself.
## Pure data + (de)serialization: must stay free of any scene/node dependency
## so it can be unit-tested headless.

const SCHEMA_VERSION := 1

## Vector2i -> int (cable kind). Spike A only knows one network: power cables.
var cables: Dictionary = {}


func set_cable(pos: Vector2i, kind: int) -> void:
	cables[pos] = kind


func remove_cable(pos: Vector2i) -> void:
	cables.erase(pos)


func has_cable(pos: Vector2i) -> bool:
	return cables.has(pos)


func to_json() -> String:
	var out := {}
	for k: Vector2i in cables:
		out["%d,%d" % [k.x, k.y]] = cables[k]
	return JSON.stringify({"version": SCHEMA_VERSION, "cables": out})


static func from_json(text: String) -> WorldModel:
	var model := WorldModel.new()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		push_error("WorldModel.from_json: invalid JSON")
		return model
	var dict: Dictionary = parsed
	var cable_dict: Dictionary = dict.get("cables", {})
	for key: String in cable_dict:
		var parts := key.split(",")
		if parts.size() != 2:
			continue
		model.cables[Vector2i(int(parts[0]), int(parts[1]))] = int(cable_dict[key])
	return model


func equals(other: WorldModel) -> bool:
	return cables == other.cables
