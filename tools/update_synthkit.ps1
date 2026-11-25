# Updates the SynthKit submodule (addons\synthkit) to the latest SynthKit on GitHub,
# so this project builds with the newest shared instruments.
#   tools\update_synthkit.ps1          move to SynthKit's latest main
#   tools\update_synthkit.ps1 -Pinned  just fetch the version this project already records
# Afterwards, commit the new addons\synthkit pointer here to keep it.
# SynthKit itself is changed and built in its own clone (D:\Godot_Projects\SynthKit),
# then pushed; never edit addons\synthkit here.
param([switch]$Pinned)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    if ($Pinned) {
        git submodule update --init addons/synthkit
    } else {
        git submodule update --init --remote addons/synthkit
    }
    if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    $rev = git -C addons/synthkit log -1 --format="%h %s"
    "SynthKit in addons\synthkit: $rev"
    $changed = git status --porcelain addons/synthkit
    if ($changed) { "The SynthKit version changed: commit addons/synthkit to keep it." }
} finally {
    Pop-Location
}
