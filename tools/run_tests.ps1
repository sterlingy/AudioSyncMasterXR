# Runs the GUT test suite headless.
# Godot is taken from $env:GODOT, else the first of the known install paths that exists.
$root = Split-Path $PSScriptRoot -Parent
$candidates = @(
    $env:GODOT,
    "C:\Godot\Godot_v4.7.2-stable_win64_console.exe",
    "$env:USERPROFILE\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
)
$godot = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $godot) { Write-Error "Godot 4.7.2 not found; set `$env:GODOT"; exit 1 }
& $godot --headless --path $root -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
exit $LASTEXITCODE
