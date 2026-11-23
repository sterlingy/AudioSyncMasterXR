<#
Builds the size-optimized web export template that the "Web Image Tracking" preset
uses: about half the size of the standard one, with only what that scene needs.
The other presets keep the standard templates.

The template is copied to the addon's templates folder, where a project's preset
finds it as res://addons/shivoo_xr/templates, and is committed so exporting
doesn't need a Godot build setup.

Re-run after updating Godot, so the template matches the editor. Content that needs
something left out here (physics, navigation, audio files, runtime JPEG/SVG/glTF
loading, networking, regex, CSG, the advanced GUI controls such as RichTextLabel, or
shaping for scripts such as Arabic) needs its module or option turned back on.

    tools\build-web-template.ps1 [-Godot <Godot source folder>] [-Emsdk <emsdk folder>]
#>
param(
	[string]$Godot = $(if ($env:GODOT_SOURCE) { $env:GODOT_SOURCE } else { 'G:\Repos\godot' }),
	[string]$Emsdk = $(if ($env:EMSDK) { $env:EMSDK } else { "$env:USERPROFILE\emsdk" })
)
$ErrorActionPreference = 'Stop'
$templates = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates'
$template = 'godot.web.template_release.wasm32.nothreads.tracking.zip'

. (Join-Path $Emsdk 'emsdk_env.ps1') *> $null

$disabled = @(
	'basis_universal', 'bmp', 'camera', 'csg', 'dds', 'enet', 'fbx', 'gltf', 'godot_physics_2d',
	'godot_physics_3d', 'gridmap', 'hdr', 'interactive_music', 'jolt_physics', 'jpg', 'jsonrpc', 'ktx',
	'lightmapper_rd', 'mbedtls', 'mobile_vr', 'mp3', 'msdfgen', 'multiplayer', 'navigation_2d',
	'navigation_3d', 'noise', 'ogg', 'openxr', 'raycast', 'regex', 'svg', 'text_server_adv', 'tga',
	'theora', 'upnp', 'visual_shader', 'vorbis', 'webrtc', 'websocket', 'zip'
) | ForEach-Object { "module_${_}_enabled=no" }

$options = @(
	'platform=web', 'target=template_release', 'threads=no', 'production=yes',
	'optimize=size_extra', 'lto=full', 'extra_suffix=tracking',
	'module_text_server_fb_enabled=yes', 'minizip=no',
	'disable_physics_2d=yes', 'disable_physics_3d=yes',
	'disable_navigation_2d=yes', 'disable_navigation_3d=yes', 'disable_advanced_gui=yes',
	"-j$([Environment]::ProcessorCount)"
) + $disabled

Push-Location $Godot
try {
	scons @options
	if ($LASTEXITCODE -ne 0) { throw "scons failed with exit code $LASTEXITCODE" }
	New-Item -ItemType Directory -Force -Path $templates | Out-Null
	Copy-Item (Join-Path $Godot "bin\$template") $templates -Force
	Write-Host "Built $templates\$template"
} finally {
	Pop-Location
}
