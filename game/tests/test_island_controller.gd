extends GdUnitTestSuite
## IslandController (power islands): SoC integration from the solved slack
## flow, charge-path curtailment, gas-before-shed reserve order, rolling
## shed/restore hysteresis, blackout + black-start, the gas former's
## stability floor. Pure rules — no solver, no City.

const ISLANDS := {"isl_b1": {"former": "b1", "former_kind": "battery",
	"zones": [], "devices": {}}}


static func _ctrl(soc := -1.0) -> IslandController:
	var ctrl := IslandController.new()
	ctrl.sync_islands(ISLANDS, {} if soc < 0.0 else {"b1": soc})
	return ctrl


static func _inp(overrides: Dictionary) -> Dictionary:
	var base := {"former_kind": "battery", "e_kwh": 100.0, "p_max_kw": 40.0,
		"slack_kw": 0.0, "zone_kw": {}, "renew_kw": 0.0, "gas_max_kw": 0.0,
		"former_down": false, "t": 0, "dt_h": 0.25}
	base.merge(overrides, true)
	return base


func test_sync_seeds_soc_and_prunes() -> void:
	var ctrl := _ctrl(0.8)
	assert_float(ctrl.soc_of("isl_b1")).is_equal(0.8)
	# a second sync never reseeds live state
	ctrl.state["isl_b1"]["soc"] = 0.3
	ctrl.sync_islands(ISLANDS, {"b1": 0.8})
	assert_float(ctrl.soc_of("isl_b1")).is_equal(0.3)
	# unseeded islands start at the backend-parity half charge
	var fresh := _ctrl()
	assert_float(fresh.soc_of("isl_b1")).is_equal(IslandController.SOC_START)
	# vanished islands drop their state
	ctrl.sync_islands({}, {})
	assert_bool(ctrl.state.is_empty()).is_true()


func test_soc_integrates_solved_slack_flow_both_directions() -> void:
	var ctrl := _ctrl(0.5)
	# discharge 40 kW for 15 min on 100 kWh: -10 kWh -> 0.4
	ctrl.update_island("isl_b1", _inp({"slack_kw": 40.0,
		"zone_kw": {"z": 10.0}, "renew_kw": 0.0}))
	assert_float(ctrl.soc_of("isl_b1")).is_equal_approx(0.4, 0.0001)
	# charge (negative slack) raises it again
	ctrl.update_island("isl_b1", _inp({"slack_kw": -20.0,
		"zone_kw": {"z": 10.0}, "renew_kw": 40.0}))
	assert_float(ctrl.soc_of("isl_b1")).is_equal_approx(0.45, 0.0001)


func test_surplus_beyond_charge_cap_curtails_renewables() -> void:
	var ctrl := _ctrl(0.5)
	# 100 kW renewables vs 10 kW demand: battery absorbs its p_max 40,
	# the rest is curtailed -> factor (10+40)/100
	ctrl.update_island("isl_b1", _inp({"zone_kw": {"z": 10.0},
		"renew_kw": 100.0}))
	assert_float(ctrl.curtail_of("isl_b1")).is_equal_approx(0.5, 0.0001)
	# nearly-full battery: headroom, not p_max, caps the charge path
	var full := _ctrl(0.99)
	full.update_island("isl_b1", _inp({"zone_kw": {"z": 10.0},
		"renew_kw": 100.0}))
	# headroom = 0.01*100/0.25 = 4 kW -> curtail (10+4)/100
	assert_float(full.curtail_of("isl_b1")).is_equal_approx(0.14, 0.0001)


func test_deficit_within_former_needs_no_shed() -> void:
	var ctrl := _ctrl(0.5)
	var labels := ctrl.update_island("isl_b1", _inp({
		"zone_kw": {"z": 30.0}, "renew_kw": 0.0}))
	assert_array(labels).is_empty()
	assert_float(ctrl.gas_kw_of("isl_b1")).is_equal(0.0)
	assert_bool(ctrl.zone_dark("isl_b1", "z")).is_false()


func test_reserve_gas_starts_before_shedding() -> void:
	var ctrl := _ctrl(0.5)
	# 100 kW demand, battery covers 40, reserve gas must pick up the 60
	var labels := ctrl.update_island("isl_b1", _inp({
		"zone_kw": {"z": 100.0}, "gas_max_kw": 100.0}))
	assert_array(labels).is_empty()
	assert_float(ctrl.gas_kw_of("isl_b1")).is_equal_approx(60.0, 0.0001)
	assert_bool(ctrl.zone_dark("isl_b1", "z")).is_false()


func test_shed_rotates_through_zones() -> void:
	var ctrl := _ctrl(0.5)
	var zones := {"za": 30.0, "zb": 30.0, "zc": 30.0}
	# 90 kW vs 40 kW battery: 50 uncovered -> za+zb shed (rotation start 0)
	var labels := ctrl.update_island("isl_b1", _inp({"zone_kw": zones}))
	assert_array(labels).contains(["shed"])
	assert_bool(ctrl.zone_dark("isl_b1", "za")).is_true()
	assert_bool(ctrl.zone_dark("isl_b1", "zb")).is_true()
	assert_bool(ctrl.zone_dark("isl_b1", "zc")).is_false()
	# the pointer advanced so the NEXT shortfall starts at a later zone
	assert_int(int(ctrl.state["isl_b1"]["rotate"])).is_equal(1)


func test_empty_battery_stops_discharging_and_sheds() -> void:
	var ctrl := _ctrl(IslandController.SOC_RESERVE)  # at the reserve floor
	ctrl.update_island("isl_b1", _inp({"zone_kw": {"z": 30.0}}))
	# discharge capability 0 below the reserve -> the whole zone sheds
	assert_bool(ctrl.zone_dark("isl_b1", "z")).is_true()


func test_restore_one_zone_with_headroom() -> void:
	var ctrl := _ctrl(0.5)
	var zones := {"za": 30.0, "zb": 30.0, "zc": 30.0}
	ctrl.update_island("isl_b1", _inp({"zone_kw": zones}))  # sheds za+zb
	# sun comes back: 200 kW renewables -> restore, but only ONE per step
	var labels := ctrl.update_island("isl_b1", _inp({"zone_kw": zones,
		"renew_kw": 200.0}))
	assert_array(labels).contains(["restore"])
	var dark := 0
	for zone_id: String in zones:
		if ctrl.zone_dark("isl_b1", zone_id):
			dark += 1
	assert_int(dark).is_equal(1)


func test_overload_streak_collapses_island_then_black_start() -> void:
	var ctrl := _ctrl(0.5)
	# solved slack way beyond rating, three steps running -> blackout;
	# use charge direction so SoC does not drain into the empty-collapse path
	var labels: Array[String] = []
	for t in IslandController.OVERLOAD_TRIP_STREAK:
		labels = ctrl.update_island("isl_b1", _inp({"slack_kw": -100.0,
			"zone_kw": {"z": 10.0}, "renew_kw": 120.0, "t": t}))
	assert_array(labels).contains(["blackout"])
	assert_bool(ctrl.zone_dark("isl_b1", "z")).is_true()
	# dark island charges from renewables (curtailed to the charge cap)
	# until RESTART_SOC, then black-starts
	var restarted := false
	for t in range(10, 30):
		var soc := ctrl.soc_of("isl_b1")
		var charge_cap: float = minf(40.0, (1.0 - soc) * 100.0 / 0.25)
		var out := ctrl.update_island("isl_b1", _inp({
			"slack_kw": -charge_cap, "zone_kw": {"z": 10.0},
			"renew_kw": 50.0, "t": t}))
		if out.has("black_start"):
			restarted = true
			break
	assert_bool(restarted).is_true()
	assert_bool(ctrl.zone_dark("isl_b1", "z")).is_false()


func test_empty_battery_under_load_collapses() -> void:
	var ctrl := _ctrl(0.02)
	# still asked to discharge with (almost) nothing left -> collapse
	var labels := ctrl.update_island("isl_b1", _inp({"slack_kw": 10.0,
		"zone_kw": {"z": 10.0}}))
	assert_array(labels).contains(["blackout"])


func test_former_down_darkens_island_until_repair() -> void:
	var ctrl := _ctrl(0.5)
	var labels := ctrl.update_island("isl_b1", _inp({
		"former_down": true, "zone_kw": {"z": 10.0}, "t": 0}))
	assert_array(labels).contains(["blackout"])
	assert_float(ctrl.curtail_of("isl_b1")).is_equal(0.0)
	# repaired: battery at half charge black-starts right away
	labels = ctrl.update_island("isl_b1", _inp({"zone_kw": {"z": 10.0},
		"t": 1}))
	assert_array(labels).contains(["black_start"])


func test_gas_former_keeps_stability_floor_and_restarts_on_timer() -> void:
	var ctrl := IslandController.new()
	ctrl.sync_islands({"isl_g1": {"former": "g1", "former_kind": "gas_plant",
		"zones": [], "devices": {}}}, {})
	# 500 kW renewables vs 100 kW demand on a 2 MW machine: the floor is
	# 100 kW, so ALL renewables curtail (allowed = 100-100 = 0)
	ctrl.update_island("isl_g1", _inp({
		"former_kind": "gas_plant", "p_max_kw": 2000.0,
		"zone_kw": {"z": 100.0}, "renew_kw": 500.0}))
	assert_float(ctrl.curtail_of("isl_g1")).is_equal(0.0)
	assert_bool(ctrl.zone_dark("isl_g1", "z")).is_false()
	# sustained overload -> blackout, restart on the cooldown timer
	for t in IslandController.OVERLOAD_TRIP_STREAK:
		ctrl.update_island("isl_g1", _inp({"former_kind": "gas_plant",
			"p_max_kw": 2000.0, "slack_kw": 3000.0,
			"zone_kw": {"z": 100.0}, "t": t}))
	assert_bool(ctrl.is_blackout("isl_g1")).is_true()
	var restart_at := int(ctrl.state["isl_g1"]["restart_at"])
	var out := ctrl.update_island("isl_g1", _inp({
		"former_kind": "gas_plant", "p_max_kw": 2000.0,
		"zone_kw": {"z": 100.0}, "t": restart_at}))
	assert_array(out).contains(["black_start"])
	assert_bool(ctrl.zone_dark("isl_g1", "z")).is_false()


func test_backend_reported_soc_is_authoritative() -> void:
	var ctrl := _ctrl(0.5)
	# a reported soc (contract 1.2 grid_forming) replaces local integration:
	# the slack flow says "drain" but the backend's book says 0.9
	ctrl.update_island("isl_b1", _inp({"slack_kw": 40.0, "soc": 0.9,
		"zone_kw": {"z": 10.0}}))
	assert_float(ctrl.soc_of("isl_b1")).is_equal(0.9)
	# absent report -> the local fallback integrates as before
	ctrl.update_island("isl_b1", _inp({"slack_kw": 40.0,
		"zone_kw": {"z": 10.0}}))
	assert_float(ctrl.soc_of("isl_b1")).is_equal_approx(0.8, 0.0001)
