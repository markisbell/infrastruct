class_name CloudField
extends Node3D
## The drifting cloud layer, rebuilt after real cloud morphology (user
## request 2026-08-14: "usually you would have smaller and larger clouds
## as well as connected cloud covers").
##
## Three published facts drive the shape, and each one fixes a specific
## tell of the field this replaces (26 near-identical blobs on a uniform
## random scatter at random altitudes):
##
## 1. SIZES FOLLOW A POWER LAW, not a uniform range. Wood & Field (2011)
##    measured N(L) ∝ L^-1.66 over satellite and aircraft data, with an
##    exponential SCALE BREAK cutting off the largest sizes; satellite
##    retrievals land between 1.6 and 2.2 and shallow-convection LES
##    between 1.7 and 1.9. Hence many small clouds, a few big ones, and a
##    BOUNDED sampler so the heavy tail can never produce one absurd
##    monster (the scale break, in the cheapest honest form).
## 2. CUMULUS BASES ARE FLAT AND ALL AT ONE ALTITUDE — the lifting
##    condensation level is a property of the air mass, not of the
##    individual cloud, so it is the TOPS that grow. Randomising base
##    height (what the old field did) is what made them read as stickers
##    hung at arbitrary heights.
## 3. FIELDS ORGANISE ALONG THE WIND. Horizontal convective rolls sort
##    cumulus into streets parallel to the mean boundary-layer wind
##    (roll wavelength ~2-6x the boundary-layer depth), and as cover
##    rises the field closes into an unbroken closed-cell sheet with
##    cloud fraction ~1. So clouds are positioned in WIND SPACE: streets
##    stay aligned while the wind veers, and cover both swells the clouds
##    and dissolves the street structure into a filled sheet.
##
## Scale is deliberately NOT literal: real roll spacing is kilometres and
## the whole map is 6.4 km, so streets are compressed to read at play
## zoom. The distribution SHAPES are what carry the realism.

## Wood & Field's exponent. Kept as the one dial worth touching if the
## sky ever wants more big clouds (lower alpha = fatter tail).
const SIZE_ALPHA := 1.66
const SIZE_MIN := 1.0
const SIZE_MAX := 6.0

## Sizes are in WORLD units (1 tile = 1 unit = 25 m) and are tuned to the
## camera, not to the atmosphere: a real cumulus is 1-2 km across, which
## at map scale would be 40-80 tiles and would fill the viewport as a
## single white wall (the first tuning pass did exactly that). What has to
## survive the compression is the DISTRIBUTION — small clouds ~5 units,
## big ones ~14, power-law spaced between.
const WORLD_SCALE := 0.7
const CLOUD_COUNT := 96
## The LCL: every cloud bottom sits here. Height is a READABILITY dial as
## much as a physical one — the iso camera has no horizon, so the ground
## fills the frame and any cloud overlaps some of it. Raising the deck
## pushes clouds up-screen into the far band and keeps the middle of the
## frame, where the player is actually building, clear. At 15.5 an
## overcast sky buried the city.
const BASE_Y := 24.0
const STREETS := 8
## The field TILES AROUND THE CAMERA rather than covering the map. Spread
## over all 256 tiles it took ~1800 clouds to look overcast, because the
## viewport is ~32 units wide and sees well under 1 % of the map — the
## same trap the wind arrows hit ("a world-fixed arrow field misses the
## ~30-unit viewport entirely at map scale"). Wrapping happens ~80 units
## out, far off screen at play zoom.
##
## The wrap runs in WIND space, not world x/z: wrapping world coordinates
## would slice the streets into segments whenever the wind is not axis
## aligned. BOX must stay an exact multiple of the street spacing so a
## cloud that wraps across lands back on a street.
const BOX := 160.0
const MAP_CENTER := Vector3(128.0, 0.0, 128.0)

var _clouds: Array[Dictionary] = []   # {node, size, along, street, free}
var _dir := 0.0


## Inverse-CDF sample of a BOUNDED power law p(L) ∝ L^-alpha on [lo, hi],
## for u ∈ [0,1]. Bounded because an unbounded tail eventually draws a
## cloud the size of the map; this is the exponential scale break's cheap
## stand-in, and it keeps the sampler branch-free and deterministic.
static func power_law_size(u: float, lo: float, hi: float,
		alpha: float) -> float:
	var e := 1.0 - alpha
	var lo_e := pow(lo, e)
	# clamped on the way out too: the pow round-trip lands a hair past hi
	# at u=1, and "bounded" should mean bounded, not bounded-ish
	return clampf(pow(lo_e + clampf(u, 0.0, 1.0) * (pow(hi, e) - lo_e),
		1.0 / e), lo, hi)


## How a 0..1 cloud-cover fraction reshapes the field.
## `visible` — share of the pool on screen (the pool is sorted small
##   first, so a clear sky shows fair-weather puffs and only a closing
##   sky brings the deep ones out).
## `swell` — closed-cell overcast is not "more clouds", it is BIGGER ones
##   that touch. Swelling is what actually connects the cover.
## `fill` — street structure dissolving into a filled sheet at the top of
##   the range (open cells -> closed cells).
static func cover_response(cover: float) -> Dictionary:
	var c := clampf(cover, 0.0, 1.0)
	return {
		"visible": lerpf(0.12, 1.0, pow(c, 0.75)),
		"swell": lerpf(0.80, 1.45, c),
		"fill": smoothstep(0.62, 1.0, c),
	}


## One cloud's puffs as pure data — {pos, scale} in cloud-local space,
## y = 0 at the flat base. Static and seeded so the morphology can be
## tested without a viewport (build() is skipped headless).
##
## Shape rules: puff count and horizontal spread grow with size, height
## rank is biased low (pow 1.5) so mass sits near the base, and puffs
## shrink and draw inward as they rise — the cauliflower silhouette of a
## cumulus turret rather than a uniform blob.
static func puff_layout(seed_value: int, size: float) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var count := clampi(roundi(2.0 + 1.35 * size), 3, 10)
	# Vertical development outruns horizontal growth ON PURPOSE: a small
	# cumulus humilis is a flat pancake, a big congestus is roughly as
	# tall as it is wide. Growing both linearly (the first attempt) made
	# large clouds relatively FLATTER — the opposite of how a cloud field
	# deepens, and the unit test caught it.
	var spread := 1.5 * pow(size, 0.8) * WORLD_SCALE
	var rise := (0.4 + 0.55 * pow(size, 1.2)) * WORLD_SCALE
	var puff_r := 1.25 * (0.85 + 0.28 * size) * WORLD_SCALE
	var out: Array[Dictionary] = []
	for i in count:
		# first puff anchors the base center so no cloud is a hollow ring
		var h := 0.0 if i == 0 else pow(rng.randf(), 1.5)
		var taper := lerpf(1.0, 0.45, h)
		var angle := rng.randf() * TAU
		var radius := 0.0 if i == 0 else spread * sqrt(rng.randf()) * taper
		var r := puff_r * taper * rng.randf_range(0.9, 1.1)
		out.append({
			"pos": Vector3(cos(angle) * radius, rise * h,
				sin(angle) * radius * 0.62),
			# flattened like the old puffs: cumulus are wider than tall,
			# and the long axis lies along the street (see build())
			"scale": Vector3(r * 1.55, r * 0.62, r * 1.2),
		})
	return out


func build(field_seed: int) -> void:
	if DisplayServer.get_name() == "headless":
		return  # no renderer, no clouds (smokes never look up)
	var rng := RandomNumberGenerator.new()
	rng.seed = field_seed
	# ONE shared unit sphere for every puff — the old field allocated a
	# SphereMesh per puff and encoded radius in it, which defeats batching
	# and made 100+ single-use resources
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	# smooth alpha puffs render clean but can't cast shadows — an invisible
	# SHADOWS_ONLY twin per puff throws the moving cloud shadow instead
	# (alpha-hash cast shadows but dithered the puffs into speckle)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.99, 0.99, 1.0, 0.82)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 1.0
	var sizes: Array[float] = []
	for i in CLOUD_COUNT:
		sizes.append(power_law_size(rng.randf(), SIZE_MIN, SIZE_MAX, SIZE_ALPHA))
	# small first: cover then reveals fair-weather cumulus before the deep
	# ones, instead of parking a lone giant in an otherwise clear sky
	sizes.sort()
	for i in CLOUD_COUNT:
		var size: float = sizes[i]
		var cloud := Node3D.new()
		for puff: Dictionary in puff_layout(field_seed + i * 7919, size):
			var mesh := MeshInstance3D.new()
			mesh.mesh = sphere
			mesh.position = puff["pos"]
			mesh.scale = puff["scale"]
			mesh.material_override = material
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cloud.add_child(mesh)
			var shadow_twin := MeshInstance3D.new()
			shadow_twin.mesh = sphere
			shadow_twin.position = puff["pos"]
			shadow_twin.scale = puff["scale"]
			shadow_twin.cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			cloud.add_child(shadow_twin)
		add_child(cloud)
		var spacing := BOX / float(STREETS)
		_clouds.append({
			"node": cloud,
			"size": size,
			"along": rng.randf_range(-BOX * 0.5, BOX * 0.5),
			# street seat, plus the jitter that keeps a street from
			# looking like a ruler
			"street": float(rng.randi_range(0, STREETS - 1)) * spacing
				+ rng.randf_range(-0.22, 0.22) * spacing,
			# where this cloud goes once the streets dissolve into a sheet
			"free": rng.randf_range(-BOX * 0.5, BOX * 0.5),
		})


## Per-frame: drift along the wind, re-seat the streets on the eased wind
## direction, and let cover swell/merge the field.
func update(delta: float, wind_dir: float, wind_speed: float, cover: float,
		focus: Vector3) -> void:
	if _clouds.is_empty():
		return
	_dir = wind_dir
	var response := cover_response(cover)
	var visible_n := roundi(float(_clouds.size()) * float(response["visible"]))
	var swell: float = response["swell"]
	var fill: float = response["fill"]
	var forward := Vector3(cos(wind_dir), 0.0, sin(wind_dir))
	var side := Vector3(-sin(wind_dir), 0.0, cos(wind_dir))
	# the camera's own wind-space coordinates: the tile the field wraps
	# around, so clouds always surround the player instead of sitting in
	# whatever corner of the map they were spawned in
	var offset := focus - MAP_CENTER
	var focus_along := offset.dot(forward)
	var focus_across := offset.dot(side)
	for i in _clouds.size():
		var entry: Dictionary = _clouds[i]
		var node: Node3D = entry["node"]
		node.visible = i < visible_n
		if not node.visible:
			continue
		# drift is unbounded here and folded into the box below, so the
		# wind never has to "catch up" after a long fast-forward
		entry["along"] = wrapf(float(entry["along"]) + wind_speed * delta,
			-BOX * 4.0, BOX * 4.0)
		var across: float = lerpf(entry["street"], entry["free"], fill)
		node.position = MAP_CENTER \
			+ forward * _tile(float(entry["along"]), focus_along) \
			+ side * _tile(across, focus_across)
		node.position.y = BASE_Y  # flat bases: one LCL for the whole field
		node.scale = Vector3.ONE * swell
		# the long axis follows the street, so elongated clouds lie WITH
		# the wind rather than across it
		node.rotation.y = -wind_dir


## Fold a wind-space coordinate into the BOX centred on the camera.
static func _tile(value: float, center: float) -> float:
	return center + wrapf(value - center, -BOX * 0.5, BOX * 0.5)


## Put a cloud over a world position (the screenshot wants a shadow on
## town). Solves the wind-space coordinates rather than writing a world
## position that the next update() would overwrite.
func park_over(pos: Vector3) -> void:
	if _clouds.is_empty():
		return
	var entry: Dictionary = _clouds[_clouds.size() / 2]  # a mid-size one
	var offset := pos - MAP_CENTER
	entry["along"] = offset.x * cos(_dir) + offset.z * sin(_dir)
	entry["street"] = -offset.x * sin(_dir) + offset.z * cos(_dir)
	entry["free"] = entry["street"]
