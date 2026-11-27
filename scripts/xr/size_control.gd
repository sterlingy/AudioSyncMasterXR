class_name SizeControl
extends Node3D
## Smaller / bigger / reset buttons for one thing in the XR scene (the panel,
## your instrument, the play table): [−] 100% [+] [↺]. Steps of 10 % between
## 50 % and 200 %; ↺ puts that one thing back to its normal size. The size is
## kept in Settings under `setting`, so it's the same next time.

signal changed(size: float)

const STEP := 0.1
const MIN := 0.5
const MAX := 2.0

## Settings key ("" = don't save).
@export var setting := ""
## What the size is for, shown before the percentage ("Panel", "Instrument"...).
@export var title := ""

var value := 1.0
var _label: Label3D


func _ready() -> void:
	if setting != "":
		value = clampf(float(Settings.get_value(setting)), MIN, MAX)
	var smaller := _button("−", Vector3(-0.075, 0, 0))
	smaller.pressed.connect(step.bind(-1))
	var bigger := _button("+", Vector3(0.075, 0, 0))
	bigger.pressed.connect(step.bind(1))
	var reset := _button("↺", Vector3(0.13, 0, 0))
	reset.name = "Reset"
	reset.pressed.connect(set_size.bind(1.0))
	smaller.name = "Smaller"
	bigger.name = "Bigger"
	_label = _text("Value", 40, Vector3.ZERO)
	if title != "":
		_text("Title", 28, Vector3(0.028, 0.032, 0)).text = title # small, over the buttons
	_show()


func _text(n: String, px: int, pos: Vector3) -> Label3D:
	var l := Label3D.new()
	l.name = n
	l.pixel_size = 0.0006
	l.font_size = px
	l.outline_size = 8
	l.outline_modulate = Color(0.07, 0.075, 0.09)
	l.modulate = Color(0.85, 0.87, 0.92)
	l.position = pos
	add_child(l)
	return l


func _button(t: String, pos: Vector3) -> XRButton:
	var b := XRButton.new()
	b.text = t
	b.position = pos
	add_child(b)
	return b


## One step smaller (-1) or bigger (+1).
func step(dir: int) -> void:
	set_size(snappedf(value + STEP * dir, 0.01))


func set_size(v: float) -> void:
	v = clampf(v, MIN, MAX)
	if is_equal_approx(v, value):
		_show()
		return
	value = v
	if setting != "":
		Settings.set_value(setting, value)
	_show()
	changed.emit(value)


func _show() -> void:
	if _label:
		_label.text = "%d%%" % roundi(value * 100.0)
