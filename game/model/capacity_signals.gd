class_name CapacitySignals
extends RefCounted
## Capacity-signal threshold table (Phase-2 extraction from City): the ONE
## place that decides when an element is "approaching its limit" (amber
## warn) or "critical" (red). City assembles the marker dicts; these pure
## classifiers return "" | "warn" | "crit".

const LINE_WARN := 80.0       # percent of thermal rating (contract edges)
const LINE_CRIT := 95.0
const TRAFO_WARN := 70.0      # solved 20/0.4 kV element loading
const TRAFO_CRIT := 90.0
const GRID_WARN := 80.0       # import vs the 110/20 kV MVA rating
const GRID_CRIT := 95.0
const WATER_WARN_BAR := 2.4   # W 400-1: pressure approaching the minimum
const WATER_CRIT_BAR := 2.0
const HEAT_MARGIN_C := 4.0    # supply temp scraping min + margin


static func line_level(loading: float) -> String:
	if loading >= LINE_CRIT:
		return "crit"
	if loading >= LINE_WARN:
		return "warn"
	return ""


## A tripped substation is always critical (the marker reads TRIP).
static func trafo_level(loading: float, tripped: bool) -> String:
	if tripped or loading >= TRAFO_CRIT:
		return "crit"
	if loading >= TRAFO_WARN:
		return "warn"
	return ""


static func grid_level(percent: float) -> String:
	if percent >= GRID_CRIT:
		return "crit"
	if percent >= GRID_WARN:
		return "warn"
	return ""


## Zero/negative supply temp = no solved sample -> no signal.
static func heat_level(t_supply: float, t_min: float) -> String:
	if t_supply <= 0.0 or t_supply >= t_min + HEAT_MARGIN_C:
		return ""
	return "crit" if t_supply < t_min else "warn"


## Negative pressure = no solved sample -> no signal.
static func water_level(p_bar: float) -> String:
	if p_bar < 0.0 or p_bar >= WATER_WARN_BAR:
		return ""
	return "crit" if p_bar < WATER_CRIT_BAR else "warn"
