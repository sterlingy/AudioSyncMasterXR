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
