# CLAUDE.md

This project is a multiplayer XR jam-session app built in Godot 4.7.2: remote musicians see each other's avatars and hear one another in sync, with spatial audio, built-in synth instruments, sequencers and loopers.

**Read `DESIGN.md` first.** It holds the architecture, platforms, instruments, latency targets, sync techniques, licensing constraints and the milestone plan.

## Key rules
- **The instruments live in SynthKit** (`D:\Godot_Projects\SynthKit`), the studio's shared synth addon: the C++ engine (`jamcore` GDExtension) and its source, instrument rig, sequencer, presets, clock, MIDI input and panels. Change them there, then `tools/sync_synthkit.ps1` (`-Build` to build the Windows engine first); never edit `addons/synthkit/` here. Keep SynthKit free of this app's code (sessions, looper, recording, XR, Settings): apps hook in through `InstrumentRig.looper_factory`, `rig.played`, `Midi.outgoing`/`dispatch_raw`. SynthKit is also used by MusicBeaconXR (on music-machine).
- Audio goes per person over UDP using **AOO** (BSD), compiled into SynthKit's engine (`JamAudioLink`). Do not mix audio on a server.
- Synth DSP lives in C++ in the engine, never per-sample GDScript. No allocation or locks on the audio thread.
- Avoid copying code from GPL projects (Jamulus, SonoBus, NINJAM, VCV Rack) unless the project decides to go GPL. JackTrip's MIT core is OK; check per-file licenses.
- No trademarked instrument names or look-alike panels.
- Latency is the top metric. Measure it and show it; don't add buffering without a reason.
- Virtual instruments send timestamped note events, not audio (audio mode is the fallback).
- Remote avatars are delayed to match each peer's audio latency.
- Git stays local: never add a remote or push.
- A Galaxy XR headset is available over wireless adb when the user has it on (ask them to wake it). Build and test on Windows first (flat mode, headless tests, `tests/tools/xr_panel_check.gd`); note headset-only follow-ups in `docs/TODO-headset.md`.

## Layout
- `addons/synthkit/` — the shared instruments, synced from SynthKit (engine binaries git-ignored here).
- `addons/` also: shivoo_xr (copied from ShivooXRPlugin, not a submodule: git stays local), godot-xr-tools, godotopenxrvendors, chordmaster_midi (Android MIDI plugin from ChordMasterXR), gut.
- `scenes/`, `scripts/` (app: sessions, looper, recording, XR, UI shell), `tests/` (GUT), `server/` (connection server), `assets/instruments/` (3D models).

## Building
- Godot: `C:\Users\sterl\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe` (not on PATH).
- Engine (in SynthKit, from a VS 2022 developer environment): `..\SynthKit\engine\tools\build_aoo.ps1` once, then `..\SynthKit\engine\tools\build.ps1` (`-Platform android`, `-Target release`). Then `tools/sync_synthkit.ps1` copies the addon here.
- XR build: export preset "Android XR" (feature `xr`, starts `scenes/xr_main.tscn`); the exporter hangs after DONE, so stop it once the APK is written, then `adb install -r -g`.
- Tests: `tools/run_tests.ps1` (GUT) and the two-process session test `godot --headless --path . -s res://tests/tools/net_test.gd`. Two machines: host with `-- --remote`, client with `-- --join=<host IP>` (second machine: music-machine over ZeroTier, see memory).

## Current milestone
M1-M5 done on Windows. Since then: tap tempo, click volume, host-approved tempo suggestions; interval mode (others heard exactly 1-2 bars later) with a high-latency hint; instrument audio mode; avatar pose sync delayed to each player's sound (`PoseBuffer`, `RemoteAvatar` placeholder); MIDI dialog (Bluetooth scan); M7 first pass (six Blender models in `assets/instruments`); touch/small-screen layout; M8 connection server with room codes and hole punching (`server/`). Two-machine tests run against music-machine over ZeroTier (`net_test.gd -- --remote` / `--join=`). Waiting on the user: where the connection server runs, real-sound-card buffer test. Next: M6 XR (needs the headset; see `docs/TODO-headset.md`), relay for strict NATs, M9.

## Network model (read before touching `scripts/net/`)
- Host = ENet server (port 47830 UDP), clock master, owner of tempo and the master looper. Clients' Transport is a `follower`: start/stop/tempo/meter become requests.
- Sound, sequencer and finished loops are mirrored as snapshots and played from the shared clock on every client; only live notes travel in real time (30-byte UDP packets stamped with shared-clock time, adaptive jitter delay).
- Clock pings use port 47831 and a receive thread (`ClockLink`); `Transport.clock_offset` = host clock minus ours.
- Audio: one AOO source per player, one sink per remote player (sink id = sender's player id), on an ephemeral UDP port in `JamAudioLink`. The same socket carries live notes; its network thread schedules them straight into the remote synth (`SynthCore::push_net`, a second SPSC queue).
- Audio loops: `JamAudioLink` records all input into a 64 s timestamped ring; loopers cut bars from it (`get_input_audio`) and play clips on an internal `Clips` instrument. Clips go to peers once (zstd), never streamed.
- Online: `Rendezvous` talks to `server/asm_server.py` (room codes, public addresses; JSON over UDP, `ASMR` registration packets from each socket). Players on different networks use each other's public audio address (`pub_audio`); HELLOs keep the holes open.
- Interval mode (`Session.interval_bars`, host decides): native notes play at stamp + interval - output latency; each voice goes through a delay line in `JamNetStreamPlayback` sized to land one interval after it was played.
- Jam recording: `SynthCore` logs events as they're applied and taps output; `JamStemRecorder` writes stems/mixdown while recording; `JamRecorder` (GDScript) writes MIDI and `session.json`.

## Timing model (read before touching scheduling)
- `JamSynth.get_time()` is a process-wide monotonic clock; every SynthCore locks its frame counter to it (DLL in `synth_core.h`), so `time_to_frame()` is consistent across all synths.
- `Transport` (autoload) maps time <-> beats and pumps clients (metronome, sequencers, later loopers) with a lookahead; clients schedule notes with `Transport.frame_for(synth, beat)`, which already subtracts output latency.
- Offline (tests, export): `synth.set_clock_anchor(t, 0)` then `render_offline()`.
