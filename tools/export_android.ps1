# Builds an Android APK from an export preset, headless.
#   tools\export_android.ps1 Quest                 Quest (Meta OpenXR loader)       -> build\android\AudioSyncMasterQuest.apk
#   tools\export_android.ps1 "Android XR"          Android XR, e.g. Aura           -> build\android\AudioSyncMasterXR.apk
#   tools\export_android.ps1 "Android (flat)"      phones and tablets               -> build\android\AudioSyncMaster.apk
#   tools\export_android.ps1 Quest -Release        release build (needs the release keystore in Editor Settings)
# Installs the Android build template into android\ on first use (the presets use Gradle builds).
# Needs: Godot 4.7.2 and its export templates, and the Android SDK, JDK and debug keystore set in Editor Settings.
# Install the APK with: adb install -r build\android\<name>.apk
param(
    [Parameter(Mandatory = $true)][string]$Preset,
    [switch]$Release
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$godot = @(
    $env:GODOT,
    "C:\Godot\Godot_v4.7.2-stable_win64_console.exe",
    "$env:USERPROFILE\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $godot) { throw "Godot 4.7.2 not found; set `$env:GODOT" }

# The APK path comes from the preset in export_presets.cfg.
$cfg = Get-Content (Join-Path $root "export_presets.cfg") -Raw
$m = [regex]::Match($cfg, "(?ms)^name=""$([regex]::Escape($Preset))""\s*$.*?^export_path=""([^""]+)""")
if (-not $m.Success) { throw "No export preset named '$Preset' in export_presets.cfg" }
$out = $m.Groups[1].Value
New-Item -ItemType Directory -Force (Join-Path $root (Split-Path $out -Parent)) | Out-Null

# Gradle's Java fails with "Unable to establish loopback connection" when the temp
# folder's path has a space in it (as in C:\Users\Shivoo Studios\...), so build with
# a short temp folder inside build\ (ignored by git).
$tmp = Join-Path $root "build\tmp"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:TEMP = $tmp; $env:TMP = $tmp
$env:JAVA_TOOL_OPTIONS = "-Djava.io.tmpdir=$tmp -Djdk.net.unixdomain.tmpdir=$tmp"

$apk = Join-Path $root $out
Remove-Item $apk -ErrorAction SilentlyContinue
$mode = if ($Release) { "--export-release" } else { "--export-debug" }
$template = if (Test-Path (Join-Path $root "android\build")) { "" } else { "--install-android-build-template " }
$log = Join-Path $tmp "export.log"; $err = Join-Path $tmp "export_err.log"
"Exporting '$Preset' -> $out"
$p = Start-Process $godot -ArgumentList "--headless --path `"$root`" $template$mode `"$Preset`" `"$out`"" `
    -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
$null = $p.Handle
# Godot sometimes doesn't exit after a headless export, so watch the log instead of waiting for it.
$deadline = (Get-Date).AddMinutes(15)
while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
    if ((Select-String -Path $log -Pattern "DONE.*export" -Quiet) -or (Select-String -Path $err -Pattern "export for preset .* failed" -Quiet)) {
        Start-Sleep 5; break
    }
    Start-Sleep 3
}
if (-not $p.HasExited) { $p.Kill() }
if (-not (Test-Path $apk)) {
    Get-Content $err | Select-String "What went wrong|ERROR: Export|failed" -Context 0, 2
    throw "Export failed; full logs in $log and $err"
}
Get-Item $apk | ForEach-Object { "{0}  {1:N1} MB" -f $_.FullName, ($_.Length / 1MB) }
