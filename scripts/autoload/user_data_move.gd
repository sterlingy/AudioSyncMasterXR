class_name UserDataMove
extends RefCounted
## The app was renamed from AudioSyncMaster to JamSyncXR (2026-11-27). On desktop,
## Godot keeps user:// in a folder named after the project, so the first start
## after the rename would find an empty folder. This copies the old folder's
## contents in once (settings, user presets, MIDI mappings, jams). The old folder
## is left alone as a backup. Android keeps data per package, so nothing to do there.
## Called by Settings before it loads, so it runs before anything reads user://.

const OLD_NAME := "AudioSyncMaster"
const MARKER := ".copied_from_audiosyncmaster"
## Godot's own caches and logs, which aren't worth carrying over.
const SKIP := ["logs", "objectdb_snapshots", "gut_temp_directory", "shader_cache", "vulkan"]


static func run() -> void:
	if OS.has_feature("android") or OS.has_feature("web"):
		return
	var new_dir := OS.get_user_data_dir()
	var old_dir := new_dir.get_base_dir().path_join(OLD_NAME)
	var n := copy_once(old_dir, new_dir)
	if n > 0:
		print("Copied %d files from %s to %s (the app is now called JamSyncXR)" % [n, old_dir, new_dir])


## Copies old_dir into new_dir unless that was done before, new_dir already has
## settings of its own, or old_dir doesn't exist. Returns the number of files copied.
static func copy_once(old_dir: String, new_dir: String) -> int:
	if old_dir == new_dir or not DirAccess.dir_exists_absolute(old_dir):
		return 0
	if FileAccess.file_exists(new_dir.path_join(MARKER)) or FileAccess.file_exists(new_dir.path_join("settings.cfg")):
		return 0
	DirAccess.make_dir_recursive_absolute(new_dir)
	var n := _copy_tree(old_dir, new_dir, true)
	var f := FileAccess.open(new_dir.path_join(MARKER), FileAccess.WRITE)
	if f:
		f.store_line("Copied from %s on %s" % [old_dir, Time.get_datetime_string_from_system()])
	return n


static func _copy_tree(from: String, to: String, top: bool) -> int:
	var n := 0
	var dir := DirAccess.open(from)
	if dir == null:
		return 0
	dir.include_hidden = true
	for sub in dir.get_directories():
		if top and sub in SKIP:
			continue
		DirAccess.make_dir_recursive_absolute(to.path_join(sub))
		n += _copy_tree(from.path_join(sub), to.path_join(sub), false)
	for file in dir.get_files():
		var dest := to.path_join(file)
		if not FileAccess.file_exists(dest) and DirAccess.copy_absolute(from.path_join(file), dest) == OK:
			n += 1
	return n
