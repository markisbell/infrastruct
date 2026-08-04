class_name SatisfactionModel
extends RefCounted
## Happiness v2 (Phase 6): per-network satisfaction 0..100 with MEMORY —
## outages hurt fast, clean supply heals slowly (weeks-scale), so a rough
## week keeps hurting after the lights come back. Extracted from City
## (Phase-2 refactor plan): pure rules over (hurt fraction, severity),
## no autoload reads.

const RECOVERY := 0.06  # per clean step (~6/day): weeks-scale memory
## Hurt rate per network — water outages hurt hardest (no substitute),
## heat scales with how cold it actually is (severity = cold factor).
const HURT_RATE := {"power": 9.0, "heat": 7.0, "water": 12.0}
const RECOVERY_SCALE := {"power": 1.0, "heat": 1.0, "water": 0.8}

var values := {"power": 100.0, "heat": 100.0, "water": 100.0}


## One sim step: hurt = affected-house fraction 0..1 (0 = clean step, which
## recovers); severity scales the hurt rate (heat passes its cold factor).
func apply_step(network: String, hurt: float, severity: float = 1.0) -> void:
	values[network] = clampf(values[network]
		- HURT_RATE[network] * severity * hurt
		+ (RECOVERY_SCALE[network] * RECOVERY if hurt == 0.0 else 0.0),
		0.0, 100.0)


## 0.12..1: how much the cold amplifies the heat network's weight.
static func cold_norm(temp_c: float) -> float:
	return clampf((18.0 - temp_c) / 24.0, 0.15, 1.25) / 1.25


## Weighted blend of the per-network satisfactions. Water always weighs
## heaviest; heat's weight follows the outdoor temperature. Networks with
## no zones are excluded; returns -1.0 when NOTHING is active (caller
## keeps its previous happiness — an empty map is not a happy map).
func happiness(temp_c: float, active: Dictionary) -> float:
	var weights := {"water": 0.45, "power": 0.25,
		"heat": 0.3 * (0.25 + 0.75 * cold_norm(temp_c))}
	var acc := 0.0
	var total_weight := 0.0
	for key: String in weights:
		if not active.get(key, false):
			continue
		acc += weights[key] * float(values[key])
		total_weight += weights[key]
	if total_weight <= 0.0:
		return -1.0
	return clampf(acc / total_weight, 0.0, 100.0)
