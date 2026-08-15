class_name ToolPipette
extends RefCounted
## Pipette ("pick tool"): point at something already in the world and get
## back the tool that builds it — Minecraft's middle-click pick-block,
## Factorio's Q. In a network builder this is the highest-frequency tool
## change there is: extending a run you can SEE beats recalling which
## palette category its tool lives in.
##
## It carries the VARIANT, which is the whole point: overhead vs buried
## cable, surface vs buried pipe, a solar park's facing. Those are exactly
## the distinctions a player cannot read off the palette and often cannot
## read off the map either (a buried run under a road is a manhole plate).
##
## Pure and static: every branch is a plain WorldModel lookup, so the whole
## mapping is unit-testable without a viewport or a camera.

## Probe order, most-specific first. Deliberate choices worth knowing:
##
## - LINES OUTRANK ROADS. A buried line and a road share a tile (buried
##   runs cross under streets), and the buried run is the thing whose kind
##   you cannot see — which is precisely what the pipette is for. Roads
##   stay one keypress away.
## - CABLE > HEAT > WATER where buried runs share a street cross-section,
##   matching palette order.
## - A HOUSE answers with the zone tool that made its lot buildable, and a
##   commercial lot with the commercial zone. Neither is placed by hand,
##   but "more of this district" is what the player is pointing at.
static func sample(model: WorldModel, pos: Vector2i) -> Dictionary:
	var building_id: String = model.building_tiles.get(pos, "")
	if building_id != "":
		return _building_sample(model, building_id)
	if model.cables.has(pos):
		return _line_sample(int(model.cables[pos]),
			CityView.Tool.CABLE, CityView.Tool.UCABLE)
	if model.heat_pipes.has(pos):
		return _line_sample(int(model.heat_pipes[pos]),
			CityView.Tool.PIPE, CityView.Tool.BURIED_PIPE)
	if model.water_pipes.has(pos):
		return _line_sample(int(model.water_pipes[pos]),
			CityView.Tool.WATER_PIPE, CityView.Tool.BURIED_WATER)
	if model.commercial.has(pos):
		return _plain(CityView.Tool.ZONE_COMMERCIAL)
	if model.houses.has(pos):
		return _plain(CityView.Tool.ZONE)
	if model.zoning.has(pos):
		return _plain(CityView.Tool.ZONE_COMMERCIAL \
			if int(model.zoning[pos]) == WorldModel.ZONE_COMMERCIAL \
			else CityView.Tool.ZONE)
	if model.roads.has(pos):
		return _plain(CityView.Tool.ROAD)
	return {}


## A placed building answers with its tool AND its placement transform —
## a pipette that drops rotation is half a pipette (solar-park `rot` is
## load-bearing: it decides the facing, and with it the yield curve).
static func _building_sample(model: WorldModel, id: String) -> Dictionary:
	var entry: Dictionary = model.buildings.get(id, {})
	var kind: String = entry.get("kind", "")
	for tool: CityView.Tool in CityView.TOOL_BUILDING:
		if CityView.TOOL_BUILDING[tool] == kind:
			return {"tool": tool, "rot": int(entry.get("rot", 0)),
				"flip": bool(entry.get("flip", false))}
	return {}  # a kind with no tool (nothing today) picks up nothing


static func _line_sample(kind: int, surface: CityView.Tool,
		buried: CityView.Tool) -> Dictionary:
	return _plain(buried if kind == BuildingDefs.LINE_UNDERGROUND else surface)


static func _plain(tool: CityView.Tool) -> Dictionary:
	return {"tool": tool, "rot": 0, "flip": false}
