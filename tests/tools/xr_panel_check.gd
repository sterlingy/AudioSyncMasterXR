extends SceneTree
## Feeds the XR app panel the pointer events a fingertip poke produces (on the
## desktop, no headset) and checks that a knob turns and the instrument
## dropdown opens. Run: godot --path . -s res://tests/tools/xr_panel_check.gd
## Exit 0 = pass.

var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var xr: Node3D = load("res://scenes/xr_main.tscn").instantiate()
	root.add_child(xr)
	for i in 30:
		await process_frame
	var panel: Node3D = xr.panel
	var body: Node = panel.get_node("StaticBody3D")
	var app: Control = xr.app
	var pointer := Node3D.new() # stands in for the fingertip poke
	root.add_child(pointer)

	# A knob: press, drag up 60 px, release.
	var knobs := app.find_children("*", "Knob", true, false)
	var knob: Control = null
	for k in knobs:
		if k.is_visible_in_tree():
			knob = k
			break
	if knob == null:
		_check(false, "found a visible knob")
	else:
		var c := knob.get_global_rect().get_center()
		var before: float = knob.value
		_poke(body, pointer, XRToolsPointerEvent.Type.ENTERED, c, c)
		_poke(body, pointer, XRToolsPointerEvent.Type.PRESSED, c, c)
		for s in 6:
			var a := c + Vector2(0, -10 * s)
			var b := c + Vector2(0, -10 * (s + 1))
			_poke(body, pointer, XRToolsPointerEvent.Type.MOVED, b, a)
			await process_frame
		_poke(body, pointer, XRToolsPointerEvent.Type.RELEASED, c + Vector2(0, -60), c + Vector2(0, -60))
		_poke(body, pointer, XRToolsPointerEvent.Type.EXITED, c + Vector2(0, -60), c + Vector2(0, -60))
		await process_frame
		_check(not is_equal_approx(knob.value, before), "knob turned by a poke drag (%.3f -> %.3f)" % [before, knob.value])

	# The instrument dropdown: tap it.
	var opt: OptionButton = app._inst_select
	var oc := opt.get_global_rect().get_center()
	_poke(body, pointer, XRToolsPointerEvent.Type.ENTERED, oc, oc)
	_poke(body, pointer, XRToolsPointerEvent.Type.PRESSED, oc, oc)
	await process_frame
	_poke(body, pointer, XRToolsPointerEvent.Type.RELEASED, oc, oc)
	await process_frame
	await process_frame
	_check(opt.get_popup().visible, "instrument dropdown opens on a tap")
	# Pick the next instrument from the open list.
	if opt.get_popup().visible:
		var pop := opt.get_popup()
		var want := (opt.selected + 1) % opt.item_count
		var r := Rect2(pop.position, pop.size)
		var y := r.position.y + (want + 0.5) * (r.size.y / opt.item_count)
		var at := Vector2(r.get_center().x, y)
		_poke(body, pointer, XRToolsPointerEvent.Type.MOVED, at, oc)
		_poke(body, pointer, XRToolsPointerEvent.Type.PRESSED, at, at)
		await process_frame
		_poke(body, pointer, XRToolsPointerEvent.Type.RELEASED, at, at)
		await process_frame
		_check(opt.selected == want, "picked %s from the list (selected %d, wanted %d)" % [opt.get_item_text(want), opt.selected, want])
	_poke(body, pointer, XRToolsPointerEvent.Type.EXITED, oc, oc)

	# Move handle: grab it with a fingertip, move 30 cm right and 10 cm up.
	var h: GrabHandle = xr.workspace.get_node("MoveHandle")
	var before_ws: Vector3 = xr.workspace.global_position
	pointer.global_position = h.global_position
	h.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.PRESSED, pointer, h, h.global_position, h.global_position))
	pointer.global_position += Vector3(0.3, 0.1, 0)
	await process_frame
	h.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.RELEASED, pointer, h, pointer.global_position, pointer.global_position))
	var moved: Vector3 = xr.workspace.global_position - before_ws
	_check(moved.distance_to(Vector3(0.3, 0.1, 0)) < 0.01, "panel and instrument follow the move handle (%s)" % moved)
	# Instrument handle moves only the table.
	var th: GrabHandle = xr.table.get_node("InstrumentHandle")
	var panel_at: Vector3 = xr.panel.global_position
	var table_at: Vector3 = xr.table.global_position
	pointer.global_position = th.global_position
	th.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.PRESSED, pointer, th, th.global_position, th.global_position))
	pointer.global_position += Vector3(0, 0.05, 0.1)
	await process_frame
	th.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.RELEASED, pointer, th, pointer.global_position, pointer.global_position))
	_check(xr.panel.global_position.is_equal_approx(panel_at) and xr.table.global_position.distance_to(table_at + Vector3(0, 0.05, 0.1)) < 0.01,
		"instrument handle moves just the instrument")

	# The play table: built, both hands hooked up, follows its handle, toggles.
	var pt: Node3D = xr.play_table # untyped: -s scripts compile before the autoloads exist
	_check(pt != null and pt.objects.size() == 14, "play table with all 14 kit objects")
	_check(pt.controllers.size() == 2, "both hands play the play table (%d)" % pt.controllers.size())
	var top_btn := app.find_children("*", "Button", true, false).filter(func(b): return b.text == "Play table")
	_check(top_btn.size() == 1, "Play table button in the panel")
	var ph: GrabHandle = pt.get_node("PlayTableHandle")
	var pt_at: Vector3 = pt.global_position
	pointer.global_position = ph.global_position
	ph.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.PRESSED, pointer, ph, ph.global_position, ph.global_position))
	pointer.global_position += Vector3(0, 0.05, 0.1)
	await process_frame
	ph.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.RELEASED, pointer, ph, pointer.global_position, pointer.global_position))
	_check(pt.global_position.distance_to(pt_at + Vector3(0, 0.05, 0.1)) < 0.01, "play table handle moves the play table")
	var was: bool = pt.visible
	xr.toggle_play_table()
	_check(pt.visible != was and pt.hands.enabled == pt.visible, "Play table button hides and shows it")
	xr.toggle_play_table()

	# Sizes: + on each grows just that one; ↺ resets just that one.
	var saved := {}
	var settings: Node = root.get_node("/root/Settings") # by path: -s scripts compile before the autoloads exist
	for k in ["xr_size_panel", "xr_size_instrument", "xr_size_play_table"]:
		saved[k] = settings.get_value(k)
	for c in [xr.panel_size, xr.instrument_size, xr.play_table_size]:
		c.set_size(1.0)
	var press := func(ctl: Node, n: String):
		var b: Node3D = ctl.get_node(n)
		b.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.PRESSED, pointer, b, b.global_position, b.global_position))
	var bottom := func() -> Vector3:
		var sz: Vector2 = xr.panel.get("screen_size")
		return xr.panel.global_transform * Vector3(0, -sz.y / 2.0, 0)
	var bottom_before: Vector3 = bottom.call()
	press.call(xr.panel_size, "Bigger")
	press.call(xr.panel_size, "Bigger")
	var sz2: Vector2 = xr.panel.get("screen_size")
	_check(sz2.is_equal_approx(Vector2(1.2, 0.675) * 1.2), "panel + makes the screen bigger (%s)" % sz2)
	_check((bottom.call() as Vector3).distance_to(bottom_before) < 0.002, "panel grows upward from its bottom edge")
	_check(is_equal_approx(xr.table.scale.x, 1.0) and is_equal_approx(pt.scale.x, 1.0), "panel size leaves the tables alone")
	press.call(xr.instrument_size, "Bigger")
	_check(is_equal_approx(xr.table.scale.x, 1.1), "instrument + scales the instrument (%.2f)" % xr.table.scale.x)
	_check(is_equal_approx(xr.instrument_size.global_basis.get_scale().x, 1.0), "its size buttons stay the same size")
	press.call(xr.play_table_size, "Smaller")
	_check(is_equal_approx(pt.scale.x, 0.9), "play table − shrinks the play table (%.2f)" % pt.scale.x)
	xr.reset_position()
	_check(is_equal_approx(xr.table.scale.x, 1.1) and is_equal_approx(pt.scale.x, 0.9), "the wrist reset keeps sizes")
	press.call(xr.instrument_size, "Reset")
	_check(is_equal_approx(xr.table.scale.x, 1.0) and is_equal_approx(pt.scale.x, 0.9), "instrument ↺ resets only the instrument")
	press.call(xr.panel_size, "Reset")
	_check((xr.panel.get("screen_size") as Vector2).is_equal_approx(Vector2(1.2, 0.675)) and is_equal_approx(pt.scale.x, 0.9), "panel ↺ resets only the panel")
	press.call(xr.play_table_size, "Reset")
	_check(is_equal_approx(pt.scale.x, 1.0), "play table ↺ resets the play table")
	for k in saved:
		settings.set_value(k, saved[k])
	print("PASS" if fails == 0 else "FAILED (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


## Sends one pointer event at panel pixel `at` (moving from `from`).
func _poke(body: Node, pointer: Node3D, type: int, at: Vector2, from: Vector2) -> void:
	var ev := XRToolsPointerEvent.new(type, pointer, body, _to_3d(body, at), _to_3d(body, from))
	body.pointer_event.emit(ev)


func _to_3d(body: Node, px: Vector2) -> Vector3:
	var shape: CollisionShape3D = body.get_node("CollisionShape3D")
	var ss: Vector2 = body.screen_size
	var vs: Vector2 = body.viewport_size
	var local := Vector3((px.x / vs.x - 0.5) * ss.x, (0.5 - px.y / vs.y) * ss.y, 0.0)
	return shape.global_transform * local
