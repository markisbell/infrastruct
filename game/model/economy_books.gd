class_name EconomyBooks
extends RefCounted
## Economy engine (Phase 7 task 1; rationale in tools/balancing/economy.md),
## extracted from City (Phase-2 refactor plan). Owns the cash-flow books,
## the fractional-euro accumulator, loans, and every tariff/fuel rate.
## Cash coupling: mutators RETURN whole euros — the caller owns the int
## money balance. Balancing contract: change a constant, rerun
## --smoke=economy, commit the regenerated CSV with it.

const TARIFF_ELEC_KWH := 0.35     # income per kWh actually delivered
const TARIFF_CHARGE_KWH := 0.38   # DC fast charging per kWh (commercial pass)
const TARIFF_HEAT_KWH := 0.16
const TARIFF_WATER_M3 := 3.0
const BASE_FEE_HOUSE_DAY := 0.4   # Grundgebühr per connected household
const FUEL_PRICE_KWH := 0.09      # gas, per kWh fuel
const GRID_IMPORT_KWH := 0.22     # wholesale purchase at the slack
const GRID_FEEDIN_KWH := 0.06     # feed-in revenue for exports
const GAS_PLANT_ETA := 0.40
const CHP_ETA_TOTAL := 0.88
const BOILER_ETA_FALLBACK := 0.95 # when the solver sends no p_fuel_kw
const LOAN_RATE_DAY := 0.0005     # ~18 % p.a., charged daily on the balance
const STEP_H := 0.25              # 15-min step in hours
const STEPS_PER_DAY := 96

## Daily cash-flow breakdown (today accumulates, yesterday is the closed
## day the budget panel shows) + cumulative since scenario start.
var today := {}
var yesterday := {}
var total := {}
var loans := 0.0
var day := -1
var _cash_frac := 0.0


## Fractional euros accumulate; whole euros are returned for the caller's
## int balance.
func apply(category: String, delta_eur: float) -> int:
	today[category] = today.get(category, 0.0) + delta_eur
	total[category] = total.get(category, 0.0) + delta_eur
	_cash_frac += delta_eur
	var whole := int(_cash_frac)
	_cash_frac -= whole
	return whole


## Clock-driven costs: upkeep + Grundgebühr + loan interest accrue every
## step regardless of network state. Returns {cash: int, day_rolled: bool}
## — the caller rolls its own midnight work (events) on day_rolled.
func tick(t: int, upkeep_day: float, houses: int) -> Dictionary:
	var step_day := t / STEPS_PER_DAY
	var rolled := step_day != day
	if rolled:
		day = step_day
		yesterday = today.duplicate()
		today = {}
	var cash := 0
	if upkeep_day > 0.0:
		cash += apply("cost_upkeep", -upkeep_day / STEPS_PER_DAY)
	if houses > 0:  # standing charges (Grundgebühr)
		cash += apply("income_base", houses * BASE_FEE_HOUSE_DAY / STEPS_PER_DAY)
	if loans > 0.0:
		cash += apply("cost_interest", -loans * LOAN_RATE_DAY / STEPS_PER_DAY)
	return {"cash": cash, "day_rolled": rolled}


func take_loan(amount: float) -> int:
	loans += amount
	return apply("loan_in", amount)


## Repayment is clamped to the outstanding balance AND the cash on hand.
## Returns {repaid: float, cash: int}.
func repay_loan(amount: float, cash_available: int) -> Dictionary:
	var repaid := minf(minf(amount, loans), float(cash_available))
	if repaid <= 0.0:
		return {"repaid": 0.0, "cash": 0}
	loans -= repaid
	return {"repaid": repaid, "cash": apply("loan_out", -repaid)}


## Books a cost WITHOUT touching cash — for spends already paid straight
## from the money balance (repair crews).
func book_paid_cost(category: String, cost_eur: float) -> void:
	today[category] = today.get(category, 0.0) - cost_eur
	total[category] = total.get(category, 0.0) - cost_eur


func reset() -> void:
	today = {}
	yesterday = {}
	total = {}
	loans = 0.0
	day = -1
	_cash_frac = 0.0


# ─── pure per-step rate formulas (the rules the suite pins) ───

## Zones bill only the net IMPORT actually delivered: at sunny noon a
## rooftop-PV zone exports (negative net load) and nothing is sold.
static func delivered_elec_eur(net_kw: float) -> float:
	return maxf(0.0, net_kw) * STEP_H * TARIFF_ELEC_KWH


## A charging park bills every delivered kWh at the charging tariff; the
## energy itself was bought via the slack settlement below — the spread
## is the site operator's margin (commercial pass 2026-08-06).
static func charging_eur(kw: float) -> float:
	return maxf(0.0, kw) * STEP_H * TARIFF_CHARGE_KWH


## The slack settles wholesale: positive import buys, negative sells.
## Returns [category, delta_eur] (delta 0 at exactly zero flow).
static func slack_settlement(import_kw: float) -> Array:
	if import_kw > 0.0:
		return ["cost_grid", -import_kw * STEP_H * GRID_IMPORT_KWH]
	return ["income_feedin", -import_kw * STEP_H * GRID_FEEDIN_KWH]


static func gas_fuel_eur(p_kw: float) -> float:
	return p_kw / GAS_PLANT_ETA * STEP_H * FUEL_PRICE_KWH


static func heat_income_eur(q_kw: float) -> float:
	return q_kw * STEP_H * TARIFF_HEAT_KWH


## Boiler fuel prefers the SOLVED p_fuel_kw; CHP fuel covers heat + the
## coupled electricity over total efficiency.
static func boiler_fuel_kw(q_kw: float, detail: Dictionary) -> float:
	return float(detail.get("p_fuel_kw", q_kw / BOILER_ETA_FALLBACK))


static func chp_fuel_kw(q_kw: float, p_el_kw: float) -> float:
	return (q_kw + p_el_kw) / CHP_ETA_TOTAL


static func fuel_eur(fuel_kw: float) -> float:
	return fuel_kw * STEP_H * FUEL_PRICE_KWH


## Household m³ actually delivered (PDD fraction) earn the tariff —
## fire/leak draws are losses, never billed.
static func water_income_eur(household_m3h: float, fraction: float) -> float:
	return household_m3h * fraction * STEP_H * TARIFF_WATER_M3
