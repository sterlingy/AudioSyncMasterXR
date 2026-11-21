# Runs the GUT test suite headless.
$root = Split-Path $PSScriptRoot -Parent
$godot = "$env:USERPROFILE\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path $root -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
