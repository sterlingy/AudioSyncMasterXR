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
- AOO + Opus (once, or after updating `thirdparty/aoo`): `tools/build_aoo.ps1` (CMake from VS 2022) → `build/aoo-windows/`. Without it jamcore builds without `JamAudioLink`.
- Extension: `scons -C jamcore platform=windows target=template_debug` from a VS 2022 developer environment (`tools/build.ps1` wraps it).
- Tests: `tools/run_tests.ps1` (GUT) and the two-process session test `godot --headless --path . -s res://tests/tools/net_test.gd`.

## Current milestone
M1 (synths, presets, panels, MIDI), M2 (clock, metronome, sequencers, quantize), M3 (loopers) done. M4 (LAN sessions) done on Windows: `Session` autoload (ENet state, P2P UDP live notes, threaded clock sync), `JamAudioLink` (AOO audio per player, WASAPI capture). M4 leftovers: live-note receive on a native thread, audio loops for real instruments, WASAPI exclusive mode; Android capture waits for the headset. Next: M5 jam export.

## Network model (read before touching `scripts/net/`)
- Host = ENet server (port 47830 UDP), clock master, owner of tempo and the master looper. Clients' Transport is a `follower`: start/stop/tempo/meter become requests.
- Sound, sequencer and finished loops are mirrored as snapshots and played from the shared clock on every client; only live notes travel in real time (30-byte UDP packets stamped with shared-clock time, adaptive jitter delay).
- Clock pings use port 47831 and a receive thread (`ClockLink`); `Transport.clock_offset` = host clock minus ours.
- Audio: one AOO source per player, one sink per remote player (sink id = sender's player id), on an ephemeral UDP port in `JamAudioLink`.

## Timing model (read before touching scheduling)
- `JamSynth.get_time()` is a process-wide monotonic clock; every SynthCore locks its frame counter to it (DLL in `synth_core.h`), so `time_to_frame()` is consistent across all synths.
- `Transport` (autoload) maps time <-> beats and pumps clients (metronome, sequencers, later loopers) with a lookahead; clients schedule notes with `Transport.frame_for(synth, beat)`, which already subtracts output latency.
- Offline (tests, export): `synth.set_clock_anchor(t, 0)` then `render_offline()`.
