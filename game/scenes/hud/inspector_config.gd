class_name InspectorConfig
extends RefCounted
## Per-kind inspector graph configuration (Phase-6 refactor plan,
## extracted from hud.gd): which telemetry series, unit, axis title and
## dashed limit lines each element type gets (the rtpowerflow quantities),
## plus the per-house sampled-household series builder. Pure statics —
## no autoload reads, so the tables are unit-testable.


## Per-kind graph configuration: which telemetry series, unit, axis title,
## and dashed limit lines (the rtpowerflow quantities per element type).
## island_former: this battery forms a microgrid island (power islands M4)
## — its panel shows the solved island balance against ±p_max_kw with the
## SoC as the secondary graph (the EMS gauge) instead of SoC alone.
static func config_for(kind: String, id: String, model: WorldModel,
		grid_capacity_override: float, island_former := false) -> Dictionary:
	var kw_series: Array[Dictionary] = [
		{"key": "dev:" + id, "label": "P", "color": Color(0.95, 0.68, 0.21)}]
	match kind:
		"grid_connection":
			var capacity: float = grid_capacity_override \
				if grid_capacity_override > 0.0 \
				else BuildingDefs.get_def(kind)["capacity_kw"]
			var limits: Array[Dictionary] = []
			if capacity <= 1_000.0:  # a 10-MVA line would flatten the curve
				limits = [{"value": capacity, "label": "%.0f kW cap" % capacity,
					"color": Color(0.95, 0.3, 0.25)}]
			return {"title": "Grid connection 110/20 kV", "unit": "kW", "dec": 0,
				"base_zero": false, "y": "Import / export [kW]", "limits": limits,
				"series": [{"key": "dev:" + id, "label": "Import",
					"color": Color(0.95, 0.45, 0.3)}]}
		"substation":
			return {"title": "Substation 20/0.4 kV (%.0f kVA)"
					% float(model.building_params(id).get("rating_kva",
						BuildingDefs.get_def(kind).get("rating_kva", 630.0))),
				"unit": "%", "dec": 0, "base_zero": true, "y": "Trafo loading [%]",
				"limits": [{"value": 100.0, "label": "rating",
					"color": Color(0.95, 0.3, 0.25)}],
				"series": [{"key": "trafo:" + id, "label": "Loading",
					"color": Color(0.31, 0.76, 0.97)}]}
		"gas_plant", "wind_farm", "solar_park":
			return {"title": kind.capitalize(), "unit": "kW", "dec": 0,
				"base_zero": true, "y": "P [kW]", "limits": [], "series": kw_series}
		"chp_plant", "boiler_plant", "heat_pump_plant":
			return {"title": kind.capitalize(), "unit": "kW", "dec": 0,
				"base_zero": true, "y": "Q [kW]", "limits": [],
				"series": [{"key": "dev:" + id, "label": "Q",
					"color": Color(0.9, 0.35, 0.25)}]}
		"battery", "heat_storage", "water_tower":
			if kind == "battery" and island_former:
				var p_max := float(model.building_params(id)
					.get("p_max_kw", 400.0))
				return {"title": "Battery — grid-forming", "unit": "kW",
					"dec": 1, "base_zero": false, "y": "Island balance [kW]",
					"limits": [
						{"value": p_max, "label": "p_max",
							"color": Color(0.95, 0.3, 0.25)},
						{"value": -p_max, "label": "-p_max",
							"color": Color(0.95, 0.3, 0.25)}],
					"series": [{"key": "dev:" + id, "label": "Balance",
						"color": Color(0.95, 0.68, 0.21)}],
					"secondary": {"unit": "%", "dec": 0, "base_zero": true,
						"y": "SoC [%]", "limits": [],
						"series": [{"key": "soc:" + id, "label": "SoC",
							"color": Color(0.62, 0.44, 0.86)}]}}
			return {"title": kind.capitalize(), "unit": "%", "dec": 0,
				"base_zero": true, "y": "State of charge [%]", "limits": [],
				"series": [{"key": "soc:" + id, "label": "SoC",
					"color": Color(0.62, 0.44, 0.86)}]}
		"charging_park":
			var stalls := int(model.building_params(id).get("stalls", 8))
			var stall_kw := float(model.building_params(id).get("stall_kw", 175.0))
			return {"title": "Charging park (%d x %.0f kW)" % [stalls, stall_kw],
				"unit": "kW", "dec": 0, "base_zero": true, "y": "Site load [kW]",
				"limits": [{"value": stalls * stall_kw, "label": "all stalls",
					"color": Color(0.95, 0.3, 0.25)}],
				"series": [{"key": "d:cp_" + id, "label": "Load",
					"color": Color(0.2, 0.75, 0.85)}]}
		"heat_exchanger":
			return {"title": "Heat exchanger", "unit": "°C", "dec": 1,
				"base_zero": false, "y": "Supply temperature [°C]",
				"limits": [{"value": 60.0, "label": "min 60 °C",
					"color": Color(0.35, 0.55, 0.95)}],
				"series": [{"key": "t:hz_" + id, "label": "T supply",
					"color": Color(0.95, 0.55, 0.2)}]}
		"water_station":
			return {"title": "Water station", "unit": "bar", "dec": 2,
				"base_zero": false, "y": "Zone pressure [bar]",
				"limits": [{"value": 2.0, "label": "min 2.0 bar",
					"color": Color(0.95, 0.3, 0.25)}],
				"series": [{"key": "pb:wz_" + id, "label": "p",
					"color": Color(0.25, 0.75, 0.5)}]}
		"well", "pumping_station":
			return {"title": kind.capitalize(), "unit": "m³/h", "dec": 1,
				"base_zero": true, "y": "Flow [m³/h]", "limits": [],
				"series": [{"key": "q:" + id, "label": "Q",
					"color": Color(0.25, 0.75, 0.5)}]}
	return {}


## THE sampled household on this lot (per-house individuality, user
## request): its LPG archetype's own curve, its concrete 22-kW charging
## block, its rooftop size/orientation, its heat/water volumes. Real
## telemetry still only exists per zone — these are the deterministic
## samples behind the mix. Returns {config, subtitle}.
static func house_config(pos: Vector2i, day: int, weather: WeatherSystem,
		zone: String) -> Dictionary:
	# THE sampled household on this lot (per-house individuality,
	# user request): its LPG archetype's own curve, its concrete
	# 22-kW charging block, its rooftop size/orientation, its
	# heat/water volumes. Real telemetry still only exists per
	# zone — these are the deterministic samples behind the mix.
	var profile := DemandModel.house_profile(pos)
	var net: Array[float] = []
	var net_prev: Array[float] = []
	var consumption: Array[float] = []
	var pv: Array[float] = []
	var heat: Array[float] = []
	var heat_prev: Array[float] = []
	var water_l: Array[float] = []
	var water_l_prev: Array[float] = []
	for i in 96:
		var t0 := day * 96 + i
		var t1 := maxi(day - 1, 0) * 96 + i
		var base0 := DemandModel.house_base_kw(profile, t0) \
			+ DemandModel.house_ev_kw(profile, t0)
		var pv0 := DemandModel.house_pv_kw(profile, t0)
		consumption.append(base0)
		pv.append(pv0)
		net.append(base0 - pv0)
		net_prev.append(DemandModel.house_base_kw(profile, t1)
			+ DemandModel.house_ev_kw(profile, t1)
			- DemandModel.house_pv_kw(profile, t1))
		# heat (SH physics + LPG DHW shape) and water follow the
		# seeded weather — yesterday's curves use yesterday's temps
		heat.append(DemandModel.house_heat_kw(
			profile, t0, weather.temp_c(t0)))
		heat_prev.append(DemandModel.house_heat_kw(
			profile, t1, weather.temp_c(t1)))
		water_l.append(1000.0 * DemandModel.house_water_m3h(
			profile, t0, weather.temp_c(t0)))
		water_l_prev.append(1000.0 * DemandModel.house_water_m3h(
			profile, t1, weather.temp_c(t1)))
	var tags: String = profile["label"]
	if profile["has_ev"]:
		tags += " · EV 22 kW"
	if profile["has_pv"]:
		tags += " · PV %.1f kWp %s" % [profile["pv_kwp"],
			DemandModel.PV_ROT_FACING[profile["pv_rot"]]]
	if zone != "":
		tags += " · " + zone
	return {"config": {"title": "House (%d, %d)" % [pos.x, pos.y],
		"unit": "kW", "dec": 2, "base_zero": false,
		"y": "This household [kW]", "limits": [],
		"series": [
			{"label": "Net import", "color": Color(0.95, 0.68, 0.21),
				"values": net, "values_prev": net_prev},
			{"label": "Consumption", "color": Color(0.55, 0.65, 0.9),
				"values": consumption},
			{"label": "PV infeed", "color": Color(0.4, 0.8, 0.45),
				"values": pv},
			{"label": "Heat", "color": Color(0.9, 0.35, 0.25),
				"values": heat, "values_prev": heat_prev},
		],
		"secondary": {"unit": "L/h", "dec": 1, "base_zero": true,
			"y": "Water [L/h]", "limits": [],
			"series": [{"label": "Water",
				"color": Color(0.25, 0.75, 0.5),
				"values": water_l, "values_prev": water_l_prev}]},
		},
		"subtitle": tags if zone != "" else tags + " · no substation coverage"}


## One commercial lot's panel (commercial pass 2026-08-06): the sampled
## business's three curves — electricity, heat (process + space split is
## visible in summer: a food plant still steams), water on the secondary
## axis. Deterministic like the house panel; no per-lot telemetry exists.
static func commercial_config(pos: Vector2i, ctype: int, day: int,
		weather: WeatherSystem) -> Dictionary:
	var spec: Dictionary = DemandModel.COMMERCIAL_SPECS.get(ctype,
		DemandModel.COMMERCIAL_SPECS[1])
	var elec: Array[float] = []
	var elec_prev: Array[float] = []
	var heat: Array[float] = []
	var water_m3: Array[float] = []
	for i in 96:
		var t0 := day * 96 + i
		var t1 := maxi(day - 1, 0) * 96 + i
		elec.append(DemandModel.commercial_kw(ctype, pos, t0))
		elec_prev.append(DemandModel.commercial_kw(ctype, pos, t1))
		heat.append(DemandModel.commercial_heat_kw(ctype, pos, t0,
			weather.temp_c(t0)))
		water_m3.append(DemandModel.commercial_water_m3h(ctype, pos, t0))
	var scale := float(DemandModel.commercial_profile(pos)["scale"])
	return {"config": {"title": str(spec["label"]),
		"unit": "kW", "dec": 1, "base_zero": true,
		"y": "This business [kW]", "limits": [],
		"series": [
			{"label": "Electricity", "color": Color(0.95, 0.68, 0.21),
				"values": elec, "values_prev": elec_prev},
			{"label": "Heat", "color": Color(0.9, 0.35, 0.25),
				"values": heat},
		],
		"secondary": {"unit": "m3/h", "dec": 2, "base_zero": true,
			"y": "Water [m3/h]", "limits": [],
			"series": [{"label": "Water", "color": Color(0.25, 0.75, 0.5),
				"values": water_m3}]},
		},
		"subtitle": "%s x%.2f · (%d, %d)" % [str(spec["label"]), scale,
			pos.x, pos.y]}
