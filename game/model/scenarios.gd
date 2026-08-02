class_name Scenarios
extends RefCounted
## Scenario system (ROADMAP Phase 7 task 3): hand-authored starts with
## win/lose conditions evaluated daily, plus the tutorial step chain.
## Pure data + predicates over the City autoload — the runner lives in the
## main scene, the picker in the HUD.

const DIFFICULTY := {
	"easy": {"growth_scale": 1.5, "event_scale": 0.5, "money_scale": 1.5},
	"normal": {"growth_scale": 1.0, "event_scale": 1.0, "money_scale": 1.0},
	"hard": {"growth_scale": 0.7, "event_scale": 1.6, "money_scale": 0.7},
}

## Sustained-condition windows (game-days) — kept short enough that a
## failing city fails visibly within a session.
const WIN_SUSTAIN_DAYS := 14
const LOSE_SUSTAIN_DAYS := 7
const BANKRUPT_EUR := -50_000


static func catalog() -> Array[Dictionary]:
	return [
		{"id": "sandbox", "name": "Sandbox",
			"desc": "No goals, no bankruptcy — just the three networks and you."},
		{"id": "sandbox_kraichgau", "name": "Sandbox — Kraichgau",
			"desc": "Sandbox on REAL rolling hills (SRTM elevation, 6.4 km of Kraichgau)."},
		{"id": "sandbox_schwarzwald", "name": "Sandbox — Schwarzwald",
			"desc": "Sandbox in REAL small mountains (SRTM, a northern Black Forest valley — mind the cliffs)."},
		{"id": "tutorial", "name": "Tutorial",
			"desc": "Learn the three networks one at a time: power, heat, water."},
		{"id": "greenfield", "name": "Greenfield",
			"desc": "Empty land. Grow a happy 25-house town on all three networks within two years."},
		{"id": "brownfield", "name": "Inherited grid",
			"desc": "A 20-kW relic of a grid connection and a sagging feeder. Build local supply before the town gives up on you."},
		{"id": "transition", "name": "Energy transition",
			"desc": "Retire the old fossil plant within two years — without blackouts."},
	]


## Applies start money/difficulty and pre-builds the world. Runner state
## (deadline, sustain counters) comes back to the caller.
static func start(id: String, difficulty_key: String) -> Dictionary:
	var diff: Dictionary = DIFFICULTY[difficulty_key]
	City.reset_for_scenario(42)
	City.difficulty = diff.duplicate()
	City.events_enabled = id != "tutorial"  # tutorial stays predictable
	# prebuilds run on the reset's deep pockets; the scenario's start
	# budget lands AFTER (the inherited town wasn't paid for by the player)
	var start_money := 500_000
	match id:
		"sandbox":
			City.model.terrain.set_seed(19)
			City.infinite_money = true  # no goals, no budget — just build
		"sandbox_kraichgau", "sandbox_schwarzwald":
			City.model.terrain.set_seed(19)  # rivers still ride the noise
			City.model.terrain.load_region(id.trim_prefix("sandbox_"))
			City.infinite_money = true
		"tutorial":
			start_money = 400_000
		"greenfield":
			start_money = 350_000
			City.model.terrain.set_seed(19)
		"brownfield":
			start_money = 120_000
			_build_brownfield()
		"transition":
			start_money = 300_000
			_build_transition()
	City.money = int(start_money * diff["money_scale"])
	City._topo_dirty = true
	# the CLOCK is the time authority (City.current_t is stale between steps)
	return {"id": id, "start_day": int(GameClock.total_minutes / (15.0 * 96.0)),
		"win_streak": 0, "lose_streak": 0, "done": false}


## Daily verdict: "" (running) | "win" | "lose". Mutates the runner state's
## streak counters.
static func evaluate(state: Dictionary, day: int) -> String:
	var elapsed: int = day - state["start_day"]
	match state["id"]:
		"greenfield":
			if City.money < BANKRUPT_EUR:
				return "lose"
			var all_three: bool = not City.topo.zones_info.is_empty() \
				and not City.heat_topo.zones_info.is_empty() \
				and not City.water_topo.zones_info.is_empty()
			if all_three and City.model.houses.size() >= 25 and City.happiness >= 80.0:
				return "win"
			if elapsed > 720:
				return "lose"
		"brownfield":
			if City.money < BANKRUPT_EUR:
				return "lose"
			state["win_streak"] = state["win_streak"] + 1 \
				if City.happiness >= 75.0 else 0
			state["lose_streak"] = state["lose_streak"] + 1 \
				if City.happiness < 20.0 else 0
			if state["win_streak"] >= WIN_SUSTAIN_DAYS:
				return "win"
			if state["lose_streak"] >= LOSE_SUSTAIN_DAYS or elapsed > 360:
				return "lose"
		"transition":
			if City.money < BANKRUPT_EUR:
				return "lose"
			var fossil_gone := City.model.buildings_of_kind("gas_plant").is_empty()
			var recent_outage_ok := City.total_outage_minutes() \
				- int(state.get("outage_baseline", 0)) < 60
			if day % 7 == 0:  # rolling 7-day outage window
				state["outage_baseline"] = City.total_outage_minutes()
			if fossil_gone and recent_outage_ok and City.happiness >= 70.0 \
					and elapsed >= 7:
				return "win"
			if elapsed > 720:
				return "lose"
	return ""


# ─── prebuilt worlds ───

## Inherited grid: electricity only (the town heats with oil stoves), a
## 20-kW relic of a grid connection, the substation a sagging feeder away —
## evening peaks trip the connection nightly until the player builds local
## generation. Undersized on purpose.
static func _build_brownfield() -> void:
	City.grid_capacity_override = 20.0
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 31):
		City.build_cable(Vector2i(x, 5))
	City.place_building("substation", Vector2i(24, 6))  # far: sagging feeder
	for x in range(8, 25):
		City.build_road(Vector2i(x, 8))
	for x in range(8, 25):
		City.build_zone(Vector2i(x, 9))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 14)


## Energy transition: a healthy compact town — but the only generation is
## one big old gas plant the player must retire without blackouts.
static func _build_transition() -> void:
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 31):
		City.build_cable(Vector2i(x, 5))
	City.place_building("gas_plant", Vector2i(16, 3))
	City.place_building("substation", Vector2i(12, 6))
	for x in range(8, 25):
		City.build_road(Vector2i(x, 8))
	for x in range(8, 25):
		City.build_road(Vector2i(x, 11))
	for x in range(8, 25):
		City.build_zone(Vector2i(x, 9))
	for x in range(8, 19):
		City.build_zone(Vector2i(x, 12))
	City.place_building("boiler_plant", Vector2i(6, 13))
	for x in range(8, 15):
		City.build_heat_pipe(Vector2i(x, 14))
	City.place_building("heat_exchanger", Vector2i(15, 14))
	City.place_building("water_tower", Vector2i(6, 17))
	for x in range(7, 15):
		City.build_water_pipe(Vector2i(x, 17))
	City.place_building("water_station", Vector2i(15, 17))
	City.place_building("well", Vector2i(10, 19))
	City.build_water_pipe(Vector2i(10, 18))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 18)


# ─── tutorial (teaches the three networks one at a time) ───

static func tutorial_steps() -> Array[Dictionary]:
	return [
		{"text": "ELECTRICITY 1/4 — Build a Grid connection (TAB menu or key 9). It is your link to the wholesale grid.",
			"done": func() -> bool:
				return not City.model.buildings_of_kind("grid_connection").is_empty()},
		{"text": "ELECTRICITY 2/4 — Place a Substation (4) and connect it to the grid connection with Overhead lines (3) or buried Cables (G).",
			"done": func() -> bool:
				return City.topo.connected.get(
					City.model.buildings_of_kind("substation")[0], false) \
					if not City.model.buildings_of_kind("substation").is_empty() else false},
		{"text": "ELECTRICITY 3/4 — Draw a Road (1) near the substation and paint Residential zones (2) next to it.",
			"done": func() -> bool:
				return not City.model.roads.is_empty() and not City.model.zoning.is_empty()},
		{"text": "ELECTRICITY 4/4 — Unpause (SPACE) and wait: houses appear and light up while the zone is supplied.",
			"done": func() -> bool:
				return City.model.houses.size() >= 3},
		{"text": "HEAT 1/2 — Build a Boiler plant (B) and run Heat pipes (H) from it toward town.",
			"done": func() -> bool:
				return not City.model.buildings_of_kind("boiler_plant").is_empty() \
					and City.model.heat_pipes.size() >= 3},
		{"text": "HEAT 2/2 — Add a Heat exchanger (J) on the pipe within reach of the houses. Watch the ring turn warm.",
			"done": func() -> bool:
				return not City.heat_topo.zones_info.is_empty()},
		{"text": "WATER 1/2 — Build a Water tower (O) and run green Water pipes (W) toward town.",
			"done": func() -> bool:
				return not City.model.buildings_of_kind("water_tower").is_empty() \
					and City.model.water_pipes.size() >= 3},
		{"text": "WATER 2/2 — Add a Water station (A) on the main near the houses. Pressure comes from the tower's height.",
			"done": func() -> bool:
				return not City.water_topo.zones_info.is_empty()},
		{"text": "DONE — All three networks are live. Press I to see the happiness breakdown; TAB for the full palette. Good luck!",
			"done": func() -> bool: return false},
	]
