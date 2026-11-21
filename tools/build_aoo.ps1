# Builds AOO (BSD) and its bundled Opus (BSD) as static libraries for jamcore.
#   tools\build_aoo.ps1                     Windows x64
#   tools\build_aoo.ps1 -Platform android   arm64 (needs ANDROID_HOME with an NDK)
# Output: build\aoo-<platform>\install\{include,lib}. jamcore's SConstruct links it
# when present. AOO's own networking (client/server) is left out: the Session
# exchanges addresses and jamcore drives the sockets.
param([string]$Platform = "windows")
$ErrorActionPreference = "Continue" # cmake writes warnings to stderr; exit codes are checked
$root = Split-Path $PSScriptRoot -Parent
$src = "$root\thirdparty\aoo"
$out = "$root\build\aoo-$Platform"
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) {
    $cmake = Get-ChildItem "C:\Program Files\Microsoft Visual Studio\2022\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" | Select-Object -First 1 -ExpandProperty FullName
}
$common = @("-DAOO_NET=OFF", "-DAOO_USE_OPUS=ON", "-DAOO_LOCAL_OPUS=ON", "-DAOO_BUILD_SHARED_LIBRARY=OFF",
    "-DAOO_BUILD_EXAMPLES=OFF", "-DAOO_BUILD_TESTS=OFF", "-DAOO_BUILD_SERVER=OFF", "-DAOO_USE_IPV6=OFF",
    "-DAOO_INSTALL_PKG_CONFIG_MODULE=OFF", "-DAOO_INSTALL_CMAKE_CONFIG_MODULE=OFF", "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_PREFIX=$out\install")
if ($Platform -eq "android") {
    $ndk = Get-ChildItem "$env:ANDROID_HOME\ndk" | Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
    $ninja = Get-ChildItem "$env:ANDROID_HOME\cmake\*\bin\ninja.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty FullName
    $gen = @("-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=$ninja", "-DCMAKE_TOOLCHAIN_FILE=$ndk\build\cmake\android.toolchain.cmake",
        "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM=android-24", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
} else {
    # Static CRT (/MT) to match godot-cpp's default.
    $gen = @("-G", "Visual Studio 17 2022", "-A", "x64", "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded", "-DAOO_STATIC_RUNTIME=ON")
}
& $cmake -S $src -B $out @gen @common
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
& $cmake --build $out --config Release --target install -j $env:NUMBER_OF_PROCESSORS
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
Get-ChildItem "$out\install\lib" -Recurse | Select-Object FullName
