extends "res://addons/godot-xr-tools/objects/viewport_2d_in_3d_body.gd"
## The XR app panel's input surface, with two changes to XR Tools' version:
## - Pokes and laser presses go to the app as mouse events only. XR Tools also
##   sends a touch event just before each mouse event; controls react to the
##   touch, so the mouse event right behind it undoes it (a dropdown opens,
##   then closes).
## - Whatever presses (a fingertip or a laser) becomes the mouse. XR Tools
##   keeps the first pointer that touched the panel, so a laser resting on it
##   from the other hand made fingertip presses do nothing.


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	if event.event_type == XRToolsPointerEvent.Type.PRESSED and not _presses.has(_mouse):
		_mouse = event.pointer
	super(event)


func _report_touch_down(_index: int, _at: Vector2) -> void:
	pass


func _report_touch_up(_index: int, _at: Vector2) -> void:
	pass


func _report_touch_move(_index: int, _pressed: bool, _from: Vector2, _to: Vector2) -> void:
	pass
