# Builds the jamcore GDExtension.
#   tools\build.ps1                  Windows debug (default)
#   tools\build.ps1 -Target release
#   tools\build.ps1 -Platform android  (arm64, needs ANDROID_HOME with an NDK)
param([string]$Platform = "windows", [string]$Target = "debug", [string]$Arch = "")
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$godot = "$env:USERPROFILE\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
Push-Location "$root\jamcore"
try {
    if (-not (Test-Path extension_api.json)) { & $godot --headless --dump-extension-api | Out-Null }
    $args = @("platform=$Platform", "target=template_$Target", "-j$env:NUMBER_OF_PROCESSORS")
    if ($Platform -eq "android" -and $Arch -eq "") { $Arch = "arm64" }
    if ($Platform -eq "android") {
        # Use the newest NDK installed (godot-cpp otherwise asks for its own pinned version).
        $ndk = Get-ChildItem (Join-Path $env:ANDROID_HOME "ndk") -Name | Sort-Object { [version]$_ } | Select-Object -Last 1
        $args += "ndk_version=$ndk"
    }
    if ($Arch -ne "") { $args += "arch=$Arch" }
    python -m SCons @args
} finally { Pop-Location }
