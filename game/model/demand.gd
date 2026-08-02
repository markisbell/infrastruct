class_name DemandModel
extends RefCounted
## Household demand v2 (ROADMAP Phase 6 task 1): electricity and water come
## from the bundled residential profile pack (data/profiles/ — electricity
## derived from rtpowerflow's LPG household library, diversity-smeared;
## rtwaterflow's W 410 archetype shapes), composed by
## season x day kind at native 15-min resolution. Space heating stays the
## live physics formula (weather-driven — that IS its seasonality); DHW
## follows LPG warm-water day shapes (2026-08-02: the same simulated
## households as the electricity curves). v1 curves and the VDI-style DHW
## staircase remain as the pack-less fallbacks.

const STEPS_PER_DAY := 96
const DAYS_PER_YEAR := 360          # GameClock's year
const PACK_PATH := "res://data/profiles/residential_pack.json"

## Diversified mean electric load per house, kW (pack factors are mean 1.0).
## Peak-calibrated: the LPG shapes reach ~3.1x mean on winter workday
## evenings, so 0.58 keeps the composed evening peak near the ~1.8 kW/house
## the station/feeder sizing was designed around (1.05 belonged to the much
## flatter BDEW H0 shape — same peak, unrealistically high yearly energy).
const HOUSE_MEAN_KW := 0.58

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


## Household composition (user direction: the residential picture must
## include local rooftop solar and electric vehicles, like rtpowerflow's
## households). Shares are diversified expectations, not per-house state.
const PV_SHARE := 0.4        # fraction of houses with a rooftop plant
## Rooftop plants span 5-15 kWp across the fleet (user spec 2026-08-01);
## the diversified composition uses the fleet mean.
const PV_KWP_MIN := 5.0
const PV_KWP_MAX := 15.0
const PV_KWP_MEAN := (PV_KWP_MIN + PV_KWP_MAX) / 2.0
const EV_SHARE := 0.5        # fraction of houses with a home charger
## 22-kW wallboxes (user spec 2026-08-01); the pack shape charges the same
## ~24 kWh session in half the window, so daily energy stays put while the
## coincident peak sharpens.
const EV_CHARGER_KW := 22.0

## NET zone load at the transformer: households + EV charging − rooftop PV.
## Negative = the zone exports (sunny noon), which the solver handles as a
## negative load. Billing uses max(0, ·) — exported energy isn't sold twice.
static func zone_demand_kw(n_houses: int, t: int) -> float:
	var base := n_houses * HOUSE_MEAN_KW * house_factor(t)
	var ev := n_houses * EV_SHARE * EV_CHARGER_KW * ev_factor(t)
	var pv := n_houses * PV_SHARE * PV_KWP_MEAN * pv_availability(t)
	return base + ev - pv


## Expected per-EV load as a fraction of charger power (pack shape:
## gaussian arrivals x charge window, peaks ~19:00 on workdays).
static func ev_factor(t: int) -> float:
	var pack := _get_pack()
	if pack.has("ev"):
		return float(pack["ev"][day_kind(t)][t % STEPS_PER_DAY])
	var hour := (t * 15 % 1440) / 60
	return 0.45 if (hour >= 18 and hour < 21) else (0.1 if hour >= 21 or hour < 2 else 0.02)


## PV yield as a fraction of kWp — REAL measured day shapes from
## rtpowerflow's rooftop plant (real_pv_days.json via the profile pack),
## scaled by season (the measurement campaign covers late spring/summer).
## Drives rooftop PV in the zone composition AND the solar parks' dispatch.
## WHICH measured day a game day gets follows the WEATHER's cloud field
## (energy-sorted shapes, dim day <-> dim shape — the sky, the visual cloud
## cover and the dispatch agree); without an injected weather (unit tests,
## fixtures) the legacy per-day hash pick applies.
## Winter shortens BOTH the amplitude and the DAYLIGHT WINDOW: the summer
## shapes are time-compressed toward noon (a 4-pm winter sunset), otherwise
## a January evening would still show phantom summer sun.

## Solar-park orientation (2026-08-02): building `rot` is MEANINGFUL for
## parks — rot 0 faces SOUTH (+Z, the noon sun; optimal and the default,
## so every pre-existing placement keeps its old yield), CCW quarter
## turns map 1=W, 2=N, 3=E. East/West shift the day curve by ∓1.5 h at
## ~12 % loss (the same ±1.5 h rtpowerflow's orientation mix uses);
## North is diffuse-only. Rooftop fleets stay pv_availability (mixed
## orientations are already priced into the measured shapes).
const PV_ROT_FACING: Array[String] = ["S", "W", "N", "E"]


static func pv_park_availability(t: int, rot: int) -> float:
	match PV_ROT_FACING[((rot % 4) + 4) % 4]:
		"E":
			return 0.88 * pv_availability(t + 6)
		"W":
			return 0.88 * pv_availability(maxi(t - 6, 0))
		"N":
			return 0.50 * pv_availability(t)
		_:
			return pv_availability(t)


## Injected by City (and re-injected on scenario start + save-load, where
## the WeatherSystem is recreated with the scenario's seed).
static var weather: WeatherSystem = null
static var _pv_order: Array[int] = []  # pack day indices, dimmest first


static func _pv_day_index(days: Array, day: int) -> int:
	if weather == null:
		return (day * 2654435761) % days.size()
	if _pv_order.size() != days.size():
		var ranked: Array = []
		for i in days.size():
			var total := 0.0
			for v: Variant in days[i]:
				total += float(v)
			ranked.append([total, i])
		ranked.sort()
		_pv_order.clear()
		for pair: Array in ranked:
			_pv_order.append(pair[1])
	var rank := roundi(weather.clearness_day(day) * float(_pv_order.size() - 1))
	return _pv_order[clampi(rank, 0, _pv_order.size() - 1)]


static func pv_availability(t: int) -> float:
	var pack := _get_pack()
	var doy := (t / STEPS_PER_DAY) % DAYS_PER_YEAR
	var season := 0.5 - 0.5 * cos(TAU * float(doy) / DAYS_PER_YEAR)  # 0 winter..1 summer
	var seasonal := lerpf(0.22, 1.0, season)
	var day_scale := lerpf(0.62, 1.0, season)  # ~10 h winter vs ~16 h summer day
	var stretched := 48.0 + (float(t % STEPS_PER_DAY) - 48.0) / day_scale
	if stretched < 0.0 or stretched > 95.0:
		return 0.0
	if pack.has("pv_days"):
		var days: Array = pack["pv_days"]
		var day := t / STEPS_PER_DAY
		var shape: Array = days[_pv_day_index(days, day)]
		return float(shape[int(stretched)]) * seasonal
	# fallback: clear-sky bell
	var frac := stretched / STEPS_PER_DAY
	var elevation := 1.0 - absf(frac - 0.5) / 0.3
	return maxf(elevation, 0.0) * seasonal


# ─── heat (Phase 4, unchanged): space heating follows outdoor temperature
# (heating-limit curve at 16 °C), DHW is a VDI-style day shape ───

const HOUSE_HEAT_DESIGN_KW := 4.0   # SH design load per house at -14 °C
const HOUSE_DHW_KW := 0.25          # diversified DHW average per house


## Expected DHW draw factor (mean ~1.0 over the week) — LPG warm-water day
## shapes via the pack (the same simulated households as the electricity
## curves); the VDI-style staircase stays as the pack-less fallback.
static func dhw_factor(t: int) -> float:
	var pack := _get_pack()
	if pack.has("dhw"):
		return float(pack["dhw"][day_kind(t)][t % STEPS_PER_DAY])
	var dhw_hour := ((t * 15) % 1440) / 60
	return 1.8 if (dhw_hour >= 6 and dhw_hour < 9) \
		else (1.5 if (dhw_hour >= 18 and dhw_hour < 21) else 0.7)


static func heat_zone_demand_kw(n_houses: int, t: int, temp_c: float) -> float:
	var sh_factor := clampf((16.0 - temp_c) / 30.0, 0.0, 1.15)
	var minute := (t * 15) % 1440
	var night_setback := 0.82 if (minute < 300 or minute >= 1380) else 1.0
	return n_houses * (HOUSE_HEAT_DESIGN_KW * sh_factor * night_setback
		+ HOUSE_DHW_KW * dhw_factor(t))


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
