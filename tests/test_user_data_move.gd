extends GutTest
## UserDataMove: the one-time copy of the old AudioSyncMaster user folder.

var _root := ""


func before_each() -> void:
	_root = OS.get_user_data_dir().path_join("test_output/user_data_move_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_root.path_join("old/presets/Lumen"))
	DirAccess.make_dir_recursive_absolute(_root.path_join("old/logs"))
	_write(_root.path_join("old/settings.cfg"), "[app]\ninstrument=\"Lumen\"\n")
	_write(_root.path_join("old/presets/Lumen/mine.json"), "{}")
	_write(_root.path_join("old/logs/godot.log"), "log")


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func test_copies_data_once_and_skips_logs() -> void:
	var old_dir := _root.path_join("old")
	var new_dir := _root.path_join("new")
	assert_eq(UserDataMove.copy_once(old_dir, new_dir), 2, "settings and the user preset")
	assert_true(FileAccess.file_exists(new_dir.path_join("settings.cfg")))
	assert_true(FileAccess.file_exists(new_dir.path_join("presets/Lumen/mine.json")))
	assert_false(FileAccess.file_exists(new_dir.path_join("logs/godot.log")), "logs stay behind")
	assert_true(FileAccess.file_exists(old_dir.path_join("settings.cfg")), "the old folder is kept")
	assert_eq(UserDataMove.copy_once(old_dir, new_dir), 0, "only once")


func test_leaves_a_folder_that_already_has_settings() -> void:
	var new_dir := _root.path_join("new")
	DirAccess.make_dir_recursive_absolute(new_dir)
	_write(new_dir.path_join("settings.cfg"), "[app]\ninstrument=\"Comet\"\n")
	assert_eq(UserDataMove.copy_once(_root.path_join("old"), new_dir), 0)
	assert_string_contains(FileAccess.get_file_as_string(new_dir.path_join("settings.cfg")), "Comet")


func test_nothing_to_copy() -> void:
	assert_eq(UserDataMove.copy_once(_root.path_join("missing"), _root.path_join("new")), 0)


func test_sessions_from_before_the_rename_still_load() -> void:
	assert_true("AudioSyncMaster" in JamRecorder.APP_NAMES)
	assert_eq(JamRecorder.APP_NAME, "JamSyncXR")
