extends GutTest
## The XR size buttons: [−] 100% [+] [↺].

func _control(key := "") -> SizeControl:
	var c := SizeControl.new()
	c.setting = key
	add_child_autofree(c)
	return c


func test_steps_clamp_and_reset() -> void:
	var c := _control()
	var got := []
	c.changed.connect(func(v): got.append(v))
	assert_eq(c.value, 1.0)
	c.step(1)
	assert_almost_eq(c.value, 1.1, 1e-6)
	for i in 20:
		c.step(1)
	assert_almost_eq(c.value, SizeControl.MAX, 1e-6, "no bigger than 200 %")
	for i in 30:
		c.step(-1)
	assert_almost_eq(c.value, SizeControl.MIN, 1e-6, "no smaller than 50 %")
	c.set_size(1.0)
	assert_eq(c.value, 1.0, "reset")
	assert_eq(got.back(), 1.0)
	assert_eq(c.get_node("Value").text, "100%")


func test_buttons_press() -> void:
	var c := _control()
	var press := func(n: String):
		var b: XRButton = c.get_node(n)
		b.pointer_event.emit(XRToolsPointerEvent.new(XRToolsPointerEvent.Type.PRESSED, b, b, b.global_position, b.global_position))
	press.call("Bigger")
	press.call("Bigger")
	assert_almost_eq(c.value, 1.2, 1e-6, "+ twice")
	press.call("Smaller")
	assert_almost_eq(c.value, 1.1, 1e-6, "− once")
	press.call("Reset")
	assert_eq(c.value, 1.0, "↺")


func test_size_is_remembered() -> void:
	var was: Variant = Settings.get_value("xr_size_play_table")
	var c := _control("xr_size_play_table")
	c.set_size(1.4)
	var again := _control("xr_size_play_table")
	assert_almost_eq(again.value, 1.4, 1e-6, "next time it starts at the saved size")
	Settings.set_value("xr_size_play_table", was)
