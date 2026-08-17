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
		{"id": "heidelberg", "name": "Heidelberg (reference city)",
			"desc": "The real Heidelberg on real SRTM elevation: Altstadt under the Königstuhl, the Neckar, district heating from the west. A reference build to study, not a puzzle — no goals, free budget."},
		{"id": "island", "name": "Off-grid village",
			"desc": "No transmission grid for miles. Grow a village on wind, sun and one battery — stay off-grid, and mind the EMS: calm nights shed load when storage runs short."},
	]


## Applies start money/difficulty and pre-builds the world. Runner state
## (deadline, sustain counters) comes back to the caller.
static func start(id: String, difficulty_key: String) -> Dictionary:
	var diff: Dictionary = DIFFICULTY[difficulty_key]
	City.reset_for_scenario(42)
	City.difficulty = diff.duplicate()
	City.events_enabled = id != "tutorial"  # tutorial stays predictable
	# prebuilds run on the reset's deep pockets; the scenario's start
	# budget lands AFTER (the inherited town wasn't paid for by the player).
	# BULK: world_changed drives a FULL CityView.redraw, so a per-tile
	# signal storm is quadratic — Heidelberg's ~4 500 build calls froze the
	# game for minutes before this wrap existed.
	City.begin_bulk()
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
		"heidelberg":
			_build_heidelberg()
			City.infinite_money = true  # a reference to study and extend
		"island":
			start_money = 250_000
			_build_island()
	City.money = int(start_money * diff["money_scale"])
	City.end_bulk()  # one redraw for the whole prebuild
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
		"island":
			if City.money < BANKRUPT_EUR:
				return "lose"
			# win: a GROWN village kept happy on the microgrid ALONE — a
			# grid connection resets the streak (the point is off-grid)
			var off_grid := City.model.buildings_of_kind(
				"grid_connection").is_empty()
			state["win_streak"] = state["win_streak"] + 1 \
				if off_grid and City.happiness >= 75.0 \
					and City.model.houses.size() >= 16 else 0
			state["lose_streak"] = state["lose_streak"] + 1 \
				if City.happiness < 20.0 else 0
			if state["win_streak"] >= WIN_SUSTAIN_DAYS:
				return "win"
			if state["lose_streak"] >= LOSE_SUSTAIN_DAYS or elapsed > 720:
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


## Off-grid village (power islands M4): no grid connection anywhere — a
## battery-formed microgrid (one turbine, one park, one 1-MWh battery)
## feeds a small village. Heat is oil stoves, water a gravity spring;
## electricity is the scenario. Ten starter houses; growth pushes the
## calm-night balance until the player adds storage or a gas reserve.
static func _build_island() -> void:
	City.place_building("battery", Vector2i(6, 4))
	for x in range(6, 18):
		City.build_cable(Vector2i(x, 5))
	City.place_building("wind_farm", Vector2i(9, 4))
	City.place_building("solar_park", Vector2i(12, 3))
	City.place_building("substation", Vector2i(17, 6))
	for x in range(10, 24):
		City.build_road(Vector2i(x, 8))
	for x in range(10, 24):
		City.build_zone(Vector2i(x, 9))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 10)


# ─── Heidelberg, Baden-Württemberg: a REFERENCE build of a real city ───
#
# 6.4 x 6.4 km of real SRTM elevation centred on the Alte Brücke (49.410 N,
# 8.700 E) — the whole city is ~109 km², so this window holds the core:
# Altstadt, Bergheim, Weststadt, the Hauptbahnhof, Südstadt, and across the
# Neckar Neuenheim and Handschuhsheim. Tile coordinates were derived from
# real lat/lon through the same Web Mercator math the terrain fetcher uses,
# so districts sit where they sit in reality.
#
# The infrastructure follows the real city's shape rather than being
# invented: MV and district heating arrive FROM THE WEST (Heidelberg's
# district heat is largely GKM Mannheim waste heat plus the Pfaffengrund
# biomass plant, whose Energie- und Zukunftsspeicher is modelled as the
# heat store beside the CHP — the real energy park sits just outside this
# window, so the west map edge stands in for it), drinking water comes from
# well fields in the Rhine plain by the river, and the pressure tower sits
# on the Königstuhl slope the way Heidelberg's Hochbehälter do.
#
# KNOWN LIMITATION, and the most useful thing this build surfaces: there
# are NO BRIDGES yet, and water blocks every kind of construction, so the
# Neckar cuts the map in two. The north bank is therefore built as its OWN
# independent network with its own 110/20 kV infeed — which is defensible
# (Neuenheim and Handschuhsheim really are fed from other substations) but
# is a workaround, not a model. River bridges are the unlock that would let
# this be one city.

## The Neckar. The city stretch is anchored on the three real bridge
## crossings — a bridge IS on the river, and the Rhine plain is far too
## flat for the DEM to reveal a channel — while the gorge east of the Alte
## Brücke follows the baked DEM's valley floor, because hand-picked
## coordinates there kept landing on the Königstuhl slope instead.
const HD_NECKAR: Array[Vector2i] = [
	Vector2i(3, 92), Vector2i(47, 98),
	Vector2i(91, 105),    # Ernst-Walz-Brücke
	Vector2i(114, 109),   # Theodor-Heuss-Brücke
	Vector2i(159, 115),   # Alte Brücke, at the mouth of the gorge
	Vector2i(167, 112), Vector2i(175, 109), Vector2i(183, 105),
	Vector2i(191, 101), Vector2i(199, 96), Vector2i(207, 90),
	Vector2i(215, 89), Vector2i(231, 89), Vector2i(247, 94),
	Vector2i(255, 96),
]
const HD_HALF_WIDTH := 2  # ~125 m of channel, close to the real Neckar


static func _build_heidelberg() -> void:
	var terrain := City.model.terrain
	terrain.set_seed(0)                    # the Neckar is placed, not generated
	terrain.load_region("heidelberg")
	_hd_carve_neckar(terrain)

	var osm := _hd_osm()

	# ── south bank: supply arrives from the west, as it really does ──
	# Utilities go down BEFORE the streets. Their coordinates were checked
	# against the DEM (flat ground, dry, off the river), and a road can be
	# paved over a buried trench but never over a building — so laying the
	# plant and the corridors first lets the street network route around
	# them. The other way round, the real streets silently swallowed the
	# pumping station and a well, and a water network lost its source.
	# PHASE 1 — every hand-validated building goes down first (all checked
	# against the DEM: flat, dry, clear of the river). A LINE may not cross
	# a building any more than a road may, so anything placed later would
	# sever a trench laid earlier.
	City.place_building("grid_connection", Vector2i(26, 150))
	# The Zukunftsspeicher stays at the west energy park, but there is NO
	# plant beside it any more: the sole heat producer has to sit in the
	# MIDDLE of the city. With the slack at the west map edge the 85 °C
	# supply arrived at the far exchangers at 54, 35, 20, finally 10 °C
	# (t_supply_low on eight zones, then outright `failed`) — a 6.75 km
	# single-fed network simply cannot hold temperature. Real Heidelberg
	# answers that with several feed-in points; the heat contract allows
	# exactly one, so the producer moves to Heizwerk Mitte instead.
	City.place_building("heat_storage", Vector2i(24, 161))  # Zukunftsspeicher
	# THE ENERGY PARK at the west edge, which is what the map edge stands in
	# for: Heidelberg's district heat is largely GKM Mannheim waste heat plus
	# the Pfaffengrund biomass plant, and the Zukunftsspeicher above sits
	# beside them. It feeds IN rather than holding pressure (the reference is
	# Heizwerk Mitte, in the middle of town where a single producer has to
	# be) — which is exactly what a secondary plant is now able to do.
	City.place_building("boiler_plant", Vector2i(20, 159))  # GKM tie-in
	City.place_building("well", Vector2i(44, 102))          # river bonus
	City.place_building("well", Vector2i(52, 102))
	City.place_building("pumping_station", Vector2i(60, 112))
	City.place_building("water_tower", Vector2i(168, 150))  # Königstuhl slope
	City.place_building("chp_plant", Vector2i(74, 145))     # Heizwerk Mitte
	City.place_building("heat_pump_plant", Vector2i(58, 131))  # Flusswärmepumpe
	# SPITZENLASTKESSEL along the line, which is how a real district heating
	# network is fed: one plant holds pressure and supply temperature (the
	# slack) while further plants inject heat at their OWN node, each through
	# its own pump. Two things had to be true before these could stand here:
	# the slack is chosen by FLOW TEMPERATURE (an id sort let a 66 °C boiler
	# outrank the 85 °C CHP and set the whole city's supply temperature), and
	# secondary plants are pump_mass producers rather than heat_exchanger
	# feed-ins — an hx fixes HEAT on a branch whose flow the network decides,
	# so the second one landed at near-zero flow and its temperature rise
	# exploded (measured on the backend's own bundle: a zone at -438 °C,
	# reported as "converged"). A pump fixes the flow instead.
	City.place_building("boiler_plant", Vector2i(100, 152))  # Spitzenlast Ost
	City.place_building("boiler_plant", Vector2i(38, 152))   # Spitzenlast West
	# and one ON the Altstadt branch, 3 km from the slack: that far end sat
	# at 10-20 °C supply because a single producer cannot push heat that far.
	# Re-heating mid-line is exactly what these are for.
	City.place_building("boiler_plant", Vector2i(150, 123))  # Spitzenlast Altstadt
	City.place_building("gas_plant", Vector2i(47, 185))     # gas generator
	City.place_building("grid_connection", Vector2i(46, 58))   # north bank
	# OSM puts the Heizkraftwerk at (48,75), which straddles a terrain step
	# — a 2x2 needs one level, so it sits one tile east, still on its spur.
	# A CHP, which is what it really is: it had to be a plain power plant
	# while heat could carry only ONE pressure reference and that reference
	# was on the south bank. Independent systems exist now.
	City.place_building("chp_plant", Vector2i(49, 74))      # Heizkraftwerk HD

	# Utility corridors: BURIED, and buried is not a detail here — a surface
	# line cannot cross a road at all, so an overhead trunk could never enter
	# a district. Real MV and district heating are trenched under the street
	# anyway, and the game lets buried networks share that cross-section.
	var corridors: Array = [
		[Vector2i(28, 151), Vector2i(118, 151)],                    # west trunk
		[Vector2i(112, 151), Vector2i(112, 132), Vector2i(132, 132)],  # Bergheim
		[Vector2i(112, 132), Vector2i(112, 125)],                   # link north
		[Vector2i(112, 125), Vector2i(138, 125), Vector2i(138, 122),
			Vector2i(178, 122)],                                    # Altstadt
		# SÜDSTADT, on district heating since 2026-08-17. It was power and
		# water only, and the reason given was that hanging another 45-tile
		# branch off a network with ONE producer pushed the far exchangers to
		# 10 °C. Both halves of that are gone: pipes are sized from the load
		# behind them (a branch gets the DN it needs) and a network carries a
		# pressure reference per component with feed-in plants along the line.
		[Vector2i(96, 151), Vector2i(96, 182), Vector2i(110, 182)],  # Südstadt
		# plant tie-in — DETOURED to y=152. The straight run along y=151 went
		# through the grid connection's 2x2 footprint at (26,151)/(27,151),
		# which severed the SLACK plant from the trunk: heat fell back to a
		# 2-exchanger island while the 273-tile main network was dropped
		# ("only the slack plant's network is solved"). It still converged
		# every frame, because a tiny network solves fine — convergence
		# never implied coverage.
		[Vector2i(22, 160), Vector2i(22, 152), Vector2i(28, 152),
			Vector2i(28, 151)],
		[Vector2i(22, 160), Vector2i(26, 160)],                      # heat store
	]
	# ── the three real Neckar crossings, decked before anything is laid ──
	# Ernst-Walz-, Theodor-Heuss- and Alte Brücke stand where the river
	# polyline already named them. A decked tile is crossable ground, so the
	# OSM street network lays itself over them later in this same build and
	# the utility run below can follow — which is the whole reason the north
	# bank stops being a separate city.
	for span: Vector2i in [Vector2i(91, 105), Vector2i(114, 109),
			Vector2i(159, 115)]:
		_hd_bridge_span(span)

	# PHASE 2 — every trench, laid while only Phase 1's buildings exist.
	# Seating the supply trios inside THIS loop (the previous shape) let a
	# trio beside corridor N sever corridor N+1 where it crossed: the
	# utility networks came apart into 5 cable and 6 water components, and
	# HeatTopology/PowerTopology then dropped whatever their BFS from the
	# slack could not reach — the "thermal units are not connected" report.
	var corridor_tiles: Array = []
	for run: Array in corridors:
		corridor_tiles.append(_hd_run3(run))
	# ── south bank: water from the Rhine-plain well fields by the river ──
	# y=103, NOT y=101: the well feeder used to run 12 tiles straight down
	# the middle of the Neckar (the channel is 5 wide and its centre sits at
	# y≈99 here), so those tiles silently refused to build and both wells
	# ended up on a pipe network of their own. Still within 3 tiles of the
	# water, so the wells keep their +50 % river yield.
	_hd_run("water", [Vector2i(44, 103), Vector2i(60, 103), Vector2i(60, 111)])
	_hd_run("water", [Vector2i(62, 113), Vector2i(62, 151)])
	# pressure head off the Königstuhl slope, like Heidelberg's Hochbehälter
	_hd_run("water", [Vector2i(178, 122), Vector2i(178, 125),
		Vector2i(168, 125), Vector2i(168, 149)])

	# ── Heidelberg's REAL thermal plants (OSM power=plant / generator) ──
	# The city is not heated from one shed at the map edge: Stadtwerke run
	# a gas Heizkraftwerk, a peak-load Heizwerk in the middle of town, and
	# since 2023 a river-water heat pump on the Neckar. Each taps the
	# corridor it stands on. (The Neckar's two hydro stations at the Karls-
	# tor weir and Wieblingen, 2.6 and 1.3 MW, have no game equivalent —
	# there is no hydro device in the contract.)
	# Heizwerk Mitte is a gas plant house; it is placed as a CHP, NOT a
	# boiler, and that is forced by the model rather than chosen. The heat
	# doc carries exactly ONE producer — the slack — and its flow
	# temperature comes from that plant's kind, while the slack is picked as
	# `plant_ids.sort()[0]`. "boiler_plant" sorts before "chp_plant", so a
	# single boiler anywhere in the city silently drops the WHOLE network
	# from 85 °C to the boiler's 66 °C; on a 487-pipe network the far ends
	# then cannot be served and frames come back `failed`.
	_hd_run("heat", [Vector2i(74, 147), Vector2i(74, 151)])    # Heizwerk Mitte
	_hd_run("heat", [Vector2i(58, 133), Vector2i(58, 151)])    # Flusswärmepumpe
	_hd_run("cable", [Vector2i(58, 133), Vector2i(58, 151)])   # it runs on power
	_hd_run("cable", [Vector2i(47, 187), Vector2i(47, 151)])   # gas generator

	# ── north bank: its own city, because there is no way across ──
	# The real Heizkraftwerk Heidelberg (OSM: gas, 13.5 MW) stands on this
	# bank and is a CHP — but it is modelled here as a PLAIN GAS PLANT,
	# and the north bank gets NO district heating. That is a limit of the
	# heat contract, not a choice: HeatTopology binds exactly ONE slack
	# (the first plant by id) and BFSes from it, dropping every unreachable
	# pipe with "only the slack plant's network is solved". A city split by
	# an unbridged river needs TWO independent heat systems, and the model
	# cannot express that — power can (grid_forming islands), heat cannot.
	# Building it anyway cost the south network its solve: heat convergence
	# fell from 9 frames in 9 to 2.
	_hd_run("cable", [Vector2i(48, 77), Vector2i(48, 60)])
	var north: Array = [
		[Vector2i(48, 60), Vector2i(48, 58), Vector2i(96, 58)],
		[Vector2i(62, 58), Vector2i(62, 52), Vector2i(90, 52)],
		[Vector2i(96, 58), Vector2i(96, 98), Vector2i(118, 98)],
		[Vector2i(61, 96), Vector2i(96, 96)],
	]
	# POWER ONLY across the river. Heat and water are single-source models —
	# HeatTopology BFSes from one slack plant, WaterTopology from one head
	# (tower > well > pump) — and both drop every pipe they cannot reach.
	# The head is the Königstuhl tower on the SOUTH bank, so a north-bank
	# water system is unsolvable exactly like a north-bank heat system: it
	# built 16 water stations that the solver silently discarded (34 tiles
	# of station, 18 zones out of 34). Power is the only network with
	# multi-component support, via grid_forming islands.
	var north_tiles: Array = []
	for run: Array in north:
		_hd_run("water", run)
		north_tiles.append(_hd_run("cable", run))
	# THE NORTH BANK'S OWN DISTRICT HEATING. Fed by the Heizkraftwerk, and
	# deliberately NOT joined to the south over the bridge: two independent
	# systems with a pressure reference each is what the real city has, and
	# it keeps Neuenheim's load off a trunk that is already carrying the
	# Altstadt. This was impossible until heat learned to hold more than one
	# reference — the north bank simply had no district heating at all.
	# Down the bank and INTO Neuenheim, where the houses actually are: the
	# first routing followed the empty north-west edge and every station on
	# it was pruned for having no customers, which left the plant alone on
	# a main with no consumer — an isolated node the contract rightly
	# refuses. A heat main goes where the load is.
	var north_heat: Array = _hd_run("heat", [
		Vector2i(48, 75), Vector2i(48, 94), Vector2i(118, 94)])
	_hd_seat_every(north_heat, 14, "heat_exchanger")
	# THE CROSSING. One run over the Theodor-Heuss-Brücke joins the north
	# bank to the south networks: power meshes into one grid, and the water
	# mains reach the Königstuhl tower's pressure zone instead of being
	# discarded as an unreachable component. It lands on the north trunk at
	# y=98 and on the Altstadt corridor at y=125, both of which already run
	# through x=114.
	_hd_run("cable", [Vector2i(114, 98), Vector2i(114, 125)])
	_hd_run("water", [Vector2i(114, 98), Vector2i(114, 125)])

	# PHASE 3 — supply trios, seated only once every trench is in the
	# ground. Each finds its own free tile beside the pipe it taps; a
	# hand-picked coordinate lands on asphalt now that real streets cross
	# the city, and a building may not sit on a road.
	for tiles: Array in corridor_tiles:
		_hd_supply_along(tiles, 16, true)

	for tiles: Array in north_tiles:
		_hd_supply_along(tiles, 16, false)   # water reaches over the bridge now

	# ── the real street network, laid around the utilities ──
	# Every arterial across the map (motorway…tertiary), plus the dense
	# minor lanes INSIDE the river strip where the real footprints are:
	# arterials alone leave 78 % of Heidelberg's buildings with no street
	# in reach, and paving every minor way in the window would add 5 800
	# tiles — a third of the map.
	var strip := _hd_strip(osm)
	for way: Variant in _hd_ways(osm, "main"):
		_hd_pave((way as Dictionary)["pts"], Rect2i(0, 0, 256, 256))
	for way: Variant in _hd_ways(osm, "minor"):
		_hd_pave((way as Dictionary)["pts"], strip)
	_hd_thin_roads()
	_hd_prune_stubs(6)
	_hd_trim_dots()

	# ── the real city: OpenStreetMap building footprints become houses ──
	# One house per footprint, on the tile its centroid falls in (a game
	# tile is 25 m, so a Heidelberg building is about one tile). Laid AFTER
	# the corridors on purpose: a house blocks a buried line, so the
	# utilities claim their trench first and the handful of footprints that
	# fall on it simply do not get built.
	for entry: Variant in osm.get("buildings", []):
		var pos := Vector2i(int((entry as Array)[0]), int((entry as Array)[1]))
		var seat := _hd_lot_near(pos)
		if seat.x < 0:
			continue
		City.build_zone(seat)
		if City.model.spawn_house(seat):
			City.dirty_tiles[seat] = true
	# ── the districts the footprint extract does not cover ──
	# Zoning used to exist ONLY where an OSM footprint landed, and the
	# extract covers just the river strip — so every house in the city stood
	# between y=80 and y=139 while Weststadt, Bergheim-Süd and Südstadt had
	# streets, ~21 substations, heat and water on land that could never grow.
	# Those are dense residential districts in reality. This is the room
	# they need; growth fills it as the city runs.
	for district: Rect2i in [
			Rect2i(28, 140, 96, 18),    # Weststadt / Bergheim-Süd
			Rect2i(88, 152, 34, 36),    # Südstadt toward Rohrbach
			Rect2i(120, 132, 60, 12)]:  # south of the Altstadt corridor
		_hd_zone_district(district)
	# whatever the footprints could not fill, growth may still take
	for sub_id: String in City.model.buildings_of_kind("substation"):
		City.spawn_houses_bulk(sub_id, 8)
	# every dark cluster gets its station + street-following feeder
	_hd_power_infill()
	_hd_prune_idle_heat(City.model)


## Serve every dark house: trench a spur under the streets and set a
## substation wherever a cluster of houses has none in reach.
##
## The corridor trios are seated every ~16 trench tiles BEFORE any house
## exists, and the OSM footprints spread far beyond the corridors — the
## rebuilt city left 351 of 940 houses with no substation within the zone
## radius, dark forever with no feedback. This is what a distribution
## utility actually does about that: the load exists, so a station is
## built at the load, fed by a buried spur that follows the street network
## back to the nearest live cable (crossing the river on the bridge decks
## like every other trench).
static func _hd_power_infill(max_stations: int = 48) -> int:
	# ROUNDS, because placement order matters: every station's feeder adds
	# trench the NEXT cluster can tap, so a cluster that failed early in a
	# round often succeeds once the map has grown toward it. One permanent
	# blacklist stranded 27 houses whose station placed fine when asked
	# again at the end — so failed clusters get fresh chances until a whole
	# round places nothing.
	var total := 0
	for _round in 4:
		var placed := _hd_power_infill_round(max_stations - total)
		total += placed
		if placed == 0:
			break
	return total


static func _hd_power_infill_round(max_stations: int) -> int:
	_hd_infill_given_up.clear()
	var model: WorldModel = City.model
	var radius: int = int(BuildingDefs.get_def("substation")["zone_radius"])
	var placed := 0
	for _pass in max_stations:
		# orphans: houses with no substation anchor within the zone radius
		var anchors: Array[Vector2i] = []
		for kind: String in ["substation", "substation_xl"]:
			for id: String in model.buildings_of_kind(kind):
				anchors.append(model.buildings[id]["anchor"])
		var orphans: Array[Vector2i] = []
		for pos: Vector2i in model.houses:
			var near := false
			for a: Vector2i in anchors:
				if absi(pos.x - a.x) + absi(pos.y - a.y) <= radius:
					near = true
					break
			if near:
				continue
			var hopeless := false
			for dead: Vector2i in _hd_infill_given_up:
				if absi(pos.x - dead.x) + absi(pos.y - dead.y) <= radius:
					hopeless = true
					break
			if not hopeless:
				orphans.append(pos)
		if orphans.is_empty():
			return placed
		# the densest cluster: the orphan with the most orphans in reach of
		# a station standing next to it
		var best := orphans[0]
		var best_n := -1
		for pos: Vector2i in orphans:
			var n := 0
			for other: Vector2i in orphans:
				if absi(pos.x - other.x) + absi(pos.y - other.y) <= radius - 2:
					n += 1
			if n > best_n:
				best_n = n
				best = pos
		if _hd_station_at(best, radius):
			placed += 1
		else:
			# nothing seatable/reachable for this cluster: remember it and
			# keep serving the others (a repeat would loop forever)
			_hd_infill_given_up.append(best)
	return placed


## Clusters _hd_power_infill could not serve (skipped on later passes).
static var _hd_infill_given_up: Array[Vector2i] = []


## Seat one substation near *goal* and trench its feeder. Returns success.
##
## ORDER MATTERS: trench first, seat second. The first version chose the
## seat during the BFS and trenched afterwards — and with free land
## traversable, the shortest route to the cable regularly ran THROUGH the
## chosen seat (it is exactly the free tile beside the road the path wants),
## so `place_building` found a cable on its tile, failed, and the whole
## cluster was blacklisted. Seating beside the FINISHED trench cannot lose
## that race, and the station taps the trench like any building taps a line.
static func _hd_station_at(goal: Vector2i, radius: int) -> bool:
	var model: WorldModel = City.model
	var start := _hd_nearest_road(goal, 6)
	if start.x < 0:
		return false
	# BFS outward over everything trenchable until a live cable is found.
	# Streets alone are not enough: the street network is a DOZEN components
	# (real OSM geometry) and a cluster's fragment often carries no cable at
	# all — so the feeder may cut across free land between two streets,
	# exactly like a real one. Houses, buildings and unbridged water still
	# refuse via can_set_cable; bridge decks carry it over the river.
	var parent := {start: start}
	var queue: Array[Vector2i] = [start]
	var cable_hit := Vector2i(-1, -1)
	var i := 0
	while i < queue.size():
		var tile: Vector2i = queue[i]
		i += 1
		if model.cables.has(tile):
			cable_hit = tile
			break
		for offset: Vector2i in [Vector2i(0, -1), Vector2i(0, 1),
				Vector2i(-1, 0), Vector2i(1, 0)]:
			var next: Vector2i = tile + offset
			if parent.has(next):
				continue
			if model.roads.has(next) or model.cables.has(next) \
					or model.can_set_cable(next, BuildingDefs.LINE_UNDERGROUND):
				parent[next] = tile
				queue.append(next)
	if cable_hit.x < 0:
		return false
	# trench: from the live cable back up the BFS tree to the start
	var trench: Array[Vector2i] = []
	var walk := cable_hit
	while true:
		City.build_cable(walk, BuildingDefs.LINE_UNDERGROUND)
		trench.append(walk)
		if walk == parent[walk]:
			break
		walk = parent[walk]
	# seat: a free tile beside the trench, as close to the cluster as the
	# trench gets (the start end is <= 6 tiles from the goal house)
	trench.reverse()   # start end first — nearest the cluster
	for tile: Vector2i in trench:
		if absi(tile.x - goal.x) + absi(tile.y - goal.y) > radius - 2:
			continue
		for offset: Vector2i in [Vector2i(0, -1), Vector2i(0, 1),
				Vector2i(-1, 0), Vector2i(1, 0)]:
			if City.place_building("substation", tile + offset):
				return true
	return false


static func _hd_nearest_road(goal: Vector2i, reach: int) -> Vector2i:
	var model: WorldModel = City.model
	for r in reach + 1:
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var pos := goal + Vector2i(dx, dy)
				if model.roads.has(pos):
					return pos
	return Vector2i(-1, -1)


## Paint buildable land beside the streets of one district.
##
## Only tiles that a house could actually take: orthogonally beside a road,
## free, and passing `lot_buildable` — zoning a hillside the growth rule will
## refuse just paints the map amber and teaches the player nothing.
static func _hd_zone_district(box: Rect2i) -> int:
	var model: WorldModel = City.model
	var painted := 0
	var roads: Array = model.roads.keys()
	for pos: Vector2i in roads:
		if not box.has_point(pos):
			continue
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			var lot: Vector2i = pos + offset
			if model.zoning.has(lot) or not model.can_set_zone(lot):
				continue
			# lot_buildable can only be asked of a ZONED tile (its first
			# clause checks the paint) — so paint first, verify, and take
			# the paint back off a lot growth would refuse (cliff steps,
			# a line underneath): amber dead-lots teach the player nothing
			# when the prebuild made them.
			if not City.build_zone(lot):
				continue
			if model.lot_buildable(lot, WorldModel.ZONE_RESIDENTIAL):
				painted += 1
			else:
				model.zoning.erase(lot)
	return painted


## Drop heat exchangers that ended up with NO houses in reach.
##
## The supply trios are seated mechanically every ~16 corridor tiles, before
## a single house exists — so where the real footprints happen to be thin,
## a station lands with nobody to serve. NINE of seventeen were like that,
## and an idle station is not merely useless: it draws no flow, so its
## branch cools to ground temperature (the smoke read it as a 10 °C
## `t_supply_low` violation and it looked like the far city was freezing)
## and it leaves a near-stagnant branch for the hydraulics to resolve. A
## utility would not build it, so neither do we.
static func _hd_prune_idle_heat(model: WorldModel) -> void:
	var radius: int = int(BuildingDefs.get_def("heat_exchanger")["zone_radius"])
	for sub_id: String in model.buildings_of_kind("heat_exchanger"):
		var centre: Vector2i = model.buildings[sub_id]["anchor"]
		var served := false
		for pos: Vector2i in model.houses:
			if absi(pos.x - centre.x) <= radius and absi(pos.y - centre.y) <= radius:
				served = true
				break
		if not served:
			model.remove_building(sub_id)


## The river as a swept polyline. force_water overrides the "valley level 0
## only" rule that governs generated rivers, so the channel can sit on the
## real valley floor whatever level the DEM gives it.
static func _hd_carve_neckar(terrain: Terrain) -> void:
	for i in HD_NECKAR.size() - 1:
		var a: Vector2i = HD_NECKAR[i]
		var b: Vector2i = HD_NECKAR[i + 1]
		var steps: int = maxi(absi(b.x - a.x), absi(b.y - a.y))
		for s in steps + 1:
			var p := Vector2i(roundi(lerpf(a.x, b.x, float(s) / steps)),
				roundi(lerpf(a.y, b.y, float(s) / steps)))
			terrain.force_water(p - Vector2i(HD_HALF_WIDTH, HD_HALF_WIDTH),
				p + Vector2i(HD_HALF_WIDTH, HD_HALF_WIDTH))


## The baked OpenStreetMap extract (streets + Altstadt footprints), or {}
## when it is missing — the scenario then has terrain and utilities but no
## streets, which is visibly broken rather than silently wrong.
static func _hd_osm() -> Dictionary:
	var path := "res://data/terrain/heidelberg_osm.json"
	if not FileAccess.file_exists(path):
		push_warning("heidelberg_osm.json missing: no streets will be built")
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


static func _hd_ways(osm: Dictionary, bucket: String) -> Array:
	var streets: Dictionary = osm.get("streets", {})
	return streets.get(bucket, [])


## Padded tile bounds of the real footprints — the strip where paving the
## dense minor lanes is worth it.
static func _hd_strip(osm: Dictionary) -> Rect2i:
	var buildings: Array = osm.get("buildings", [])
	if buildings.is_empty():
		return Rect2i()
	var lo := Vector2i(9999, 9999)
	var hi := Vector2i(-9999, -9999)
	for entry: Variant in buildings:
		var p := Vector2i(int((entry as Array)[0]), int((entry as Array)[1]))
		lo = Vector2i(mini(lo.x, p.x), mini(lo.y, p.y))
		hi = Vector2i(maxi(hi.x, p.x), maxi(hi.y, p.y))
	return Rect2i(lo - Vector2i(2, 2), hi - lo + Vector2i(5, 5))


## A 4-CONNECTED tile line between two points.
##
## Rounding an interpolated line gives an 8-connected one, where a diagonal
## step leaves consecutive tiles touching only at a CORNER. The road
## renderer picks each piece from its ORTHOGONAL neighbours, so every such
## step drew two dead-end caps and a diagonal street read as a dotted line
## of bumps (user report 2026-08-14: "unconnected or … circular bumps" —
## 97 fully isolated tiles and 803 diagonal dead ends, 22 % of the
## network). Inserting the elbow tile costs a few tiles and makes the
## street continuous. Pure and static so the property is testable.
static func paved_line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [a]
	var steps: int = maxi(absi(b.x - a.x), absi(b.y - a.y))
	var prev := a
	for s in range(1, steps + 1):
		var cur := Vector2i(roundi(lerpf(a.x, b.x, float(s) / steps)),
			roundi(lerpf(a.y, b.y, float(s) / steps)))
		if cur == prev:
			continue
		if cur.x != prev.x and cur.y != prev.y:
			out.append(Vector2i(cur.x, prev.y))  # the elbow the corner needs
		out.append(cur)
		prev = cur
	return out


## Street-shape pipeline, applied to every OSM way BEFORE it hits the grid.
##
## The tile grid has no diagonal road piece — the Kenney kit's `slant`
## pieces are ramps and its `curve` is a smooth 90° — and the renderer
## picks each piece from its ORTHOGONAL neighbours. So a street at any
## angle but 0/90° can only be a staircase of alternating corners: a
## sawtooth ribbon, not a road. Measured on the real extract, HALF of all
## two-neighbour tiles were corners and the mean straight run was 3.5
## tiles, which is what "the streets do not look right" was.
##
## Snapping each segment onto its nearer axis trades Heidelberg's organic
## diagonals for streets that read as streets (user's call): bends 51 % ->
## 16 %, mean straight run 3.5 -> 5.4 tiles, solid 2x2 asphalt 727 -> 293.
## Simplify first, so sub-tile wiggles never become corners of their own.
const STREET_SIMPLIFY_TOL := 1.5   # tiles — below this a wiggle is noise
const STREET_SNAP_DEG := 0.0      # 0 = keep the real angles; the diagonal
                                  # renderer draws them as smooth bands now


## Douglas-Peucker on a tile polyline.
static func simplify_way(pts: Array, tol: float) -> Array:
	if pts.size() < 3 or tol <= 0.0:
		return pts
	var a := Vector2(pts[0])
	var b := Vector2(pts[pts.size() - 1])
	var span := a.distance_to(b)
	var worst := -1.0
	var idx := 0
	for i in range(1, pts.size() - 1):
		var p := Vector2(pts[i])
		var dist := p.distance_to(a) if span == 0.0 \
			else absf((b - a).cross(p - a)) / span
		if dist > worst:
			worst = dist
			idx = i
	if worst <= tol:
		return [pts[0], pts[pts.size() - 1]]
	var head := simplify_way(pts.slice(0, idx + 1), tol)
	head.append_array((simplify_way(pts.slice(idx), tol) as Array).slice(1))
	return head


## Flatten each segment onto the axis it is closer to.
static func snap_way(pts: Array, deg: float) -> Array:
	if pts.size() < 2 or deg <= 0.0:
		return pts
	var out: Array = [pts[0]]
	for i in range(1, pts.size()):
		var prev: Vector2i = out[out.size() - 1]
		var cur: Vector2i = pts[i]
		if cur == prev:
			continue
		var delta := Vector2(cur - prev)
		var ang := absf(rad_to_deg(delta.angle()))
		if minf(ang, absf(ang - 180.0)) <= deg:
			cur.y = prev.y
		elif absf(ang - 90.0) <= deg:
			cur.x = prev.x
		out.append(cur)
	# RE-ANCHOR on the true endpoint. Snapping chains: each segment is
	# flattened onto the previous point, so the error accumulates and the
	# way drifts off its ends — which are the nodes it SHARES with the
	# streets it meets. Letting them drift tore the network from 17
	# components into 85 while the shape metrics looked better than ever.
	# One short reconnecting leg per way costs a corner and keeps the
	# junctions.
	var last: Vector2i = pts[pts.size() - 1]
	if out[out.size() - 1] != last:
		out.append(last)
	return out


## Rasterise one OSM way into road tiles, shaped first.
static func _hd_pave(pts: Array, clip: Rect2i) -> void:
	var raw: Array = []
	for entry: Variant in pts:
		raw.append(Vector2i(int((entry as Array)[0]), int((entry as Array)[1])))
	var shaped := snap_way(simplify_way(raw, STREET_SIMPLIFY_TOL),
		STREET_SNAP_DEG)
	for i in shaped.size() - 1:
		for p: Vector2i in paved_line(shaped[i], shaped[i + 1]):
			if clip.has_point(p):
				City.build_road(p)


## Redundant asphalt goes, and ONLY redundant asphalt. Parallel OSM ways
## (dual carriageways, service roads, slip lanes) collapse onto neighbouring
## tiles at 25 m and render as blobs and little donuts — the "bubbles and
## rings". A tile is removed when its road neighbours stay mutually
## reachable inside the 5x5 window WITHOUT it and none of them is left a
## dead end: a local detour implies a global one, so this can never
## disconnect the network. Measured: solid 2x2 asphalt 331 -> 22, mean
## straight run 5.5 -> 6.0, components unchanged.
##
## Two rejected alternatives, both of which scored well and broke the map:
## dropping whole duplicate WAYS (blobs 331 -> 107 but components 4 -> 50)
## and opening every small ring (components 4 -> 457). Filling the 1-tile
## holes instead just trades donuts for blobs (331 -> 643).
static func _hd_thin_roads() -> void:
	var roads: Dictionary = City.model.roads
	var order: Array[Vector2i] = []
	for pos: Vector2i in roads:
		order.append(pos)
	order.sort()  # deterministic: the result depends on visit order
	for pos: Vector2i in order:
		var links: Array[Vector2i] = []
		for offset: Vector2i in ORTHOGONAL:
			if roads.has(pos + offset):
				links.append(pos + offset)
		if links.size() < 2 or not _hd_locally_bridged(roads, pos, links):
			continue
		roads.erase(pos)
		var orphaned := false
		for neighbour: Vector2i in links:
			var degree := 0
			for offset: Vector2i in ORTHOGONAL:
				if roads.has(neighbour + offset):
					degree += 1
			if degree <= 1:
				orphaned = true
				break
		if orphaned:
			roads[pos] = true      # putting it back beats a new loose end
		else:
			City.dirty_tiles[pos] = true


## Do `pos`'s road neighbours still reach each other without it, staying
## inside the 5x5 window? O(1) per tile — the global version cost a flood
## fill each time.
static func _hd_locally_bridged(roads: Dictionary, pos: Vector2i,
		links: Array[Vector2i]) -> bool:
	var window := {}
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var q := pos + Vector2i(dx, dy)
			if q != pos and roads.has(q):
				window[q] = true
	var seen := {links[0]: true}
	var stack: Array[Vector2i] = [links[0]]
	while not stack.is_empty():
		var cur: Vector2i = stack.pop_back()
		for offset: Vector2i in ORTHOGONAL:
			var q: Vector2i = cur + offset
			if window.has(q) and not seen.has(q):
				seen[q] = true
				stack.append(q)
	for neighbour: Vector2i in links:
		if not seen.has(neighbour):
			return false
	return true


## Trim dead-end spurs: OSM driveways and service stubs rasterise to a few
## tiles that simply stop in a field, and a dead end renders as a capped
## stub — the "loose ends". Iterative, because trimming one spur can expose
## the next. Longer spurs are real cul-de-sacs and stay.
static func _hd_prune_stubs(max_len: int) -> void:
	var roads: Dictionary = City.model.roads
	var changed := true
	while changed:
		changed = false
		var ends: Array[Vector2i] = []
		for pos: Vector2i in roads:
			var degree := 0
			for offset: Vector2i in ORTHOGONAL:
				if roads.has(pos + offset):
					degree += 1
			if degree == 1:
				ends.append(pos)
		for start: Vector2i in ends:
			if not roads.has(start):
				continue
			var run: Array[Vector2i] = [start]
			var cur := start
			var prev := Vector2i(-9999, -9999)
			while run.size() <= max_len:
				var onward: Array[Vector2i] = []
				for offset: Vector2i in ORTHOGONAL:
					var q: Vector2i = cur + offset
					if roads.has(q) and q != prev:
						onward.append(q)
				if onward.size() != 1:
					break                      # reached a junction or an end
				var degree := 0
				for offset: Vector2i in ORTHOGONAL:
					if roads.has(onward[0] + offset):
						degree += 1
				if degree > 2:
					break                      # the next tile is a junction
				prev = cur
				cur = onward[0]
				run.append(cur)
			if run.size() <= max_len:
				for q: Vector2i in run:
					City.model.remove_road(q)
					City.dirty_tiles[q] = true
				changed = true


const ORTHOGONAL: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1)]


## Is this road network something you could walk, or a field of dots?
## `lonely` = tiles with no orthogonal neighbour (each renders as a capped
## stub); `components` = 4-connected pieces; `largest` = the biggest one.
## A diagonally-rastered street shatters into hundreds of components while
## still looking plausible in a tile count, so the count is the signal.
static func road_health(roads: Dictionary) -> Dictionary:
	var lonely := 0
	var seen := {}
	var components := 0
	var largest := 0
	for pos: Vector2i in roads:
		var linked := false
		for offset: Vector2i in ORTHOGONAL:
			if roads.has(pos + offset):
				linked = true
				break
		if not linked:
			lonely += 1
		if seen.has(pos):
			continue
		components += 1
		var size := 0
		var stack: Array[Vector2i] = [pos]
		seen[pos] = true
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			size += 1
			for offset: Vector2i in ORTHOGONAL:
				var next: Vector2i = cur + offset
				if roads.has(next) and not seen.has(next):
					seen[next] = true
					stack.append(next)
		largest = maxi(largest, size)
	# SHAPE, not just topology. Connectivity said this network was perfect
	# while it rendered as a sawtooth: what decides "street or noise" is the
	# ratio of CORNER tiles to straight ones, and how far you get before the
	# next corner. A real street is mostly straight.
	# Bends INSIDE a diagonal band are not a defect: the renderer replaces
	# that whole staircase with one straight 45° ribbon, so the eye never
	# sees the corners. Only uncovered corners count.
	var covered := {}
	for path: Array in LineSpecs.diagonal_runs(roads):
		for pos: Vector2i in path:
			covered[pos] = true
	var straight := 0
	var bends := 0
	var blobs := 0
	var stubs := 0
	for pos: Vector2i in roads:
		var links: Array[Vector2i] = []
		for offset: Vector2i in ORTHOGONAL:
			if roads.has(pos + offset):
				links.append(offset)
		if links.size() == 1:
			stubs += 1     # a dead end renders as a capped "loose end"
		if links.size() == 2 and not covered.has(pos):
			if links[0] == -links[1]:
				straight += 1
			else:
				bends += 1
		if roads.has(pos + Vector2i(1, 0)) and roads.has(pos + Vector2i(0, 1)) \
				and roads.has(pos + Vector2i(1, 1)):
			blobs += 1
	return {"tiles": roads.size(), "lonely": lonely, "stubs": stubs,
		"components": components, "largest": largest, "blobs": blobs,
		"bend_pct": 0 if straight + bends == 0
			else roundi(100.0 * float(bends) / float(straight + bends))}


## Drop road tiles with no orthogonal neighbour at all: a lone tile renders
## as a capped stub sitting in a field. They come from OSM ways so short
## they rasterise to a single tile — real, but below this map's resolution.
static func _hd_trim_dots() -> void:
	var lonely: Array[Vector2i] = []
	for pos: Vector2i in City.model.roads:
		var linked := false
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			if City.model.roads.has(pos + offset):
				linked = true
				break
		if not linked:
			lonely.append(pos)
	for pos: Vector2i in lonely:
		City.model.remove_road(pos)
		City.dirty_tiles[pos] = true


## All three networks down one trench; returns the corridor's tiles.
static func _hd_run3(waypoints: Array) -> Array[Vector2i]:
	_hd_run("heat", waypoints)
	_hd_run("water", waypoints)
	return _hd_run("cable", waypoints)


## Walk a corridor and seat a supply trio every `spacing` tiles —
## Ortsnetzstation, heat transfer station, water hub. Hand-picked
## coordinates stopped working once real streets crossed the city (a
## building may not sit on a road), so each one finds its own free tile
## beside the trench it taps.
static func _hd_supply_along(corridor: Array, spacing: int,
		heat: bool, water: bool = true) -> void:
	# one INDEPENDENT walk per kind: with 3 300 tiles of real street the
	# four seats beside a given corridor tile are often all asphalt, and a
	# shared walk let the substation take the one free tile and the heat
	# station miss out entirely (the city ended up with two).
	_hd_seat_every(corridor, spacing, "substation")
	if heat:
		_hd_seat_every(corridor, spacing, "heat_exchanger")
	if water:
		_hd_seat_every(corridor, spacing, "water_station")


static func _hd_seat_every(corridor: Array, spacing: int,
		kind: String) -> void:
	var since := spacing
	for tile: Vector2i in corridor:
		since += 1
		if since >= spacing and _hd_seat(kind, tile):
			since = 0


## Where a real footprint can actually stand. A centroid rounds onto the
## lane beside it often enough to matter — a 25 m tile is coarser than a
## Heidelberg street — so a building that lands on asphalt steps to its
## first free neighbour instead of being dropped. 24 % of the real
## footprints land on a street tile.
static func _hd_lot_near(pos: Vector2i) -> Vector2i:
	for offset: Vector2i in [Vector2i.ZERO, Vector2i(0, -1), Vector2i(0, 1),
			Vector2i(-1, 0), Vector2i(1, 0)]:
		if City.model.is_tile_free(pos + offset):
			return pos + offset
	return Vector2i(-1, -1)


## First free tile orthogonally beside a corridor tile, so the building
## taps the buried line. False when the street leaves no room — the walk
## just tries again further along.
static func _hd_seat(kind: String, at: Vector2i) -> bool:
	for offset: Vector2i in [Vector2i(0, -1), Vector2i(0, 1),
			Vector2i(-1, 0), Vector2i(1, 0)]:
		if City.place_building(kind, at + offset):
			return true
	return false


## Buried run along axis-aligned legs. Integer stepping is exact because
## every leg is axis-aligned (one component of the delta is zero).
## Deck one river crossing: the three columns around *centre*.x, walking
## out along y and decking only what is actually wet. The channel is a swept
## polyline, so its exact extent at a given x is whatever the sweep left —
## and three columns wide gives a diagonal street room to find the deck.
static func _hd_bridge_span(centre: Vector2i, reach: int = 12) -> int:
	var decked := 0
	var wet: Array[int] = []
	for dx in range(-1, 2):
		for dy in range(-reach, reach + 1):
			if City.model.set_bridge(centre + Vector2i(dx, dy)):
				decked += 1
				if dx == 0:
					wet.append(centre.y + dy)
	if wet.is_empty():
		return 0
	wet.sort()
	# The carriageway. Decking alone leaves a bare slab: the OSM street
	# network is laid from real geometry and does not happen to run down the
	# column we decked, so the crossing has to be paved explicitly — the
	# centre column plus a short ramp onto each bank to meet the streets.
	# Tiles already carrying something simply refuse, which is the ramp
	# finding its own length.
	for y in range(wet[0] - 4, wet[wet.size() - 1] + 5):
		City.build_road(Vector2i(centre.x, y))
	return decked


static func _hd_run(build: String, waypoints: Array) -> Array[Vector2i]:
	var laid: Array[Vector2i] = []
	for i in waypoints.size() - 1:
		var a: Vector2i = waypoints[i]
		var b: Vector2i = waypoints[i + 1]
		var steps: int = maxi(absi(b.x - a.x), absi(b.y - a.y))
		for s in steps + 1:
			var p: Vector2i = a if steps == 0 else a + (b - a) * s / steps
			laid.append(p)
			match build:
				"cable":
					City.build_cable(p, BuildingDefs.LINE_UNDERGROUND)
				"heat":
					City.build_heat_pipe(p, BuildingDefs.LINE_UNDERGROUND)
				"water":
					City.build_water_pipe(p, BuildingDefs.LINE_UNDERGROUND)
	return laid


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
