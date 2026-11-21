# Waiting for a headset

Work that needs the XReal Aura (or Galaxy XR / Quest) connected. Everything
else is built and tested on Windows first. Add to this list whenever a step
is skipped because no headset is available.

## When the Aura is connected
1. **Install the flat Android build** (`build/android/AudioSyncMaster.apk`, `adb install -r`), play each instrument from the on-screen keys, and read the **DSP %** in the top bar for every instrument with a full chord held. The Windows debug build uses 0.4–1.6 % of one core; the Aura's puck should stay under ~10 %.
2. **Measure Godot's audio output latency on Android** (`AudioServer.get_output_latency()` and a loopback/click test). If it's well above ~20 ms, start the native AAudio/Oboe output path (DESIGN.md, "Engine integration").
3. **USB MIDI on the puck**: plug in a keyboard (direct cable/OTG, not through a charger hub). The ChordMasterMidi Android plugin should list it automatically.
4. **Bluetooth LE MIDI**: pair a BLE MIDI keyboard, then trigger `Midi.scan_bluetooth()` (needs a settings screen button). Accept the Bluetooth permission prompt.
5. **Wi-Fi MIDI relay**: laptop sends (`net_send`), headset receives (on by default on Android). Ports 47820/47821 UDP.

## XR milestone (M6), needs the headset to verify
- XR scene with the Shivoo XR rig (`addons/shivoo_xr` submodule from `D:\Godot_Projects\ShivooXRPlugin`, plus godot-xr-tools 4.5.x and OpenXR Vendors 5.1.x copied from the template project).
- Panels in 3D: the flat panels rendered into SubViewports on movable XR panels, operated by fingertip/pinch (pattern from ChordMasterXR's XR controls).
- Passthrough by default; VR stage toggle; measure frame rate with six instruments visible.
- Hand-played instruments (drum pads you hit, a floating keyboard).
- Instruments play through `AudioStreamPlayer3D` at each player (`InstrumentRig.spatial = true`).

## Known gaps to check on device
- `res://presets/factory/**/*.json` must be in the Android export's include filter (it is in the preset created here; recheck after editing presets in the editor).
- The Android MIDI plugin's singleton is still named `ChordMasterMidi` (the AAR is reused unchanged). Rename only if rebuilding the plugin (`android_plugin/`).
