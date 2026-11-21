extends GutTest
## The whole app loads: catches script errors in UI files no other test touches.


func test_main_scene_loads() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	assert_not_null(packed, "main.tscn and every script it uses parse")
	var main := packed.instantiate()
	add_child_autofree(main)
	await wait_frames(5)
	assert_not_null(main.get("players_view"), "Jam tab built")
	assert_not_null(main.get("recorder"), "jam recorder built")
	main._open_share()
	await wait_frames(2)
	assert_not_null(main._share_qr.texture, "share dialog shows a QR code")
	main._share_dialog.hide()


func test_midi_dialog_and_bluetooth_scan() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child_autofree(main)
	await wait_frames(3)
	var dlg: MidiSettings = main._midi_dialog
	assert_not_null(dlg)
	dlg.popup_centered(Vector2i(620, 560))
	await wait_frames(2)
	Midi.scan_bluetooth(1)
	await wait_frames(1)
	if Midi.has_android_plugin():
		pass_test("scanning on Android")
	else:
		assert_string_contains(dlg._bt_status.text, "Android", "desktop explains where Bluetooth MIDI pairing happens")
	dlg.hide()


func test_touch_keyboard_plays_chords_and_fits_octaves() -> void:
	var kb := KeyboardView.new()
	kb.size = Vector2(1000, 120)
	add_child_autofree(kb)
	await wait_frames(1)
	Midi.release_all()
	for finger in 2:
		var t := InputEventScreenTouch.new()
		t.index = finger
		t.pressed = true
		t.position = Vector2(30 + finger * 120, 110)
		kb._gui_input(t)
	assert_eq(Midi.held.size(), 2, "two fingers hold two notes")
	# The emulated mouse click for the first finger doesn't add a third note.
	var m := InputEventMouseButton.new()
	m.button_index = MOUSE_BUTTON_LEFT
	m.pressed = true
	m.position = Vector2(30, 110)
	m.device = InputEvent.DEVICE_ID_EMULATION
	kb._gui_input(m)
	assert_eq(Midi.held.size(), 2)
	for finger in 2:
		var t := InputEventScreenTouch.new()
		t.index = finger
		t.pressed = false
		kb._gui_input(t)
	assert_eq(Midi.held.size(), 0, "lifting both fingers releases both")
	kb.size = Vector2(400, 120)
	kb._fit_octaves()
	assert_eq(kb.octaves, 1, "a phone-width keyboard shows fewer, wider keys")


func test_ui_scale_follows_screen_density() -> void:
	var main_script: GDScript = load("res://scripts/main.gd")
	assert_eq(main_script.ui_scale_for_dpi(96.0), 1.0, "desktop stays 1:1")
	assert_eq(main_script.ui_scale_for_dpi(420.0), 2.0, "phone")
	assert_eq(main_script.ui_scale_for_dpi(1200.0), 3.0, "capped")
