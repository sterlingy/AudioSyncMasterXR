@tool
extends EditorExportPlugin
## Steam Frame runs apks inside Lepton, which only starts an <activity> that has
## a LAUNCHER intent filter and ignores activity aliases. Godot puts LAUNCHER on
## the GodotAppLauncher alias and keeps it off GodotApp, so without this Lepton
## exits before Android boots and Steam sits on the loading screen.
##
## Applies to presets using the Khronos vendor plugin, which is how Steam Frame
## apks are exported.

const KHRONOS_OPTION := "xr_features/enable_khronos_plugin"


func _get_name() -> String:
	return "SteamFrameLauncher"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_manifest_activity_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
	var preset := get_export_preset()
	if preset == null or not preset.get_or_env(KHRONOS_OPTION, ""):
		return ""
	# Godot strips self-closing LAUNCHER categories from GodotApp, so this one
	# needs an explicit closing tag to survive.
	return """
			<intent-filter>
				<action android:name="android.intent.action.MAIN" />
				<category android:name="android.intent.category.LAUNCHER"></category>
				<category android:name="org.khronos.openxr.intent.category.IMMERSIVE_HMD" />
			</intent-filter>
"""
