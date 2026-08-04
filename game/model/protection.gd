class_name ProtectionSystem
extends RefCounted
## Overload protection (Phase-2 extraction from City): sustained SOLVED
## loading above the threshold trips lines/transformers/the grid slack.
## Owns the consecutive-step streak counters and the trip decisions; the
## caller applies consequences (tile trips, zone darkening, event log).
## Trips DON'T self-heal — that pressure is the game design.

const TRIP_THRESHOLD := 120.0     # percent loading, STRICTLY above
const TRIP_STREAK := 3            # consecutive critical steps (lines)
const TRAFO_TRIP_STREAK := 4      # 1 h of solved trafo loading above 120 %
const GRID_TRIP_STREAK := 2       # consecutive capacity busts at the slack

var line_streak := {}
var trafo_streak := {}
var slack_streak := 0


## Line rule: >120 % for TRIP_STREAK consecutive steps trips the branch —
## but only edges the topology knows tiles for (known_lines); a matured
## streak on an unknown edge keeps counting instead of tripping blind.
## Returns [{edge_id, loading}] for branches to disconnect.
func line_trips(edges: Dictionary, known_lines: Dictionary) -> Array[Dictionary]:
	var trips: Array[Dictionary] = []
	for edge_id: String in edges:
		var loading := float(edges[edge_id].get("loading_percent", 0.0))
		if loading > TRIP_THRESHOLD:
			line_streak[edge_id] = int(line_streak.get(edge_id, 0)) + 1
			if line_streak[edge_id] >= TRIP_STREAK and known_lines.has(edge_id):
				line_streak.erase(edge_id)
				trips.append({"edge_id": edge_id, "loading": loading})
		else:
			line_streak.erase(edge_id)
	return trips


## Transformer rule: same criticality on the solved T-edges, longer streak;
## substations already tripped are skipped entirely (no streak bookkeeping).
## Returns [{sub_id, loading}].
func trafo_trips(edges: Dictionary, trafo_subs: Dictionary,
		already_tripped: Dictionary) -> Array[Dictionary]:
	var trips: Array[Dictionary] = []
	for edge_id: String in trafo_subs:
		var sub_id: String = trafo_subs[edge_id]
		if already_tripped.has(sub_id):
			continue
		var loading := float(edges.get(edge_id, {}).get("loading_percent", 0.0))
		if loading > TRIP_THRESHOLD:
			trafo_streak[sub_id] = int(trafo_streak.get(sub_id, 0)) + 1
			if trafo_streak[sub_id] >= TRAFO_TRIP_STREAK:
				trafo_streak.erase(sub_id)
				trips.append({"sub_id": sub_id, "loading": loading})
		else:
			trafo_streak.erase(sub_id)
	return trips


## Grid rule: total import above the combined station capacity for
## GRID_TRIP_STREAK steps trips city-wide — unless a trip is already
## active (can_trip false), in which case the streak keeps standing so
## the next eligible step re-trips immediately.
func grid_trip(import_kw: float, capacity_kw: float, can_trip: bool) -> bool:
	if import_kw > capacity_kw:
		slack_streak += 1
		if slack_streak >= GRID_TRIP_STREAK and can_trip:
			slack_streak = 0
			return true
	else:
		slack_streak = 0
	return false


func reset() -> void:
	line_streak.clear()
	trafo_streak.clear()
	slack_streak = 0
