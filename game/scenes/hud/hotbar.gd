class_name Hotbar
extends RefCounted
## The build hotbar: ten user-assigned tool slots on 1-0, pinned to the
## bottom screen edge, whose POSITIONS NEVER MOVE.
##
## That invariant is the entire design. A tabbed palette reuses the same
## screen cell for a different tool per tab, so the location→tool mapping
## the hand wants to learn never stabilises (and a hotkey that auto-switches
## the tab changes the visible set under a cursor that never moved). Slots
## hold TOOL REFERENCES, never stock: an unaffordable tool keeps its slot,
## greyed, and still previews its ghost — Factorio's quickbar rework landed
## on the same rule after items shuffling between slots proved intolerable.
##
## Slots persist as STABLE STRING IDS in user://settings.cfg, deliberately
## NOT in the save envelope: a loadout is a player preference that should
## follow them across saves and scenarios, and the envelope is golden-file
## and contract sensitive. String ids (not Tool enum ints) because tools get
## appended to the enum regularly — a mid-enum insert would silently rebind
## every persisted slot.

const SLOT_COUNT := 10
const CONFIG_PATH := "user://settings.cfg"
const SECTION := "hotbar"

## The default loadout is the DISTRICT LOOP, and it spans every network on
## purpose: the row that is always on screen is also the game's shortest
## statement of what the game is about. Seeding it from the old digit binds
## instead (road/zone/cable/substation/gas/wind/solar/battery/grid) put six
## electricity tools on screen and NO heat or water — those had only ever
## had letter aliases — and the first look at it read as "heat and water
## were removed". Slots 1-4 keep their old meaning; the occasional
## placements (gas/wind/solar/battery/grid connection) moved to the
## catalogue, where a few-times-per-city tool belongs.
const DEFAULT_IDS: Array[String] = ["road", "zone", "cable_overhead",
	"substation", "heat_pipe", "heat_exchanger", "water_pipe",
	"water_station", "repair", "bulldoze"]

## Slot 10 is labelled 0, the key that selects it (Minecraft/Factorio).
const SLOT_LABELS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8",
	"9", "0"]

## Digit row + numpad, matched on PHYSICAL position: the number row is not
## digits on every layout (AZERTY unshifted gives &é"'(-è_çà), and a hotbar
## bound by printed label would be dead there. Mnemonic LETTER hotkeys are
## the opposite case and stay on `keycode` — see Hud.TOOL_KEYS.
const _PHYSICAL_SLOTS := {
	KEY_1: 0, KEY_2: 1, KEY_3: 2, KEY_4: 3, KEY_5: 4, KEY_6: 5, KEY_7: 6,
	KEY_8: 7, KEY_9: 8, KEY_0: 9,
	KEY_KP_1: 0, KEY_KP_2: 1, KEY_KP_3: 2, KEY_KP_4: 3, KEY_KP_5: 4,
	KEY_KP_6: 5, KEY_KP_7: 6, KEY_KP_8: 7, KEY_KP_9: 8, KEY_KP_0: 9,
}


static func default_slots() -> Array[String]:
	return DEFAULT_IDS.duplicate()


## Slot index for a physically-pressed digit, -1 for anything else.
static func slot_for_physical(physical: int) -> int:
	return int(_PHYSICAL_SLOTS.get(physical, -1))


## Force any stored array into exactly SLOT_COUNT known ids. Unknown ids
## become empty slots rather than shifting their neighbours — a renamed or
## removed tool must never move the ones the player DID learn.
static func sanitize(raw: Array, known_ids: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for i in SLOT_COUNT:
		var id := str(raw[i]) if i < raw.size() else ""
		out.append(id if known_ids.has(id) else "")
	return out


static func assign(slots: Array[String], index: int, id: String) -> Array[String]:
	var out := slots.duplicate()
	if index >= 0 and index < out.size():
		out[index] = id
	return out


## Returns the stored loadout, falling back to the defaults when there is
## no settings file yet (first run) or it is unreadable.
static func load_slots(known_ids: Dictionary,
		path: String = CONFIG_PATH) -> Array[String]:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return sanitize(default_slots(), known_ids)
	var raw: Variant = config.get_value(SECTION, "slots", [])
	if not (raw is Array):
		return sanitize(default_slots(), known_ids)
	return sanitize(raw, known_ids)


## Merges into the settings file rather than overwriting it — other UI
## preferences will land in the same file.
static func save_slots(slots: Array[String],
		path: String = CONFIG_PATH) -> Error:
	var config := ConfigFile.new()
	config.load(path)  # missing file is fine, we are creating it
	config.set_value(SECTION, "slots", slots)
	return config.save(path)
