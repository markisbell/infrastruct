class_name BuildingModels
extends RefCounted
## Procedural building/utility models (Phase-5 refactor plan, extracted
## from city_view.gd): every plant is a by-eye rebuild after a Sketchfab
## reference (MODEL PASS 2026-07-31 — nothing downloaded, licenses never
## attach). Pure static factories over flat()/box(); no scene or autoload
## reads, so the gallery, thumbnails and renderer share one library.

## Network color language (user direction): heat = red/blue double pipe
## (forward/return — physically honest), water = green.
const PIPE_SUPPLY_COLOR := Color(0.85, 0.22, 0.15)
const PIPE_RETURN_COLOR := Color(0.2, 0.38, 0.85)
const WATER_PIPE_COLOR := Color(0.2, 0.7, 0.35)
const PIPE_HEIGHT := 0.16  # heat/water pipe centerline height

static var _material_cache := {}


static func flat(color: Color, transparent: bool = false,
		unshaded: bool = false) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color.to_html(), transparent, unshaded]
	if not _material_cache.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		if transparent:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if unshaded:
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material_cache[key] = material
	return _material_cache[key]


## Emissive accent material (the EV dispenser's teal glow strips —
## SHADED, so it never blooms at night like the unshaded overlays did).
static func glow(color: Color) -> StandardMaterial3D:
	var key := "glow|" + color.to_html()
	if not _material_cache.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.6
		_material_cache[key] = material
	return _material_cache[key]


static func box(size: Vector3, color: Color, offset: Vector3) -> MeshInstance3D:
	var mesh_box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_box.mesh = mesh
	mesh_box.position = offset
	mesh_box.material_override = flat(color)
	return mesh_box


## The procedural library dispatch; null = no procedural model (the
## renderer falls back to a kit GLB).
static func make(kind: String) -> Node3D:
	match kind:
		"gas_plant": return _make_gas_plant()
		"substation": return _make_substation()
		"substation_xl": return _make_substation_xl()
		"wind_farm": return _make_wind_farm()
		"solar_park": return _make_solar_park()
		"battery": return _make_battery()
		"grid_connection": return _make_grid_connection()
		"boiler_plant": return _make_boiler_plant()
		"chp_plant": return _make_chp_plant()
		"heat_pump_plant": return _make_heat_pump_plant()
		"heat_storage": return _make_heat_storage()
		"heat_exchanger": return _make_transfer_station()
		"water_station": return _make_water_station()
		"well": return _make_well()
		"pumping_station": return _make_pumping_station()
		"water_tower": return _make_water_tower()
		"charging_park": return _make_charging_park()
	return null


## The wooden distribution pole + crossarm (also the palette thumbnail).
static func pole_visual() -> Node3D:
	var node := Node3D.new()
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.035
	pole_mesh.bottom_radius = 0.05
	pole_mesh.height = 0.85
	pole.mesh = pole_mesh
	pole.position.y = 0.42
	pole.material_override = flat(Color(0.45, 0.36, 0.28))
	node.add_child(pole)
	var arm := MeshInstance3D.new()
	arm.mesh = BoxMesh.new()
	(arm.mesh as BoxMesh).size = Vector3(0.3, 0.04, 0.06)
	arm.position.y = 0.78
	arm.material_override = pole.material_override
	node.add_child(arm)
	return node

static func wire_segment(from: Vector3, to: Vector3, thickness: float,
		color: Color) -> MeshInstance3D:
	var wire := MeshInstance3D.new()
	wire.set_meta("wire", true)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thickness, thickness, from.distance_to(to))
	wire.mesh = mesh
	wire.transform = Transform3D(
		Basis.looking_at((to - from).normalized(), Vector3.UP),
		(from + to) / 2.0)
	wire.material_override = flat(color)
	return wire

## Line tile visuals by kind. Overhead: pole, crossarm, wire half-spans,
## and a sloped SERVICE DROP to any adjacent electrical building (the
## visible connection). Underground: a trench strip with a marker post
## (Kabelmerkstein) and a grey riser box where it enters a building.
## Kabelendmast dressing: strain bracket, three cable terminations
## (Endverschluesse), a surge-arrester pair and the steel riser conduit
## the cable descends in — oriented toward the buried neighbor.
static func termination_hardware(toward: Vector3) -> Node3D:
	var rig := Node3D.new()
	var grey := Color(0.62, 0.64, 0.66)
	var porcelain := Color(0.45, 0.35, 0.3)
	rig.add_child(box(Vector3(0.16, 0.035, 0.16), grey, Vector3(0, 0.58, 0)))
	for k in 3:
		var cone := MeshInstance3D.new()
		var cone_mesh := CylinderMesh.new()
		cone_mesh.top_radius = 0.012
		cone_mesh.bottom_radius = 0.028
		cone_mesh.height = 0.11
		cone_mesh.radial_segments = 8
		cone.mesh = cone_mesh
		cone.position = Vector3(-0.05 + k * 0.05, 0.65, 0.05)
		cone.material_override = flat(porcelain)
		rig.add_child(cone)
	# arrester pair on the opposite bracket edge
	for k in 2:
		rig.add_child(box(Vector3(0.025, 0.09, 0.025), Color(0.55, 0.57, 0.6),
			Vector3(-0.03 + k * 0.06, 0.64, -0.055)))
	# steel riser conduit down the pole toward the buried side
	var conduit := MeshInstance3D.new()
	var conduit_mesh := CylinderMesh.new()
	conduit_mesh.top_radius = 0.022
	conduit_mesh.bottom_radius = 0.022
	conduit_mesh.height = 0.6
	conduit_mesh.radial_segments = 8
	conduit.mesh = conduit_mesh
	conduit.position = toward * 0.09 + Vector3(0, 0.3, 0)
	conduit.material_override = flat(grey)
	rig.add_child(conduit)
	# jumper from the crossarm down into the terminations
	rig.add_child(wire_segment(Vector3(0, 0.74, 0), Vector3(0, 0.6, 0.05),
		0.02, Color(0.16, 0.16, 0.18)))
	rig.add_child(wire_segment(Vector3(0, 0.6, 0.05),
		toward * 0.09 + Vector3(0, 0.58, 0), 0.02, Color(0.16, 0.16, 0.18)))
	return rig

## Heat transfer station (user pick from the model gallery): grey hut with
## an orange roof band, vent, and red/blue stubs that plug into the double
## pipe — rotate with R so the stubs face your line.
static func _make_transfer_station() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(0.55, 0.5, 0.45), Color(0.72, 0.74, 0.78),
		Vector3(0, 0.25, 0)))
	node.add_child(box(Vector3(0.57, 0.08, 0.47), Color(0.85, 0.45, 0.2),
		Vector3(0, 0.54, 0)))
	# the actual plate heat exchanger (Sketchfab reference: blue bolted
	# plate pack) visible beside the hut
	node.add_child(box(Vector3(0.15, 0.22, 0.13), Color(0.18, 0.32, 0.6),
		Vector3(0.36, 0.11, 0.1)))
	for i in 3:
		node.add_child(box(Vector3(0.16, 0.015, 0.14), Color(0.75, 0.77, 0.8),
			Vector3(0.36, 0.05 + i * 0.07, 0.1)))
	node.add_child(box(Vector3(0.12, 0.2, 0.12), Color(0.5, 0.52, 0.56),
		Vector3(0.15, 0.68, 0.1)))
	for pair: Array in [[PIPE_SUPPLY_COLOR, 0.13], [PIPE_RETURN_COLOR, -0.13]]:
		var stub := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.055
		cyl.bottom_radius = 0.055
		cyl.height = 0.5
		stub.mesh = cyl
		stub.rotation_degrees.x = 90
		stub.position = Vector3(pair[1], PIPE_HEIGHT, 0.4)
		stub.material_override = flat(pair[0])
		node.add_child(stub)
	return node

## District water station: sibling of the transfer station — grey hut with a
## teal band and one green stub that plugs into the water main.
## Small brick waterworks house after the chlorination-station reference:
## sand-brick walls, steep dark pitched roof, brick chimney, blue door.
static func _make_water_station() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(0.55, 0.42, 0.45), Color(0.78, 0.68, 0.52),
		Vector3(0, 0.21, 0)))
	var roof := MeshInstance3D.new()
	var roof_mesh := PrismMesh.new()
	roof_mesh.size = Vector3(0.62, 0.24, 0.52)
	roof.mesh = roof_mesh
	roof.position = Vector3(0, 0.54, 0)
	roof.material_override = flat(Color(0.32, 0.33, 0.36))
	node.add_child(roof)
	node.add_child(box(Vector3(0.08, 0.3, 0.08), Color(0.65, 0.5, 0.38),
		Vector3(0.18, 0.62, -0.1)))
	node.add_child(box(Vector3(0.14, 0.24, 0.015), Color(0.2, 0.45, 0.7),
		Vector3(-0.1, 0.13, 0.226)))
	var stub := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.07
	cyl.bottom_radius = 0.07
	cyl.height = 0.5
	stub.mesh = cyl
	stub.rotation_degrees.x = 90
	stub.position = Vector3(0, PIPE_HEIGHT, 0.4)
	stub.material_override = flat(WATER_PIPE_COLOR)
	node.add_child(stub)
	return node

## Classic stone well after the Sketchfab reference: round stone ring, two
## wooden posts carrying a pitched shingle roof, windlass bar and bucket.
## Rustic on purpose — reads as "water from the ground" instantly, and the
## river-bonus wells sit in exactly this kind of spot.
static func _make_well() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(0.85, 0.05, 0.85), Color(0.62, 0.6, 0.55),
		Vector3(0, 0.025, 0)))
	var ring := MeshInstance3D.new()
	var ring_mesh := CylinderMesh.new()
	ring_mesh.top_radius = 0.2
	ring_mesh.bottom_radius = 0.22
	ring_mesh.height = 0.22
	ring_mesh.radial_segments = 12
	ring.mesh = ring_mesh
	ring.position.y = 0.14
	ring.material_override = flat(Color(0.6, 0.62, 0.6))
	node.add_child(ring)
	var hole := MeshInstance3D.new()
	var hole_mesh := CylinderMesh.new()
	hole_mesh.top_radius = 0.13
	hole_mesh.bottom_radius = 0.13
	hole_mesh.height = 0.02
	hole.mesh = hole_mesh
	hole.position.y = 0.255
	hole.material_override = flat(Color(0.1, 0.12, 0.14))
	node.add_child(hole)
	var wood := Color(0.45, 0.32, 0.2)
	node.add_child(box(Vector3(0.05, 0.5, 0.05), wood, Vector3(-0.22, 0.4, 0)))
	node.add_child(box(Vector3(0.05, 0.5, 0.05), wood, Vector3(0.22, 0.4, 0)))
	node.add_child(box(Vector3(0.5, 0.04, 0.04), Color(0.35, 0.25, 0.16),
		Vector3(0, 0.52, 0)))  # windlass bar
	var roof := MeshInstance3D.new()
	var roof_mesh := PrismMesh.new()
	roof_mesh.size = Vector3(0.6, 0.2, 0.5)
	roof.mesh = roof_mesh
	roof.position = Vector3(0, 0.75, 0)
	roof.material_override = flat(Color(0.5, 0.3, 0.22))
	node.add_child(roof)
	node.add_child(box(Vector3(0.09, 0.09, 0.09), Color(0.7, 0.55, 0.35),
		Vector3(0.05, 0.34, 0)))  # bucket
	node.add_child(box(Vector3(0.3, 0.28, 0.24), Color(0.72, 0.74, 0.78),
		Vector3(0.28, 0.14, -0.26)))  # pump cabinet (the actual utility)
	return node

## Pump house: compact utility hall with a roll door, an EXTERNAL pump set
## (volute + motor) on a plinth, and big suction/discharge piping — the
## building that ties water to power; place it next to a cable AND the main.
static func _make_pumping_station() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(1.9, 0.05, 1.9), Color(0.62, 0.62, 0.6), Vector3(0, 0.02, 0)))
	node.add_child(box(Vector3(0.95, 0.5, 0.8), Color(0.8, 0.81, 0.83), Vector3(-0.3, 0.3, 0)))
	node.add_child(box(Vector3(0.99, 0.06, 0.84), Color(0.45, 0.47, 0.5), Vector3(-0.3, 0.58, 0)))
	node.add_child(box(Vector3(0.4, 0.34, 0.02), Color(0.4, 0.42, 0.46), Vector3(-0.3, 0.22, 0.401)))
	# external pump set: volute snail + motor on a plinth
	node.add_child(box(Vector3(0.5, 0.08, 0.4), Color(0.5, 0.5, 0.52), Vector3(0.55, 0.09, 0.3)))
	var volute := MeshInstance3D.new()
	var vol_mesh := CylinderMesh.new()
	vol_mesh.top_radius = 0.13
	vol_mesh.bottom_radius = 0.13
	vol_mesh.height = 0.12
	volute.mesh = vol_mesh
	volute.rotation.x = PI / 2
	volute.position = Vector3(0.42, 0.24, 0.3)
	volute.material_override = flat(Color(0.2, 0.42, 0.62))
	node.add_child(volute)
	var motor := MeshInstance3D.new()
	var motor_mesh := CylinderMesh.new()
	motor_mesh.top_radius = 0.09
	motor_mesh.bottom_radius = 0.09
	motor_mesh.height = 0.26
	motor.mesh = motor_mesh
	motor.rotation.z = PI / 2
	motor.position = Vector3(0.62, 0.24, 0.3)
	motor.material_override = flat(Color(0.65, 0.67, 0.7))
	node.add_child(motor)
	# suction from the hall into the volute + discharge stub to the main
	var suction := MeshInstance3D.new()
	var suc_mesh := CylinderMesh.new()
	suc_mesh.top_radius = 0.06
	suc_mesh.bottom_radius = 0.06
	suc_mesh.height = 0.5
	suction.mesh = suc_mesh
	suction.rotation.z = PI / 2
	suction.position = Vector3(0.1, 0.24, 0.3)
	suction.material_override = flat(WATER_PIPE_COLOR)
	node.add_child(suction)
	var stub := MeshInstance3D.new()
	var stub_mesh := CylinderMesh.new()
	stub_mesh.top_radius = 0.07
	stub_mesh.bottom_radius = 0.07
	stub_mesh.height = 0.7
	stub.mesh = stub_mesh
	stub.rotation_degrees.x = 90
	stub.position = Vector3(0.42, PIPE_HEIGHT, 0.62)
	stub.material_override = flat(WATER_PIPE_COLOR)
	node.add_child(stub)
	return node

## Classic elevated tank: four legs, cylindrical tank with a conical cap —
## the pressure boundary of the network, unmistakable on the skyline.
static func _make_water_tower() -> Node3D:
	var node := Node3D.new()
	for legs: Vector2 in [Vector2(-0.2, -0.2), Vector2(0.2, -0.2),
			Vector2(-0.2, 0.2), Vector2(0.2, 0.2)]:
		node.add_child(box(Vector3(0.06, 1.1, 0.06), Color(0.55, 0.57, 0.6),
			Vector3(legs.x, 0.55, legs.y)))
	# X-bracing between the legs (Sketchfab lattice-tower reference): two
	# crossed diagonals per face, at two heights
	for brace_y: float in [0.35, 0.8]:
		for side: Array in [[Vector3(0, brace_y, 0.2), 0.0], [Vector3(0, brace_y, -0.2), 0.0],
				[Vector3(0.2, brace_y, 0), PI / 2], [Vector3(-0.2, brace_y, 0), PI / 2]]:
			for tilt: float in [0.55, -0.55]:
				var brace := box(Vector3(0.5, 0.025, 0.025), Color(0.5, 0.52, 0.55), Vector3.ZERO)
				brace.position = side[0]
				brace.rotation = Vector3(0, side[1], tilt)
				node.add_child(brace)
	var tank := MeshInstance3D.new()
	var tank_mesh := CylinderMesh.new()
	tank_mesh.top_radius = 0.34
	tank_mesh.bottom_radius = 0.3
	tank_mesh.height = 0.55
	tank.mesh = tank_mesh
	tank.position.y = 1.35
	tank.material_override = flat(Color(0.55, 0.65, 0.75))
	node.add_child(tank)
	var cap := MeshInstance3D.new()
	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = 0.02
	cap_mesh.bottom_radius = 0.36
	cap_mesh.height = 0.22
	cap.mesh = cap_mesh
	cap.position.y = 1.73
	cap.material_override = flat(Color(0.45, 0.55, 0.65))
	node.add_child(cap)
	# riser pipe down the middle, in network green
	var riser := MeshInstance3D.new()
	var riser_mesh := CylinderMesh.new()
	riser_mesh.top_radius = 0.05
	riser_mesh.bottom_radius = 0.05
	riser_mesh.height = 1.1
	riser.mesh = riser_mesh
	riser.position.y = 0.55
	riser.material_override = flat(WATER_PIPE_COLOR)
	node.add_child(riser)
	return node

## HV power transformer in the real-substation look (user reference): grey
## main tank, ribbed radiator banks beside it, a cylindrical conservator
## drum on a bracket above one end, and a row of dark ribbed bushing
## insulators on top. Line-attachment posts kept from the old model.
static func _make_substation() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(0.9, 0.06, 0.9), Color(0.6, 0.6, 0.62), Vector3(0, 0.03, 0)))
	var tank_grey := Color(0.62, 0.63, 0.65)
	var fin_grey := Color(0.7, 0.71, 0.73)
	# main tank + lid rim + warning sign
	node.add_child(box(Vector3(0.44, 0.34, 0.28), tank_grey, Vector3(0, 0.23, 0)))
	node.add_child(box(Vector3(0.48, 0.03, 0.32), fin_grey, Vector3(0, 0.41, 0)))
	node.add_child(box(Vector3(0.005, 0.06, 0.05), Color(0.95, 0.8, 0.15),
		Vector3(-0.223, 0.26, 0.05)))
	# radiator bank: parallel ribbed plates along the +x side
	for i in 7:
		node.add_child(box(Vector3(0.012, 0.28, 0.2), fin_grey,
			Vector3(0.25 + i * 0.026, 0.22, 0)))
	# conservator drum on a bracket above the -x end
	var drum := MeshInstance3D.new()
	var drum_mesh := CylinderMesh.new()
	drum_mesh.top_radius = 0.055
	drum_mesh.bottom_radius = 0.055
	drum_mesh.height = 0.2
	drum.mesh = drum_mesh
	drum.rotation.z = PI / 2  # lie along x
	drum.position = Vector3(-0.27, 0.52, 0)
	drum.material_override = flat(tank_grey)
	node.add_child(drum)
	node.add_child(box(Vector3(0.03, 0.12, 0.03), fin_grey, Vector3(-0.27, 0.42, 0)))
	# three dark ribbed bushings on top (core + fin discs + cap)
	var porcelain := flat(Color(0.26, 0.2, 0.17))
	for b in 3:
		var bx := 0.02 + b * 0.03  # slight diagonal like the reference
		var bz := -0.09 + b * 0.09
		var core := MeshInstance3D.new()
		var core_mesh := CylinderMesh.new()
		core_mesh.top_radius = 0.014
		core_mesh.bottom_radius = 0.018
		core_mesh.height = 0.24
		core_mesh.radial_segments = 8
		core.mesh = core_mesh
		core.position = Vector3(bx, 0.53, bz)
		core.material_override = porcelain
		node.add_child(core)
		for d in 4:
			var disc := MeshInstance3D.new()
			var disc_mesh := CylinderMesh.new()
			disc_mesh.top_radius = 0.034
			disc_mesh.bottom_radius = 0.034
			disc_mesh.height = 0.012
			disc_mesh.radial_segments = 10
			disc.mesh = disc_mesh
			disc.position = Vector3(bx, 0.46 + d * 0.05, bz)
			disc.material_override = porcelain
			node.add_child(disc)
		node.add_child(box(Vector3(0.03, 0.025, 0.03), Color(0.8, 0.81, 0.83),
			Vector3(bx, 0.66, bz)))
	# line-attachment posts (power cables visually terminate here)
	for offset: float in [-0.3, 0.3]:
		node.add_child(box(Vector3(0.04, 0.55, 0.04), Color(0.75, 0.75, 0.78),
			Vector3(offset, 0.33, -0.3)))
	return node

## ONE modern HAWT per placement (user direction: build farms turbine by
## turbine) in the classic white-with-red-tip-bands look (user reference: a
## slim tapered tube tower, compact nacelle, round spinner nose, slender
## tapered blades) on a ROUND concrete foundation pad. Turbines YAW into the
## wind and the spin follows wind availability (rotor update in _process).
static func _make_wind_farm() -> Node3D:
	var node := Node3D.new()
	var pad := MeshInstance3D.new()
	var pad_mesh := CylinderMesh.new()
	pad_mesh.top_radius = 0.42
	pad_mesh.bottom_radius = 0.46
	pad_mesh.height = 0.05
	pad_mesh.radial_segments = 24
	pad.mesh = pad_mesh
	pad.position.y = 0.025
	pad.material_override = flat(Color(0.66, 0.66, 0.63))
	node.add_child(pad)
	var white := flat(Color(0.95, 0.96, 0.97))
	var grey := flat(Color(0.86, 0.87, 0.89))
	var red := flat(Color(0.83, 0.22, 0.22))
	for spot: Vector3 in [Vector3.ZERO]:
		var turbine := Node3D.new()
		turbine.position = spot
		turbine.set_meta("turbine", true)  # yawed into the wind per frame
		var mast := MeshInstance3D.new()
		var mast_mesh := CylinderMesh.new()
		mast_mesh.top_radius = 0.025
		mast_mesh.bottom_radius = 0.055
		mast_mesh.height = 1.7
		mast.mesh = mast_mesh
		mast.position.y = 0.85
		mast.material_override = white
		turbine.add_child(mast)
		var nacelle := MeshInstance3D.new()
		var nacelle_mesh := BoxMesh.new()
		nacelle_mesh.size = Vector3(0.075, 0.08, 0.2)
		nacelle.mesh = nacelle_mesh
		nacelle.position = Vector3(0, 1.7, -0.02)
		nacelle.material_override = grey
		turbine.add_child(nacelle)
		var rotor := Node3D.new()
		rotor.position = Vector3(0, 1.7, 0.1)
		rotor.set_meta("rotor", true)
		var spinner := MeshInstance3D.new()
		var spinner_mesh := SphereMesh.new()
		spinner_mesh.radius = 0.04
		spinner_mesh.height = 0.08
		spinner.mesh = spinner_mesh
		spinner.scale = Vector3(1, 1, 1.4)  # rounded nose cone
		spinner.material_override = white
		rotor.add_child(spinner)
		for blade_i in 3:
			var arm := Node3D.new()
			arm.rotation_degrees.z = blade_i * 120.0
			var blade := MeshInstance3D.new()
			var blade_mesh := CylinderMesh.new()  # tapered: wide root, slim tip
			blade_mesh.top_radius = 0.01
			blade_mesh.bottom_radius = 0.034
			blade_mesh.height = 0.62
			blade_mesh.radial_segments = 8
			blade.mesh = blade_mesh
			blade.scale = Vector3(1, 1, 0.3)  # flatten into an airfoil-ish slab
			blade.position.y = 0.34
			blade.material_override = white
			arm.add_child(blade)
			var band := MeshInstance3D.new()  # red tip marking
			var band_mesh := CylinderMesh.new()
			band_mesh.top_radius = 0.014
			band_mesh.bottom_radius = 0.018
			band_mesh.height = 0.07
			band_mesh.radial_segments = 8
			band.mesh = band_mesh
			band.scale = Vector3(1, 1, 0.3)
			band.position.y = 0.56
			band.material_override = red
			arm.add_child(band)
			rotor.add_child(arm)
		turbine.add_child(rotor)
		node.add_child(turbine)
	return node

## Pole-mounted framed arrays after the user's reference: silver frame, 3x2
## blue modules with visible gridlines, one pole per array on a concrete
## footing block.
static func _make_solar_park() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(1.9, 0.05, 1.9), Color(0.55, 0.55, 0.5), Vector3(0, 0.02, 0)))
	var silver := Color(0.78, 0.8, 0.83)
	var cell_blue := Color(0.2, 0.3, 0.62)
	var concrete := Color(0.68, 0.67, 0.64)
	for row in 4:
		for col in 3:
			var mount := Node3D.new()
			mount.position = Vector3(-0.6 + col * 0.6, 0.05, -0.65 + row * 0.42)
			mount.add_child(box(Vector3(0.07, 0.06, 0.07), concrete, Vector3(0, 0.03, 0)))
			var pole := MeshInstance3D.new()
			var pole_mesh := CylinderMesh.new()
			pole_mesh.top_radius = 0.014
			pole_mesh.bottom_radius = 0.014
			pole_mesh.height = 0.2
			pole_mesh.radial_segments = 8
			pole.mesh = pole_mesh
			pole.position.y = 0.14
			pole.material_override = flat(silver)
			mount.add_child(pole)
			var assembly := Node3D.new()
			assembly.position.y = 0.26
			# +30: panels face +Z = SOUTH at rot 0 (facing is gameplay now)
			assembly.rotation_degrees.x = 30
			# silver frame slab, blue modules on top with gridline gaps
			assembly.add_child(box(Vector3(0.52, 0.014, 0.36), silver, Vector3.ZERO))
			for mx in 3:
				for mz in 2:
					assembly.add_child(box(Vector3(0.155, 0.008, 0.155), cell_blue,
						Vector3(-0.17 + mx * 0.17, 0.01, -0.088 + mz * 0.176)))
			mount.add_child(assembly)
			node.add_child(mount)
	return node

## BESS shipping container after the Sketchfab reference: blue corrugated
## box, door seams, a small HVAC unit on the side and a hazard mark.
static func _make_battery() -> Node3D:
	var node := Node3D.new()
	var blue := Color(0.16, 0.32, 0.58)
	var dark_blue := Color(0.12, 0.25, 0.47)
	node.add_child(box(Vector3(0.86, 0.48, 0.5), blue, Vector3(0, 0.26, 0)))
	for i in 7:  # corrugation grooves
		node.add_child(box(Vector3(0.015, 0.44, 0.505), dark_blue,
			Vector3(-0.36 + i * 0.12, 0.26, 0)))
	node.add_child(box(Vector3(0.87, 0.03, 0.51), Color(0.1, 0.12, 0.16), Vector3(0, 0.515, 0)))
	# door seams (white) on one end + HVAC box + hazard mark
	node.add_child(box(Vector3(0.008, 0.4, 0.44), Color(0.88, 0.9, 0.92), Vector3(0.432, 0.26, 0)))
	node.add_child(box(Vector3(0.12, 0.26, 0.3), Color(0.82, 0.84, 0.86), Vector3(-0.48, 0.2, 0)))
	node.add_child(box(Vector3(0.09, 0.09, 0.008), Color(0.95, 0.8, 0.15), Vector3(0.2, 0.3, -0.255)))
	return node

## Compact gas peaker after the power-station reference: light machine hall
## with arched vault roof, one banded exhaust stack, orange gas-intake skid.
static func _make_gas_plant() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(1.9, 0.05, 1.9), Color(0.6, 0.6, 0.58), Vector3(0, 0.02, 0)))
	node.add_child(box(Vector3(1.15, 0.52, 0.95), Color(0.82, 0.83, 0.85), Vector3(-0.2, 0.31, 0)))
	for i in 3:  # vault roof: half-sunk cylinders along the hall
		var vault := MeshInstance3D.new()
		var vault_mesh := CylinderMesh.new()
		vault_mesh.top_radius = 0.16
		vault_mesh.bottom_radius = 0.16
		vault_mesh.height = 1.12
		vault.mesh = vault_mesh
		vault.rotation.z = PI / 2
		vault.position = Vector3(-0.2, 0.57, -0.3 + i * 0.3)
		vault.material_override = flat(Color(0.74, 0.75, 0.78))
		node.add_child(vault)
	for s in 4:  # banded stack
		var seg := MeshInstance3D.new()
		var seg_mesh := CylinderMesh.new()
		seg_mesh.top_radius = 0.075 - s * 0.006
		seg_mesh.bottom_radius = 0.08 - s * 0.006
		seg_mesh.height = 0.36
		seg.mesh = seg_mesh
		seg.position = Vector3(0.62, 0.18 + s * 0.36, 0.55)
		seg.material_override = flat(Color(0.9, 0.91, 0.93) if s % 2 == 0
			else Color(0.32, 0.33, 0.36))
		node.add_child(seg)
	node.add_child(box(Vector3(0.38, 0.26, 0.3), Color(0.85, 0.6, 0.2), Vector3(0.55, 0.14, -0.5)))
	return node

## Boiler house after the thermal-plant reference: brick-red hall with a
## ridged roof line and the iconic red/white banded stack, plus a fuel bay.
static func _make_boiler_plant() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(1.9, 0.05, 1.9), Color(0.6, 0.59, 0.56), Vector3(0, 0.02, 0)))
	node.add_child(box(Vector3(1.05, 0.58, 0.9), Color(0.62, 0.3, 0.24), Vector3(-0.22, 0.34, 0)))
	node.add_child(box(Vector3(1.09, 0.07, 0.94), Color(0.45, 0.22, 0.18), Vector3(-0.22, 0.66, 0)))
	node.add_child(box(Vector3(0.3, 0.34, 0.02), Color(0.3, 0.31, 0.34), Vector3(-0.22, 0.22, 0.451)))
	for s in 5:  # red/white banded stack
		var seg := MeshInstance3D.new()
		var seg_mesh := CylinderMesh.new()
		seg_mesh.top_radius = 0.07 - s * 0.004
		seg_mesh.bottom_radius = 0.075 - s * 0.004
		seg_mesh.height = 0.34
		seg.mesh = seg_mesh
		seg.position = Vector3(0.6, 0.17 + s * 0.34, 0.5)
		seg.material_override = flat(Color(0.92, 0.93, 0.94) if s % 2 == 0
			else Color(0.78, 0.22, 0.2))
		node.add_child(seg)
	node.add_child(box(Vector3(0.45, 0.3, 0.4), Color(0.5, 0.51, 0.54), Vector3(0.55, 0.16, -0.45)))
	return node

## CHP as a biogas-style site after the reference: green digester cylinder
## with a domed cap, an engine shed with exhaust, and a gas flare pipe.
static func _make_chp_plant() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(1.9, 0.05, 1.9), Color(0.58, 0.6, 0.56), Vector3(0, 0.02, 0)))
	var digester := MeshInstance3D.new()
	var dig_mesh := CylinderMesh.new()
	dig_mesh.top_radius = 0.42
	dig_mesh.bottom_radius = 0.42
	dig_mesh.height = 0.45
	digester.mesh = dig_mesh
	digester.position = Vector3(-0.35, 0.27, 0.05)
	digester.material_override = flat(Color(0.32, 0.45, 0.3))
	node.add_child(digester)
	var dome := MeshInstance3D.new()
	var dome_mesh := SphereMesh.new()
	dome_mesh.radius = 0.42
	dome_mesh.height = 0.5   # squashed hemisphere
	dome.mesh = dome_mesh
	dome.position = Vector3(-0.35, 0.5, 0.05)
	dome.material_override = flat(Color(0.78, 0.79, 0.75))
	node.add_child(dome)
	# engine shed + exhaust + flare pipe
	node.add_child(box(Vector3(0.6, 0.4, 0.5), Color(0.72, 0.74, 0.76), Vector3(0.55, 0.25, -0.35)))
	node.add_child(box(Vector3(0.05, 0.55, 0.05), Color(0.35, 0.36, 0.4), Vector3(0.75, 0.65, -0.45)))
	var flare := MeshInstance3D.new()
	var flare_mesh := CylinderMesh.new()
	flare_mesh.top_radius = 0.035
	flare_mesh.bottom_radius = 0.02
	flare_mesh.height = 0.5
	flare.mesh = flare_mesh
	flare.position = Vector3(0.6, 0.3, 0.55)
	flare.material_override = flat(Color(0.8, 0.55, 0.2))
	node.add_child(flare)
	return node

## District-heat storage: the tall white insulated Waermespeicher cylinder
## with silver trim bands and a domed cap.
static func _make_heat_storage() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(0.85, 0.05, 0.85), Color(0.62, 0.62, 0.6), Vector3(0, 0.025, 0)))
	var tank := MeshInstance3D.new()
	var tank_mesh := CylinderMesh.new()
	tank_mesh.top_radius = 0.3
	tank_mesh.bottom_radius = 0.3
	tank_mesh.height = 1.0
	tank.mesh = tank_mesh
	tank.position.y = 0.55
	tank.material_override = flat(Color(0.92, 0.93, 0.94))
	node.add_child(tank)
	for band_y: float in [0.3, 0.65, 1.0]:
		var band := MeshInstance3D.new()
		var band_mesh := CylinderMesh.new()
		band_mesh.top_radius = 0.31
		band_mesh.bottom_radius = 0.31
		band_mesh.height = 0.03
		band.mesh = band_mesh
		band.position.y = band_y
		band.material_override = flat(Color(0.72, 0.74, 0.77))
		node.add_child(band)
	var cap := MeshInstance3D.new()
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = 0.3
	cap_mesh.height = 0.3
	cap.mesh = cap_mesh
	cap.position.y = 1.05
	cap.material_override = flat(Color(0.85, 0.86, 0.88))
	node.add_child(cap)
	return node

## Bank of outdoor inverter units after the user's reference: white body,
## dark front fan grille with horizontal louvres and a visible fan disc,
## side vent slats, little feet.
static func _make_heat_pump_plant() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(1.9, 0.05, 1.9), Color(0.62, 0.62, 0.6), Vector3(0, 0.02, 0)))
	var body_white := Color(0.93, 0.93, 0.9)
	var grille_dark := Color(0.25, 0.26, 0.28)
	var louvre := Color(0.55, 0.56, 0.58)
	for i in 4:
		var unit := Node3D.new()
		var face := 1.0 if i % 2 == 0 else -1.0  # rows face outward
		unit.position = Vector3(-0.45 + (i / 2) * 0.95, 0.05, -0.4 * face)
		unit.rotation.y = 0.0 if face > 0.0 else PI
		unit.add_child(box(Vector3(0.78, 0.62, 0.34), body_white, Vector3(0, 0.35, 0)))
		# front fan grille: dark square, fan disc, louvre strips, hub
		unit.add_child(box(Vector3(0.5, 0.5, 0.012), grille_dark, Vector3(-0.09, 0.36, -0.175)))
		var fan := MeshInstance3D.new()
		var fan_mesh := CylinderMesh.new()
		fan_mesh.top_radius = 0.2
		fan_mesh.bottom_radius = 0.2
		fan_mesh.height = 0.012
		fan.mesh = fan_mesh
		fan.rotation.x = PI / 2
		fan.position = Vector3(-0.09, 0.36, -0.181)
		fan.material_override = flat(Color(0.36, 0.37, 0.4))
		unit.add_child(fan)
		unit.add_child(box(Vector3(0.05, 0.05, 0.014), louvre, Vector3(-0.09, 0.36, -0.184)))
		for l in 4:
			unit.add_child(box(Vector3(0.5, 0.014, 0.006), louvre,
				Vector3(-0.09, 0.16 + l * 0.13, -0.185)))
		# side vent slats + feet
		unit.add_child(box(Vector3(0.012, 0.44, 0.22), grille_dark, Vector3(0.39, 0.38, 0)))
		unit.add_child(box(Vector3(0.1, 0.05, 0.3), grille_dark, Vector3(-0.28, 0.02, 0)))
		unit.add_child(box(Vector3(0.1, 0.05, 0.3), grille_dark, Vector3(0.28, 0.02, 0)))
		node.add_child(unit)
	return node

## Lattice pylon after the user's reference: dark-green tapering corner
## legs with ring braces, two crossarm levels, hanging insulator strings
## with the reference's little red accents at the wire points.
static func _make_grid_connection() -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(1.9, 0.06, 1.9), Color(0.58, 0.58, 0.6), Vector3(0, 0.03, 0)))
	var steel := Color(0.28, 0.37, 0.29)
	var lean := 0.084  # rad: legs converge (0.22 -> 0.06 half-width over 1.9)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var leg := box(Vector3(0.035, 1.95, 0.035), steel, Vector3.ZERO)
			leg.position = Vector3(0.14 * sx, 0.95, 0.14 * sz)
			leg.rotation = Vector3(-lean * sz, 0.0, lean * sx)
			node.add_child(leg)
	for ring_y: float in [0.45, 1.0, 1.5]:
		var half := lerpf(0.205, 0.075, ring_y / 1.9)
		node.add_child(box(Vector3(half * 2, 0.025, 0.025), steel, Vector3(0, ring_y, half)))
		node.add_child(box(Vector3(half * 2, 0.025, 0.025), steel, Vector3(0, ring_y, -half)))
		node.add_child(box(Vector3(0.025, 0.025, half * 2), steel, Vector3(half, ring_y, 0)))
		node.add_child(box(Vector3(0.025, 0.025, half * 2), steel, Vector3(-half, ring_y, 0)))
	# two crossarm levels with hanging insulators + red wire-point accents
	var porcelain := flat(Color(0.32, 0.24, 0.2))
	for arm: Array in [[1.62, 0.5], [1.88, 0.34]]:
		node.add_child(box(Vector3(arm[1] * 2.0 + 0.16, 0.04, 0.04), steel,
			Vector3(0, arm[0], 0)))
		for sx: float in [-1.0, 1.0]:
			var insulator := MeshInstance3D.new()
			var ins_mesh := CylinderMesh.new()
			ins_mesh.top_radius = 0.016
			ins_mesh.bottom_radius = 0.016
			ins_mesh.height = 0.1
			ins_mesh.radial_segments = 8
			insulator.mesh = ins_mesh
			insulator.position = Vector3(arm[1] * sx, arm[0] - 0.07, 0)
			insulator.material_override = porcelain
			node.add_child(insulator)
			var dot := MeshInstance3D.new()
			var dot_mesh := SphereMesh.new()
			dot_mesh.radius = 0.02
			dot_mesh.height = 0.04
			dot.mesh = dot_mesh
			dot.position = Vector3(arm[1] * sx, arm[0] - 0.13, 0)
			dot.material_override = flat(Color(0.85, 0.2, 0.18))
			node.add_child(dot)
	# ─── 110/20 kV switchyard (user request 2026-08-02: the station must
	# READ as the transmission link, not just a pylon on a slab) ───
	var tank_grey := Color(0.6, 0.62, 0.65)
	var steel_grey := Color(0.5, 0.52, 0.55)
	# power transformer: tank, radiator fin bank, conservator drum, three
	# HV bushings with red tips
	var trafo := Node3D.new()
	trafo.position = Vector3(0.52, 0, -0.48)
	trafo.add_child(box(Vector3(0.46, 0.32, 0.3), tank_grey, Vector3(0, 0.19, 0)))
	for i in 5:
		trafo.add_child(box(Vector3(0.05, 0.26, 0.1), steel_grey,
			Vector3(-0.18 + i * 0.09, 0.17, -0.21)))
	var drum := MeshInstance3D.new()
	var drum_mesh := CylinderMesh.new()
	drum_mesh.top_radius = 0.05
	drum_mesh.bottom_radius = 0.05
	drum_mesh.height = 0.3
	drum.mesh = drum_mesh
	drum.rotation_degrees.z = 90.0
	drum.position = Vector3(0, 0.42, 0.08)
	drum.material_override = flat(tank_grey)
	trafo.add_child(drum)
	for i in 3:
		var bushing := MeshInstance3D.new()
		var bushing_mesh := CylinderMesh.new()
		bushing_mesh.top_radius = 0.014
		bushing_mesh.bottom_radius = 0.022
		bushing_mesh.height = 0.16
		bushing_mesh.radial_segments = 8
		bushing.mesh = bushing_mesh
		bushing.position = Vector3(-0.13 + i * 0.13, 0.43, -0.06)
		bushing.material_override = porcelain
		trafo.add_child(bushing)
		trafo.add_child(box(Vector3(0.03, 0.02, 0.03), Color(0.85, 0.2, 0.18),
			Vector3(-0.13 + i * 0.13, 0.52, -0.06)))
	node.add_child(trafo)
	# circuit-breaker bay: steel frame + three interrupter columns
	var breakers := Node3D.new()
	breakers.position = Vector3(-0.55, 0, 0.5)
	breakers.add_child(box(Vector3(0.5, 0.05, 0.16), steel_grey, Vector3(0, 0.1, 0)))
	for i in 3:
		var column := MeshInstance3D.new()
		var column_mesh := CylinderMesh.new()
		column_mesh.top_radius = 0.03
		column_mesh.bottom_radius = 0.03
		column_mesh.height = 0.3
		column_mesh.radial_segments = 8
		column.mesh = column_mesh
		column.position = Vector3(-0.16 + i * 0.16, 0.27, 0)
		column.material_override = flat(Color(0.78, 0.8, 0.82))
		breakers.add_child(column)
		breakers.add_child(box(Vector3(0.05, 0.03, 0.05), steel_grey,
			Vector3(-0.16 + i * 0.16, 0.43, 0)))
	node.add_child(breakers)
	# 20 kV busbar: two posts, tube, post insulators — the outgoing side
	for post_x: float in [0.12, 0.82]:
		node.add_child(box(Vector3(0.04, 0.5, 0.04), steel_grey,
			Vector3(post_x, 0.25, 0.62)))
	node.add_child(box(Vector3(0.78, 0.035, 0.035), Color(0.72, 0.6, 0.35),
		Vector3(0.47, 0.52, 0.62)))
	for i in 3:
		node.add_child(box(Vector3(0.025, 0.08, 0.025), Color(0.32, 0.24, 0.2),
			Vector3(0.22 + i * 0.25, 0.57, 0.62)))
	# droppers: pylon arms -> breakers -> transformer -> busbar
	node.add_child(wire_segment(Vector3(-0.34, 1.7, 0), Vector3(-0.55, 0.45, 0.5),
		0.02, Color(0.16, 0.16, 0.18)))
	node.add_child(wire_segment(Vector3(-0.55, 0.45, 0.5), Vector3(0.39, 0.5, -0.54),
		0.02, Color(0.16, 0.16, 0.18)))
	node.add_child(wire_segment(Vector3(0.52, 0.5, -0.42), Vector3(0.47, 0.55, 0.6),
		0.02, Color(0.16, 0.16, 0.18)))
	# compact station house (protection + telecontrol)
	node.add_child(box(Vector3(0.34, 0.26, 0.3), Color(0.75, 0.3, 0.28),
		Vector3(-0.6, 0.13, -0.55)))
	node.add_child(box(Vector3(0.36, 0.04, 0.32), Color(0.5, 0.22, 0.2),
		Vector3(-0.6, 0.28, -0.55)))
	return node


## The 1000-kVA industrial station: the substation model scaled up with
## a second cooling-fin bank — unmistakably the bigger machine.
static func _make_substation_xl() -> Node3D:
	var station := _make_substation()
	station.scale = Vector3(1.18, 1.25, 1.18)
	station.add_child(box(Vector3(0.3, 0.34, 0.1), Color(0.5, 0.54, 0.6),
		Vector3(0.0, 0.24, -0.42)))
	return station


## One EV dispenser rebuilt by eye after the user's Sketchfab reference
## (EV Charging Station, f5ccea28f9c2…): white monolith on a dark
## rounded plinth, big dark front screen, TEAL glow strips edging plinth
## and pillar, white CCS handle with a black cable loop on the right.
static func ev_dispenser() -> Node3D:
	var unit := Node3D.new()
	var teal := Color(0.25, 0.9, 0.95)
	# plinth: dark slab with the glowing skirt strip
	unit.add_child(box(Vector3(0.2, 0.03, 0.14), Color(0.13, 0.14, 0.16),
		Vector3(0.0, 0.015, 0.0)))
	var skirt := box(Vector3(0.21, 0.012, 0.15), teal, Vector3(0.0, 0.032, 0.0))
	skirt.material_override = glow(teal)
	unit.add_child(skirt)
	# the white pillar + dark top cap
	unit.add_child(box(Vector3(0.14, 0.42, 0.09), Color(0.93, 0.94, 0.95),
		Vector3(0.0, 0.25, 0.0)))
	unit.add_child(box(Vector3(0.15, 0.035, 0.1), Color(0.13, 0.14, 0.16),
		Vector3(0.0, 0.475, 0.0)))
	# front screen (dark inset, slightly proud)
	unit.add_child(box(Vector3(0.1, 0.2, 0.012), Color(0.06, 0.07, 0.09),
		Vector3(0.0, 0.31, 0.048)))
	# teal edge strips: both vertical front edges + the top rim
	for edge_x in [-0.072, 0.072]:
		var strip := box(Vector3(0.012, 0.42, 0.012), teal,
			Vector3(edge_x, 0.25, 0.042))
		strip.material_override = glow(teal)
		unit.add_child(strip)
	var rim := box(Vector3(0.15, 0.012, 0.012), teal, Vector3(0.0, 0.462, 0.048))
	rim.material_override = glow(teal)
	unit.add_child(rim)
	# CCS handle (white nub) + black cable loop on the right flank
	unit.add_child(box(Vector3(0.03, 0.06, 0.03), Color(0.92, 0.93, 0.94),
		Vector3(0.085, 0.3, 0.02)))
	var cable := MeshInstance3D.new()
	var loop := TorusMesh.new()
	loop.inner_radius = 0.035
	loop.outer_radius = 0.055
	cable.mesh = loop
	cable.rotation_degrees.x = 90.0
	cable.position = Vector3(0.085, 0.18, 0.0)
	cable.material_override = flat(Color(0.1, 0.1, 0.12))
	unit.add_child(cable)
	return unit


## DC fast-charging hub (commercial pass 2026-08-06): eight dispensers
## rebuilt after the user's reference on an asphalt pad in two bays,
## with the buffer/trafo cabinet at the back corner.
static func _make_charging_park() -> Node3D:
	var park := Node3D.new()
	park.add_child(box(Vector3(1.8, 0.04, 1.6), Color(0.32, 0.33, 0.36),
		Vector3(0.5, 0.02, 0.5)))          # asphalt pad (2x2 footprint)
	# bay markings: pale stripes the cars nose up to
	for i in 4:
		park.add_child(box(Vector3(0.02, 0.005, 0.55), Color(0.8, 0.8, 0.78),
			Vector3(-0.25 + 0.42 * i + 0.21, 0.045, 0.5)))
	for i in 4:                            # dispensers, both rows face out
		var top := ev_dispenser()
		top.position = Vector3(-0.04 + 0.42 * i, 0.04, 0.28)
		top.rotation_degrees.y = 180.0
		park.add_child(top)
		var bottom := ev_dispenser()
		bottom.position = Vector3(-0.04 + 0.42 * i, 0.04, 0.72)
		park.add_child(bottom)
	park.add_child(box(Vector3(0.5, 0.42, 0.3), Color(0.85, 0.87, 0.9),
		Vector3(1.15, 0.21, 1.15)))        # buffer/trafo cabinet
	return park


## The three commercial-lot silhouettes (commercial pass; also the
## palette thumbnail for the commercial-zone tool): sawtooth hall /
## silo+stack food plant / glassy mall. Statics so the renderer and the
## hud share one source.
static func commercial_lot(ctype: int) -> Node3D:
	var lot := Node3D.new()
	match ctype:
		2:  # food production
			lot.add_child(box(Vector3(0.8, 0.3, 0.62),
				Color(0.82, 0.8, 0.74), Vector3(-0.03, 0.15, 0.0)))
			var silo := MeshInstance3D.new()
			var silo_mesh := CylinderMesh.new()
			silo_mesh.top_radius = 0.11
			silo_mesh.bottom_radius = 0.11
			silo_mesh.height = 0.62
			silo.mesh = silo_mesh
			silo.position = Vector3(0.34, 0.31, 0.22)
			silo.material_override = flat(Color(0.88, 0.88, 0.9))
			lot.add_child(silo)
			lot.add_child(box(Vector3(0.05, 0.5, 0.05),
				Color(0.75, 0.3, 0.25), Vector3(0.3, 0.42, -0.22)))
		3:  # mall
			lot.add_child(box(Vector3(0.86, 0.34, 0.7),
				Color(0.45, 0.62, 0.78), Vector3(0.0, 0.17, 0.0)))
			lot.add_child(box(Vector3(0.88, 0.05, 0.72),
				Color(0.92, 0.9, 0.85), Vector3(0.0, 0.37, 0.0)))
			lot.add_child(box(Vector3(0.3, 0.1, 0.06),
				Color(0.95, 0.75, 0.2), Vector3(0.0, 0.2, 0.36)))
		_:  # general production
			lot.add_child(box(Vector3(0.84, 0.28, 0.66),
				Color(0.62, 0.64, 0.68), Vector3(0.0, 0.14, 0.0)))
			for i in 3:
				lot.add_child(box(Vector3(0.84, 0.09, 0.14),
					Color(0.5, 0.52, 0.58),
					Vector3(0.0, 0.32, -0.2 + 0.22 * i)))
	return lot
