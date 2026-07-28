extends PanelContainer
## Sidecar status debug panel (Phase 1 acceptance: green/red per backend).
## Built in code — views stay trivial; state lives in the autoloads.

const STATE_COLORS := {
	SidecarManager.State.STOPPED: Color(0.5, 0.5, 0.5),
	SidecarManager.State.STARTING: Color(0.95, 0.8, 0.2),
	SidecarManager.State.HEALTHY: Color(0.3, 0.85, 0.3),
	SidecarManager.State.DOWN: Color(0.9, 0.25, 0.25),
	SidecarManager.State.RESTARTING: Color(0.95, 0.55, 0.15),
}
const STATE_NAMES := {
	SidecarManager.State.STOPPED: "stopped",
	SidecarManager.State.STARTING: "starting",
	SidecarManager.State.HEALTHY: "healthy",
	SidecarManager.State.DOWN: "DOWN",
	SidecarManager.State.RESTARTING: "restarting",
}

var _rows := {}  # id -> {dot: ColorRect, label: Label}


func _ready() -> void:
	var vbox := VBoxContainer.new()
	add_child(vbox)
	var title := Label.new()
	title.text = "Sidecars (F1)"
	vbox.add_child(title)
	for id: String in SidecarManager.ids():
		var row := HBoxContainer.new()
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(14, 14)
		var label := Label.new()
		row.add_child(dot)
		row.add_child(label)
		vbox.add_child(row)
		_rows[id] = {"dot": dot, "label": label}
		_refresh(id)
	SidecarManager.state_changed.connect(func(id: String, _s: int) -> void: _refresh(id))
	CosimBridge.handshake_completed.connect(
		func(id: String, _ok: bool, _i: Dictionary) -> void: _refresh(id))


func _refresh(id: String) -> void:
	if not _rows.has(id):
		return
	var state: SidecarManager.State = SidecarManager.state_of(id)
	_rows[id]["dot"].color = STATE_COLORS[state]
	var text := "%s — %s" % [id, STATE_NAMES[state]]
	var version_info: Dictionary = CosimBridge.info.get(id, {})
	if not version_info.is_empty():
		text += "  ·  %s (contract %s)" % [
			version_info.get("solver", "?"), version_info.get("contract", "?")]
	_rows[id]["label"].text = text
