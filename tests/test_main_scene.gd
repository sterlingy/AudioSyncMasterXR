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
