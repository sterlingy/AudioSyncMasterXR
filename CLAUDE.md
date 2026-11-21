# CLAUDE.md

This project is a multiplayer XR jam-session app built in Godot 4.7.2: remote musicians see each other's avatars and hear one another in sync, with spatial audio, built-in synth instruments, sequencers and loopers.

**Read `DESIGN.md` first.** It holds the architecture, platforms, instruments, latency targets, sync techniques, licensing constraints and the milestone plan.

## Key rules
- Audio goes per person over UDP using **AOO** (BSD), wrapped in the **`jamcore`** GDExtension (C++). Do not mix audio on a server.
- Synth DSP lives in C++ in `jamcore`, never per-sample GDScript. No allocation or locks on the audio thread.
- Avoid copying code from GPL projects (Jamulus, SonoBus, NINJAM, VCV Rack) unless the project decides to go GPL. JackTrip's MIT core is OK; check per-file licenses.
- No trademarked instrument names or look-alike panels.
- Latency is the top metric. Measure it and show it; don't add buffering without a reason.
- Virtual instruments send timestamped note events, not audio (audio mode is the fallback).
- Remote avatars are delayed to match each peer's audio latency.
- Git stays local: never add a remote or push.
- No headset is available yet: build and test on Windows desktop (flat mode, headless tests). If a step needs the headset or the user, skip it, note it in `docs/TODO-headset.md`, and move on.

## Layout
- `jamcore/` — GDExtension source (`src/`), SConstruct; builds to `addons/jamcore/bin/`.
- `thirdparty/` — godot-cpp, AOO, Oboe, DaisySP (clones, not edited).
- `addons/` — jamcore (built extension), shivoo_xr (submodule), godot-xr-tools, godotopenxrvendors, jam_midi (from ChordMasterXR), gut.
- `scenes/`, `scripts/`, `tests/` (GUT).

## Building
- Godot: `C:\Users\sterl\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe` (not on PATH).
- Extension: `scons -C jamcore platform=windows target=template_debug` from a VS 2022 developer environment (`tools/build.ps1` wraps it).

## Current milestone
M1: synth engine and the six instruments (Pulsar, Undertow, Comet, Lumen, Tangle, Driftwood) with full parameters, presets and flat panels.
