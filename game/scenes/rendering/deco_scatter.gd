class_name DecoScatter
extends RefCounted
## Deterministic environment-prop scatter (Phase-5 refactor plan,
## extracted from city_view.gd — it hid behind a headless early-return
## and was untestable by construction). Props CLUSTER like real terrain
## features (user direction: grouped, not sprinkled): a low-frequency
## noise field carves GROVES and STONE FIELDS, rivers grow a riparian
## strip, sparse lone props between. Deterministic per (tile, terrain
## seed); the renderer assembles MultiMeshes from placements().

## category -> [weighted variant pool, density (fraction of member tiles)]
const DECO_POOLS := {
	"grove":    {"pool": ["tree", "tree", "tree", "tree_high", "tree_high",
		"plant", "patch_grass"], "density": 0.62},
	"rocks":    {"pool": ["stones", "stones", "rocks_low", "rocks_low",
		"rocks_high", "patch_dirt"], "density": 0.25},
	"riparian": {"pool": ["tree", "tree", "plant", "plant", "patch_grass"],
		"density": 0.45},
	"sparse":   {"pool": ["patch_dirt", "patch_grass", "stones", "plant",
		"tree"], "density": 0.012},
}
## cluster field: > this = grove, < negative rock threshold = stone field
## (grove threshold lowered in the graphics pass: bigger forest masses)
const GROVE_LEVEL := 0.22
const ROCKS_LEVEL := -0.42
## the riparian neighborhood: within 2 tiles (incl. diagonals) of water
const RIPARIAN_REACH: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1),
	Vector2i(-1, 1), Vector2i(-1, -1), Vector2i(2, 0), Vector2i(-2, 0),
	Vector2i(0, 2), Vector2i(0, -2)]


static func tile_hash(pos: Vector2i, seed_value: int) -> int:
	# cheap 2D integer hash — deterministic prop placement per (tile, seed)
	var h := pos.x * 73856093 ^ pos.y * 19349663 ^ seed_value * 83492791
	return absi(h)


## The raw scatter: [{pos, variant, h}] per (terrain heights/water/seed).
static func compute(terrain: Terrain, world_tiles: int) -> Array[Dictionary]:
	var scatter: Array[Dictionary] = []
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = terrain.seed_value + 4021
	noise.frequency = 0.045  # grove/stone-field features ~20 tiles
	# pass 1: river tiles as a set — the riparian strip needs cheap
	# neighborhood lookups, not 13 noise evaluations per tile
	var water := {}
	for x in world_tiles:
		for z in world_tiles:
			var pos := Vector2i(x, z)
			if terrain.is_water(pos):
				water[pos] = true
	# pass 2: category per tile, then the category's density gate
	for x in world_tiles:
		for z in world_tiles:
			var pos := Vector2i(x, z)
			if water.has(pos):
				continue
			var c := noise.get_noise_2d(float(x), float(z))
			var category := "sparse"
			if c > GROVE_LEVEL:
				category = "grove"
			elif c < ROCKS_LEVEL:
				category = "rocks"
			else:
				for offset: Vector2i in RIPARIAN_REACH:
					if water.has(pos + offset):
						category = "riparian"
						break
			var h := tile_hash(pos, terrain.seed_value)
			var spec: Dictionary = DECO_POOLS[category]
			if h % 1000 >= int(float(spec["density"]) * 1000.0):
				continue
			var pool: Array = spec["pool"]
			scatter.append({"pos": pos,
				"variant": pool[(h / 1000) % pool.size()], "h": h})
	return scatter


## Occupancy-filtered world transforms per variant: a prop lives only on
## truly empty, unzoned land the bulldozer hasn't cleared. ground_y is
## the SMOOTHED tile-center height so props follow the slopes.
static func placements(scatter: Array[Dictionary],
		model: WorldModel, ground_y: Callable) -> Dictionary:
	var buckets := {}
	for entry: Dictionary in scatter:
		var pos: Vector2i = entry["pos"]
		if not model.is_tile_free(pos) or model.zoning.has(pos) \
				or model.deco_cleared.has(pos):
			continue
		var variant: String = entry["variant"]
		if not buckets.has(variant):
			buckets[variant] = []
		var h: int = entry["h"]
		var jitter := Vector3((h % 41) / 41.0 - 0.5, 0.0,
			(h % 37) / 37.0 - 0.5) * 0.55
		var spot := Vector3(pos.x + 0.5, float(ground_y.call(pos)),
			pos.y + 0.5) + jitter
		buckets[variant].append(Transform3D(
			Basis(Vector3.UP, TAU * float(h % 97) / 97.0), spot))
	return buckets
