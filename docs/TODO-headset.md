# Waiting for a headset

Work that needs the XReal Aura (or Galaxy XR / Quest) connected. Everything
else is built and tested on Windows first. Add to this list whenever a step
is skipped because no headset is available.

## When the Aura is connected
1. **Install the flat Android build** (`build/android/JamSyncXR.apk`, `adb install -r`), play each instrument from the on-screen keys, and read the **DSP %** in the top bar for every instrument with a full chord held. The Windows debug build uses 0.4–1.6 % of one core; the Aura's puck should stay under ~10 %.
2. **Measure Godot's audio output latency on Android** (`AudioServer.get_output_latency()` and a loopback/click test). If it's well above ~20 ms, start the native AAudio/Oboe output path (DESIGN.md, "Engine integration").
3. **USB MIDI on the puck**: plug in a keyboard (direct cable/OTG, not through a charger hub). The ChordMasterMidi Android plugin should list it automatically.
4. **Bluetooth LE MIDI**: pair a BLE MIDI keyboard, then press **MIDI… → Scan for Bluetooth MIDI**. Accept the Bluetooth permission prompt.
5. **Wi-Fi MIDI relay**: laptop sends (`net_send`), headset receives (on by default on Android). Ports 47820/47821 UDP.

## First runs of the XR builds (2026-11-26)
- **Quest**: `tools\export_android.ps1 Quest`, then `adb install -r -g build\android\JamSyncXR-Quest.apk`. Check that it starts in the headset (not as a flat window), hand tracking and passthrough work, and the permission prompts appear. It's a new package (`com.shivoostudios.jamsyncxr.quest`).
- **Aura**: `tools\export_android.ps1 "Android XR"`, then install `build\android\JamSyncXR-AndroidXR.apk`. The package is now `com.shivoostudios.jamsyncxr.xr`, so it installs next to an older `...audiosyncmaster.xr` build instead of replacing it; uninstall the old one.
- Both build and are signed on music-machine; neither has run on a device since the OpenXR Vendors 5.2.0 update.

## Play table (MusicInputKit) in the headset (2026-11-27)
- Turn right: is the play table at a good height and distance? Hit the chime bars, pluck the strings, play the orb and ribbon; check velocity and that held notes end.
- Hand tracking vs controllers: touching uses the XR rig's LeftHand/RightHand controller poses; check the touch point (the small orange dot) sits at your fingertips with hand tracking, and that pinch works as the trigger for playing from afar. Tune `PlayXRHands.tip_offset` if not.
- Front row: twist the Tone dial, slide Space, pull the Bend lever (springs back), XY pad, flick the flywheel, tilt the cube. Hear them on Prism, Lumen and Undertow.
- In a session: the other player hears play-table notes, bends and knob moves.

## Sizes in the headset (2026-11-27)
- Press **+** / **−** / **↺** beside the panel, the instrument and the play table, with a fingertip and with the laser. Check the buttons are easy to hit (they're 4.5 x 3.4 cm), the panel grows upward without covering the instrument, and keys still play with a light press at 50 % and 200 %.

## Networking on the headset (M4 leftovers)
6. **Audio link on Android**: AOO is built into the arm64 library (`tools/build_aoo.ps1 -Platform android`, then `tools/build.ps1 -Platform android`). Check that joining a session from the headset streams audio both ways.
7. **Mic on Android**: uses Godot's microphone (`AudioStreamMicrophone` on a muted bus + `AudioEffectCapture` -> `JamAudioLink.push_input`, `audio/driver/enable_input.android=true`). Untested on a device: check the permission prompt, then latency; if it's poor, add native AAudio/Oboe input to `jamcore/src/net/audio_capture.cpp`.
8. **Wi-Fi latency**: join a session from the headset to a wired PC; read ping, note delay and audio dropouts in the Jam tab. Try audio buffer 10-30 ms and Opus vs PCM.

## Needs real sound cards on two machines (with the user)
9. **Smallest safe audio buffer**: the ZeroTier sweep (`net_test.gd -- --remote --sweep` here, `-- --join=<host IP>` on music-machine) showed 0 dropouts at 5-20 ms for PCM and Opus over a 14 ms ping, but both ends ran headless on Godot's dummy audio driver. Repeat with the app open on both machines (real output devices, mic on) and lower the default buffer (15 ms) if 8-10 ms stays clean.

## Needs the user (online sessions, M8)
10. **Where the connection server runs**: `server/asm_server.py` (see `server/README.md`) needs a machine with a public address and UDP 47900 open (a small cloud VM is enough). Then test a real online session: host on one network, join by room code from another (a phone hotspot works as the second network). Strict NATs will need the relay (not built).

## XR milestone (M6), needs the headset to verify
- XR scene with the Shivoo XR rig (`addons/shivoo_xr` submodule from `D:\Godot_Projects\ShivooXRPlugin`, plus godot-xr-tools 4.5.2 and OpenXR Vendors 5.2.0).
- Panels in 3D: the flat panels rendered into SubViewports on movable XR panels, operated by fingertip/pinch (pattern from ChordMasterXR's XR controls).
- Passthrough by default; VR stage toggle; measure frame rate with seven instruments visible.
- Hand-played instruments (drum pads you hit, a floating keyboard).
- 3D instruments (M7 first pass): `assets/instruments/<Name>.glb` (source: `assets/instruments/source/instruments.blend`), loaded with `InstrumentModels.instantiate(type)`; `scenes/instrument_gallery.tscn` shows all seven. Check scale and readability in the headset and give pads/keys colliders for hand play.
- Instruments play through `AudioStreamPlayer3D` at each player (`InstrumentRig.spatial = true`).
- Avatars: the networking is done and tested (`Session.set_local_pose(head, left, right)` each frame from the XR rig; `Session.remote_pose(id)` gives each remote player's pose delayed to when their sound reaches you; `RemoteAvatar` is a placeholder head + hands). Hook the rig's camera/controllers to `set_local_pose`, spawn a `RemoteAvatar` per remote player, and check by eye that a remote strum lines up with its sound.

## Known gaps to check on device
- `res://presets/factory/**/*.json` must be in the Android export's include filter (it is in the preset created here; recheck after editing presets in the editor).
- The Android MIDI plugin's singleton is still named `ChordMasterMidi` (the AAR is reused unchanged). Rename only if rebuilding the plugin (`android_plugin/`).
