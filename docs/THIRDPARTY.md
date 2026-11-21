# Third-party code

Cloned into `thirdparty/` (git-ignored). Recreate with `tools/fetch_thirdparty.sh`.

| Library | Source | Version | License | Used for |
|---|---|---|---|---|
| godot-cpp | github.com/godotengine/godot-cpp | master @ 7fd5c4b (2026-11-19), built against Godot 4.7.2 API dump | MIT | GDExtension bindings |
| AOO | git.iem.at/aoo/aoo | v2.0-pre4 | BSD | Audio streaming (M4) |
| Opus | via AOO deps/opus | AOO submodule | BSD | Codec |
| Oboe | github.com/google/oboe | main (shallow) | Apache-2.0 | Android low-latency audio (M6) |
| DaisySP | github.com/electro-smith/DaisySP | master (shallow) | MIT (`Source/` only) | Reference only; not compiled (all DSP is our own) |

**Never compile `thirdparty/DaisySP/DaisySP-LGPL`** (LGPL: includes ReverbSc, Moog ladder variants and others). DaisySP is not compiled into jamcore at present; if it ever is, list `Source/` files explicitly in the SConstruct.

Reused from the studio's own ChordMasterXR: MIDI input autoload and Wi-Fi MIDI relay (`scripts/autoload/midi_input.gd`, `scripts/net/net_midi_*.gd`), and the Android MIDI plugin (USB + Bluetooth LE).
