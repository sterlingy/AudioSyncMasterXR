class_name ShivooDOMOverlay
extends Node
## Puts a project's HTML/CSS over the page canvas, and inside Chrome Android
## immersive-ar sessions through the WebXR DOM Overlays API.
##
## Add one per page. On web it loads web/dom_overlay.js, creates (or reuses) the
## element with overlay_id, injects html/css, wraps immersive-ar session requests
## to ask for dom-overlay, and registers the event bridge.
##
## Page controls can emit events without extra JavaScript:
##   <button data-shivoo-event="overlay:ping" data-shivoo-data='{"text":"hi"}'>
##   <button data-shivoo-exit>
##   <input data-shivoo-input-event="overlay:text">
## Elements with data-shivoo-status and data-shivoo-log are updated by the page
## script. JavaScript can call ShivooDOMOverlay.emit(name, data) and listen for
## the shivoo:godot DOM event.
##
## Events arrive in page_event. send() goes the other way, to a shivoo:godot
## event and the data-shivoo-log element.
##
## The browser only composites a DOM overlay during immersive-ar, and only where
## it implements the WebXR DOM Overlays API. Elsewhere the element is still a
## normal page element over the canvas.

signal overlay_ready
## The session started, but the browser did not composite the overlay.
signal overlay_ignored
signal page_event(event: Dictionary)
signal session_started(overlay_type: String)
signal session_ended

const OVERLAY_JS := ShivooXRPaths.ADDON_DIR + "/web/dom_overlay.js"

@export var overlay_id := "shivoo-dom-overlay"
## Optional files; when set they take precedence over the inline strings. Keep
## them in the export preset's include_filter so FileAccess can read them.
@export_file("*.html") var html_file := ""
@export_file("*.css") var css_file := ""
@export_multiline var html := ""
@export_multiline var css := ""
## If set, the overlay only installs when the page URL has this query key, such
## as "domoverlay" for ?domoverlay=1. Empty installs on every page.
@export var activation_query := ""
## Hide the element outside an immersive session. It stays in layout, so the
## browser can still composite it when the session starts.
@export var hide_outside_xr := false
## Log pointer, touch and form input on the overlay to [data-shivoo-log].
@export var log_input := false

var _overlay: JavaScriptObject
## Retained here so JavaScriptBridge does not collect the callback.
var _callback: JavaScriptObject
var _enabled := false
var _active := false
var _type := ""


func _ready() -> void:
	if not OS.has_feature("web"):
		return
	if not _query_allows():
		return
	var source := FileAccess.get_file_as_string(OVERLAY_JS)
	if source.is_empty():
		push_error("ShivooDOMOverlay: %s is missing." % OVERLAY_JS)
		return
	JavaScriptBridge.eval(source, true)
	_overlay = JavaScriptBridge.get_interface("ShivooDOMOverlay")
	if _overlay == null:
		push_error("ShivooDOMOverlay: web/dom_overlay.js did not install.")
		return
	var options := {
		"id": overlay_id,
		"html": _content(html_file, html),
		"css": _content(css_file, css),
		"hideOutsideXr": hide_outside_xr,
		"logInput": log_input,
	}
	if not bool(_overlay.install(JSON.stringify(options))):
		push_error("ShivooDOMOverlay: another overlay is already installed on this page.")
		return
	_callback = JavaScriptBridge.create_callback(_on_page_event)
	_overlay.setGodotCallback(_callback)
	_enabled = true
	overlay_ready.emit.call_deferred()


func _exit_tree() -> void:
	if _enabled and _overlay != null:
		_overlay.setGodotCallback(null)
	_overlay = null
	_callback = null
	_enabled = false


## Sends an event to the page. It arrives as a shivoo:godot CustomEvent and in
## any [data-shivoo-log] element.
func send(event_name: String, data: Dictionary = {}) -> void:
	if not _enabled:
		return
	_overlay.receive(JSON.stringify({"name": event_name, "data": data}))


## Ends the active immersive session, if there is one.
func end_session() -> void:
	if _enabled:
		_overlay.end()


## The browser's domOverlayState type: "screen", "floating", "head-locked", or
## empty when no overlay is active.
func get_overlay_type() -> String:
	return _type


## Whether the browser is currently compositing the overlay.
func is_active() -> bool:
	return _active


func _query_allows() -> bool:
	if activation_query.is_empty():
		return true
	return bool(JavaScriptBridge.eval(
		"new URLSearchParams(location.search).has(%s)" % JSON.stringify(activation_query),
		true))


func _content(path: String, inline: String) -> String:
	if path.is_empty():
		return inline
	if not FileAccess.file_exists(path):
		push_warning("ShivooDOMOverlay: %s is missing; using inline content." % path)
		return inline
	return FileAccess.get_file_as_string(path)


func _on_page_event(args: Array) -> void:
	if args.is_empty():
		return
	var parsed = JSON.parse_string(str(args[0]))
	if not parsed is Dictionary:
		return
	var event: Dictionary = parsed
	var event_name := str(event.get("name", ""))
	var data = event.get("data", {})
	if not (data is Dictionary):
		data = {}
	match event_name:
		"shivoo:session-start":
			_type = str(data.get("type", ""))
			_active = bool(data.get("active", false))
			session_started.emit(_type)
			if not _active:
				overlay_ignored.emit()
			return
		"shivoo:session-end":
			_type = ""
			_active = false
			session_ended.emit()
			return
	page_event.emit(event)
