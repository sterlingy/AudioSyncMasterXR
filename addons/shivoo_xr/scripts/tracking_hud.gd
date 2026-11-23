class_name TrackingHud
extends CanvasLayer
## The screens a tracking node drives around its experience: the place and reset
## buttons, a permission notice, and whether the camera can capture. Optional: a
## project without one leaves the node's hud export empty.
##
## Extend it in the project and override what that project shows. These tracking
## nodes use only this contract, so they never name a script a project wrote; the
## capture UI itself (capture.js, the shutter, the review screen) stays in the
## project, where the camera and page-side compositing live.

## The place button was pressed.
signal place_pressed
## The reset button was pressed.
signal reset_pressed
## The review screen was closed, after a capture taken in an XR session. A tracking
## node starts the session again here, while the browser still counts the press as
## the one that may ask for it.
signal review_closed


## Shows the place button, for a surface the middle of the screen points at that
## has nothing on it yet.
func show_place_ui(_on: bool) -> void:
	pass


## Shows the reset button, once content has been put on a surface.
func show_reset_ui(_on: bool) -> void:
	pass


## Says the browser refused the camera or motion sensors, and how to allow them.
func show_permission_error() -> void:
	pass


## Whether the camera button shows. Capture reads a canvas the page can read, which
## only the flat (non-WebXR) view has.
func set_capture_available(_available: bool) -> void:
	pass


## Whether capture is now taking place inside an XR session. The page's capture code
## composites the XR layer over the session's camera image, so the button shows once
## that is known to work; a project without page-side capture ignores it.
func set_capture_in_xr(_on: bool) -> void:
	pass


## Whether the camera screen is open, which owns the screen and the fingers on it:
## a scene leaves its own touch gestures out while it is.
func capture_open() -> bool:
	return false


## Fits the HUD again, once the window or XR session changed size.
func refresh_layout() -> void:
	pass
