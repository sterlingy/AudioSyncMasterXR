# Updates the MusicInputKit submodule (addons\music_input_kit) to the latest MusicInputKit on GitHub,
# so this project has the newest playable 3D objects.
#   tools\update_music_input_kit.ps1          move to MusicInputKit's latest main
#   tools\update_music_input_kit.ps1 -Pinned  just fetch the version this project already records
# Afterwards, commit the new addons\music_input_kit pointer here to keep it.
# MusicInputKit itself is changed in its own clone (D:\MusicInputKit on music-machine),
# then pushed; never edit addons\music_input_kit here.
param([switch]$Pinned)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    if ($Pinned) {
        git submodule update --init addons/music_input_kit
    } else {
        git submodule update --init --remote addons/music_input_kit
    }
    if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    $rev = git -C addons/music_input_kit log -1 --format="%h %s"
    "MusicInputKit in addons\music_input_kit: $rev"
    $changed = git status --porcelain addons/music_input_kit
    if ($changed) { "The MusicInputKit version changed: commit addons/music_input_kit to keep it." }
} finally {
    Pop-Location
}
