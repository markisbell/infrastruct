class_name GrowthModel
extends RefCounted
## Growth v2 decision rules (Phase-2 extraction from City): the happiness
## interval tiers, the spare-margin gate, and abandonment victim selection.
## City keeps the orchestration (spawn attempts, topology refresh, events).

const GROWTH_HAPPINESS_MIN := 60.0
const ABANDON_HAPPINESS := 35.0
const ABANDON_INTERVAL := 16      # one household leaves every 4 game-hours
const MARGIN_LINE_MAX := 95.0     # any line above this blocks move-ins
const MARGIN_GRID_FRAC := 0.85    # slack import fraction that blocks move-ins


## Steps between spawns: 4/8/16 by happiness tier, 0 below the minimum;
## difficulty scales it (easy towns grow faster), never below 1.
static func growth_interval(happiness: float, growth_scale: float) -> int:
	var interval := 4 if happiness >= 90.0 \
		else (8 if happiness >= 75.0 \
		else (16 if happiness >= GROWTH_HAPPINESS_MIN else 0))
	if interval > 0:
		interval = maxi(1, int(interval / growth_scale))
	return interval


## Spare-margin gate: nobody moves into a town running at its limits.
## (Power margin — houses hang off power zones; heat/water shortfalls
## already gate growth through happiness.)
static func margin_ok(result: Dictionary, grid_capacity_kw: float,
		slack_id: String) -> bool:
	if result.get("status", "") == "failed":
		return false
	for edge_id: String in result.get("edges", {}):
		if float(result["edges"][edge_id].get("loading_percent", 0.0)) \
				> MARGIN_LINE_MAX:
			return false
	if slack_id != "":
		var import_kw := float(result.get("devices", {})
			.get(slack_id, {}).get("output_kw", 0.0))
		if import_kw > MARGIN_GRID_FRAC * grid_capacity_kw:
			return false
	return true


## The household that leaves: from the zone with the worst outage record
## first, else the deterministic first of the sorted list.
static func abandon_victim(sorted_houses: Array, house_zone: Dictionary,
		outage_minutes: Dictionary) -> Vector2i:
	var victim: Vector2i = sorted_houses[0]
	var worst_zone := ""
	var worst := -1
	for zone_id: String in outage_minutes:
		if int(outage_minutes[zone_id]) > worst:
			worst = int(outage_minutes[zone_id])
			worst_zone = zone_id
	if worst_zone != "":
		for pos: Vector2i in sorted_houses:
			if house_zone.get(pos, "") == worst_zone:
				return pos
	return victim
