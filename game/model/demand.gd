class_name DemandModel
extends RefCounted
## Household demand v2 (ROADMAP Phase 6 task 1): electricity and water come
## from the bundled residential profile pack (data/profiles/ — BDEW H0 day
## types via demandlib; rtwaterflow's W 410 archetype shapes), composed by
## season x day kind at native 15-min resolution. Space heating stays the
## live physics formula (weather-driven — that IS its seasonality); DHW
## keeps its VDI-style day shape (the heat acceptance scenarios are
## temperature-calibrated). v1 curves remain as the pack-less fallback.

const STEPS_PER_DAY := 96
const DAYS_PER_YEAR := 360          # GameClock's year
const PACK_PATH := "res://data/profiles/residential_pack.json"

## Diversified mean electric load per house, kW (pack factors are mean 1.0;
## the composed evening winter peak lands near v1's 1.8 kW).
const HOUSE_MEAN_KW := 1.05

static var _pack := {}
static var _pack_state := 0  # 0 = unloaded, 1 = loaded, -1 = missing


static func _get_pack() -> Dictionary:
	if _pack_state == 0:
		_pack_state = -1
		if FileAccess.file_exists(PACK_PATH):
			var parsed: Variant = JSON.parse_string(
				FileAccess.get_file_as_string(PACK_PATH))
			if parsed is Dictionary:
				_pack = parsed
				_pack_state = 1
	return _pack


## "workday" | "saturday" | "sunday" — 7-day week over the sim-step clock.
static func day_kind(t: int) -> String:
	var dow := (t / STEPS_PER_DAY) % 7
	return "sunday" if dow == 6 else ("saturday" if dow == 5 else "workday")


## BDEW-style season bucket from the game's 360-day year
## (spring/autumn = transition).
static func season_key(t: int) -> String:
	var doy := (t / STEPS_PER_DAY) % DAYS_PER_YEAR
	if doy >= 270:
		return "winter"
	if doy >= 90 and doy < 180:
		return "summer"
	return "transition"


# ─── electricity ───

## Mean-1.0 profile factor for the current quarter hour.
static func house_factor(t: int) -> float:
	var pack := _get_pack()
	if pack.has("elec"):
		return float(pack["elec"]["%s_%s" % [season_key(t), day_kind(t)]][t % STEPS_PER_DAY])
	# fallback: v1 hourly double peak, rescaled to mean ~1.0
	var minute := (t * 15) % 1440
	var hour := minute / 60
	var within := float(minute % 60) / 60.0
	return lerpf(HOURLY_V1[hour], HOURLY_V1[(hour + 1) % 24], within) * 1.71


static func zone_demand_kw(n_houses: int, t: int) -> float:
	return n_houses * HOUSE_MEAN_KW * house_factor(t)


# ─── heat (Phase 4, unchanged): space heating follows outdoor temperature
# (heating-limit curve at 16 °C), DHW is a VDI-style day shape ───

const HOUSE_HEAT_DESIGN_KW := 4.0   # SH design load per house at -14 °C
const HOUSE_DHW_KW := 0.25          # diversified DHW average per house


static func heat_zone_demand_kw(n_houses: int, t: int, temp_c: float) -> float:
	var sh_factor := clampf((16.0 - temp_c) / 30.0, 0.0, 1.15)
	var minute := (t * 15) % 1440
	var night_setback := 0.82 if (minute < 300 or minute >= 1380) else 1.0
	var dhw_hour := (minute / 60) % 24
	var dhw_factor := 1.8 if (dhw_hour >= 6 and dhw_hour < 9) \
		else (1.5 if (dhw_hour >= 18 and dhw_hour < 21) else 0.7)
	return n_houses * (HOUSE_HEAT_DESIGN_KW * sh_factor * night_setback
		+ HOUSE_DHW_KW * dhw_factor)


# ─── water: archetype shape x weekend volume x seasonal swing (peak
# mid-July = game day 135) x hot-day irrigation surcharge ───

## Diversified average per house, m³/h (≈ 300 l/d per 2.5-person household).
const HOUSE_WATER_M3H := 0.0125


static func water_zone_demand_m3h(n_houses: int, t: int, temp_c: float) -> float:
	var factor: float
	var pack := _get_pack()
	if pack.has("water"):
		var water: Dictionary = pack["water"]
		var kind := day_kind(t)
		factor = float(water["shapes"][kind][t % STEPS_PER_DAY]) \
			* float(water.get(kind + "_factor", 1.0))
		var doy := (t / STEPS_PER_DAY) % DAYS_PER_YEAR
		factor *= 1.0 + float(water.get("season_amp", 0.0)) \
			* cos(TAU * float(doy - 135) / DAYS_PER_YEAR)
	else:
		var minute := (t * 15) % 1440
		var hour := minute / 60
		var within := float(minute % 60) / 60.0
		factor = lerpf(WATER_HOURLY_V1[hour], WATER_HOURLY_V1[(hour + 1) % 24], within)
	# hot-day surcharge (garden/shower): +40% at 30 °C, none below 20 °C
	var summer := 1.0 + clampf((temp_c - 20.0) / 25.0, 0.0, 0.4)
	return n_houses * HOUSE_WATER_M3H * factor * summer


# ─── v1 fallback shapes (kept for pack-less runs) ───

const HOURLY_V1: Array[float] = [
	0.36, 0.33, 0.31, 0.30, 0.31, 0.38,
	0.55, 0.72, 0.66, 0.55, 0.52, 0.55,
	0.58, 0.54, 0.50, 0.52, 0.62, 0.80,
	0.95, 1.00, 0.92, 0.78, 0.58, 0.44,
]

const WATER_HOURLY_V1: Array[float] = [
	0.35, 0.30, 0.28, 0.28, 0.35, 0.70,
	1.40, 1.90, 1.60, 1.20, 1.05, 1.15,
	1.30, 1.10, 0.95, 0.95, 1.05, 1.30,
	1.60, 1.75, 1.45, 1.05, 0.70, 0.45,
]
