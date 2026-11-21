#!/usr/bin/env bash
# Recreates thirdparty/ (git-ignored).
set -e
cd "$(dirname "$0")/../thirdparty" 2>/dev/null || { mkdir -p "$(dirname "$0")/../thirdparty"; cd "$(dirname "$0")/../thirdparty"; }
[ -d godot-cpp ] || { git clone https://github.com/godotengine/godot-cpp.git godot-cpp; git -C godot-cpp checkout 7fd5c4b; }
[ -d aoo ] || git clone --depth 1 --branch v2.0-pre4 --recurse-submodules --shallow-submodules https://git.iem.at/aoo/aoo.git aoo
[ -d oboe ] || git clone --depth 1 https://github.com/google/oboe.git oboe
[ -d DaisySP ] || git clone --depth 1 https://github.com/electro-smith/DaisySP.git DaisySP
