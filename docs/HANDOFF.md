# Handoff: continuing JamSyncXR (formerly AudioSyncMaster) on music-machine

Written 2026-11-25 on Roogna (the main dev PC) so work can carry on from **music-machine**, which runs 24/7; updated 2026-11-26. Read this, then `CLAUDE.md` and `DESIGN.md`.

## Where everything is

| | GitHub | music-machine | Roogna |
|---|---|---|---|
| **AudioSyncMaster** (this project) | github.com/sterlingy/AudioSyncMasterXR (public, `main`) | `D:\AudioSyncMaster` | `D:\Godot_Projects\AudioSyncMaster` |
| **SynthKit** (shared instruments) | github.com/sterlingy/SynthKit (private, `main`) | `D:\SynthKit` (own clone) and the `addons\synthkit` submodule | `D:\Godot_Projects\SynthKit` and the submodule |
| **MusicInputKit** (playable 3D objects) | github.com/sterlingy/MusicInputKit (private, `main`) | `D:\MusicInputKit` (own clone) and the `addons\music_input_kit` submodule | submodule only |
| **MusicBeaconXR** (Beacon Field) | github.com/sterlingy/MusicBeaconXR (public; web on Pages) | `D:\MusicBeaconXR` | not cloned |
| **ChordMasterXR** | GitLab (shivoostudios, `origin`) + github.com/sterlingy/ChordMasterXR (`github`) | `D:\ChordMasterXR` | `D:\Godot_Projects\ChordMasterXR` |

On music-machine the SynthKit clone sits next to the projects (`D:\SynthKit`), so `..\SynthKit` works on both machines.

**Tools on music-machine**
- Godot 4.7.2: `C:\Godot\Godot_v4.7.2-stable_win64_console.exe`. The older copy is in `C:\ASM\godot`.
- Android SDK: `C:\Android\sdk`. adb is `C:\Android\sdk\platform-tools\adb.exe`, which is not on PATH.
- JDK 17: `C:\Android\jdk-17`.
- Blender 4.5: `C:\Program Files\Blender Foundation\Blender 4.5\blender.exe`.
- VS 2022 Community, Python and Node.
- Emscripten 7.0.1 (emsdk `latest`, installed 2026-11-25): `C:\emsdk`. Not on PATH; in each PowerShell run `& C:\emsdk\emsdk_env.ps1` first, then `em++`.
- Godot 4.7.2 export templates: installed in `%APPDATA%\Godot\export_templates\4.7.2.stable`.
- Android build template: installed in `D:\AudioSyncMaster\android` (git-ignored) on 2026-11-26. `tools\export_android.ps1` builds every Android preset; see README, "Building for Android and headsets".

**Missing on music-machine (2026-11-25)**
- **SCons** (`pip install scons`), needed for engine builds.
- **SynthKit's third-party clones** (`engine\thirdparty`, git-ignored; see SynthKit `docs/THIRDPARTY.md`). Only needed to rebuild the C++ engine; the committed binaries work without them.

## Start here (music-machine)
```powershell
cd D:\AudioSyncMaster
git pull
git submodule update --init
powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1
C:\Godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . -s res://tests/tools/net_test.gd
```
- music-machine's PowerShell blocks script files, so run scripts with `-ExecutionPolicy Bypass`.
- On a fresh checkout, import first (`Godot --headless --path . --import`) or the tests can't resolve class names.
- Expect **81/81** GUT tests and **PASS** from the session test.

## State of the project
- **Done on Windows:**
  - M1–M5;
  - tap tempo and tempo suggestions;
  - interval mode;
  - instrument audio mode;
  - avatar poses;
  - the MIDI dialog;
  - touch layout;
  - M8 connection server (`server/`).
- **XR (M6), first pass, runs on Galaxy XR.** Features:
  - passthrough;
  - the panel in 3D (fingertip poke and pinch laser);
  - grab bars;
  - wrist reset button and Recenter;
  - no teleport;
  - fingertip-played 3D instruments;
  - knobs: pinch, then move sideways, with name and value labels.
- **Instruments come from SynthKit**, a git submodule at `addons/synthkit`. It now has **seven** instruments: Prism (keys / lead / pad) was added in MusicBeaconXR. Prism has a 3D model here (`assets/instruments/Prism.glb`) and XR hand-play mapping.
- **Website material:**
  - user manual `docs/MANUAL.md`;
  - hero images `docs/images/hero_1920x1080*.{png,jpg}`, made by `assets/instruments/source/make_hero.py` (Blender, headless) and `add_title.py` (title and badge).

## Open work, in the order the user was heading
1. **SynthKit for every platform.** Mostly done 2026-11-25 (SynthKit `ba94c40`, pushed to GitHub `main`). See SynthKit's README, "Platforms".
   - The user's goal: one SynthKit holding every platform's version; each platform ships only its own build and gets each new feature it can run.
   - Done: `engine/core` (plain C++) + `engine/godot` + `engine/web`; `jam::Synth` shared by both adapters; `JamSynth.get_capabilities()` / `kit.capabilities` with the same keys; `web/` (synthkit.wasm, AudioWorklet, JS API, demo); `engine/tests/run_render_test.ps1` (Godot vs web, 16 cases, 66-128 dB SNR; the refactored Godot build is bit-exact with the old one).
   - Left: GitHub Actions building every platform on push; running the render test against the Android build (needs the headset or an emulator); moving `PresetLibrary.apply` into `jam::Synth`; mic input on the web.
   - AudioSyncMaster's `addons/synthkit` points at `a37098c` (SynthKit's Sampler instrument, 2026-11-26; 79/79 tests pass).
   - Sampler isn't offered here yet: it needs sample sets and a 3D model, so `scripts/main.gd` and `tests/test_avatar.gd` skip it like Metronome and Clips.
   - Emscripten is at `C:\emsdk` (see Tools); `engine\tools\build_web.ps1` builds the web module.
2. **AudioSyncMaster web / WebAR version**, solo:
   - instruments, sequencer, looper, presets;
   - AR with the instrument on a table.
   - Jamming stays in the installed apps, because browsers can't send its UDP audio.
   - Reuse Beacon Field's web pages (`MusicBeaconXR/web`: `synths.js`, `ar.html`, `src/ar/*`) on top of the web module from item 1.
   - Publish it on GitHub Pages, but **don't share or link the URL**: the user wants it live, not announced.
3. **MusicBeaconXR → SynthKit submodule.**
   - It still has a copied `addons/synthkit`, synced by script. Also move Beacon Field's browser instruments (`web/src/synths.js`, Web Audio rewrites of the original six, without Prism) into SynthKit.
   - Handed to a MusicBeaconXR session on 2026-11-25 with a brief (`D:\SterlingsLab\JamSyncXR\MusicBeaconXR-SynthKit-brief.md`): Godot onto the submodule first, then a proposal for the browser.
   - `D:\SynthKit`: local `master` tracks GitHub `main` and is at `a37098c`. Its 56 factory preset files show as changed, but only in line endings.
4. **Hero image**: done 2026-11-27. Re-rendered with all seven instruments (Prism added) and the JamSyncXR title. To redo it: `blender -b --python assets/instruments/source/make_hero.py -- final docs/images/hero_1920x1080.png` (about 3 minutes on the GPU), then `python assets/instruments/source/add_title.py`.
5. **Website session** (Sterling's Lab site): it asked for app info, which was sent. The app has no public build. The manual's GitHub URL exists, but the user hasn't said to give it to the site yet.

## Waiting on the user or the headset
- Feedback in the headset on the sideways knobs and labels, and installing the latest XR build, which has SynthKit and Prism. Ask the user to wake the headset. `tools\export_android.ps1 "Android XR"` (Galaxy XR, Aura) or `tools\export_android.ps1 Quest`, then `adb install -r -g`. See `docs/TODO-headset.md`, "First runs of the XR builds".
- Where the connection server runs (`server/asm_server.py`, UDP 47900). A relay for strict NATs isn't built.
- A buffer test with real sound cards on two machines. See `docs/TODO-headset.md`.

## MusicInputKit as a shared submodule (2026-11-27)
- MusicBeaconXR's `addons/music_input_kit` was split out with its history into github.com/sterlingy/MusicInputKit (private), cloned at `D:\MusicInputKit`. It's a submodule in both projects, like SynthKit.
- **Here:** added at `addons/music_input_kit` (tracks `main`; `tools/update_music_input_kit.ps1`). Not wired into the app: `hand_player.gd` still plays the 3D instruments. `tests/test_music_input_kit.gd` checks the kit loads and sends notes. Using it would mean a bridge from `MusicInput`'s `note_on`/`note_off`/`control` to `Midi.inject_*` and the rig's parameters, like MusicBeaconXR's `scripts/play/synth_bridge.gd`.
- **MusicBeaconXR:** done in a separate worktree, `D:\MusicBeaconXR-mik`, on branch `music-input-kit-submodule` (commit `b3479ee`, from `origin/main` `3be5fb4`), so the checkout at `D:\MusicBeaconXR` wasn't touched. Its Godot checks and 116 web tests pass. After it reaches `main`, `D:\MusicBeaconXR` needs `git submodule update --init` (its `addons\music_input_kit` folder becomes the submodule).
- MusicBeaconXR pins SynthKit `5e78138` ("Windows release build with the Sampler"), newer than this project's `a37098c`.

## Renamed to JamSyncXR (2026-11-27)
- The app, window title, Android labels, exe and APK names, UI text, manual and server messages say JamSyncXR. The repo (`AudioSyncMasterXR`), the folders and the `server/asm_server.py` filename are unchanged.
- **Desktop data:** Godot names the user folder after the project, so it moved from `%APPDATA%\Godot\app_userdata\AudioSyncMaster` to `...\JamSyncXR`. `scripts/autoload/user_data_move.gd` copies the old folder over once, on the first start (Settings calls it before loading). The old folder stays as a backup. Done on music-machine (37 files); Roogna's copy happens the first time it runs the new version.
- **Saved jams:** new `session.json` files say `"app": "JamSyncXR"`; files saying `"AudioSyncMaster"` still load (`JamRecorder.APP_NAMES`).
- **APKs:** `build/android/JamSyncXR.apk` (flat), `JamSyncXR-AndroidXR.apk`, `JamSyncXR-Quest.apk`.
- **App icon:** `assets/icon/` (SVG sources; `tools/make_icon.gd` renders the PNGs and `icon.ico`). It's set as the project icon, the Android launcher and adaptive icons, and the Windows exe icon.
- Hero image re-rendered with seven players and the new title. Pillow 13.0.0 is now installed on music-machine (`pip install --user pillow`).

## XR and Android builds (2026-11-26)
- **Addons:** OpenXR Vendors 5.2.0 and godot-xr-tools 4.5.2 (the latest releases). XR Tools 4.5.2's code was already here; `player_body.gd` keeps this project's fixes, which upstream lacks.
- **Android binaries are committed:** `.gitignore` had `android/`, which also hid `addons/godotopenxrvendors/.bin/android/`, so a fresh clone couldn't export for a headset. It's now `/android/`.
- **Package IDs** are `com.shivoostudios.jamsyncxr` (flat), `.xr` (Android XR) and `.quest` (Quest). They were `com.shivoostudios.audiosyncmaster...`; headsets treat the new ones as new apps.
- **Quest preset:** the Meta loader in place of Android XR's, with the same project and scene, since everything is OpenXR. No Meta/Quest SDK is needed. One APK per headset family, because each expects its own manifest.
- **Built on music-machine:** debug APKs for Quest and Android XR, signed, with the expected manifests. Neither has run on a device yet.
- **Known:** Godot exits with 0xC0000005 after the GUT run (the tests pass first), with both the old and new addons.

## Two-machine tests
- **Addresses (ZeroTier):** music-machine is 10.241.70.124 and Roogna is 10.241.111.150.
- **Commands:** host with `net_test.gd -- --remote`; client with `-- --join=<host IP>`. Either machine can host; Roogna has to be on.
- **Clock gap:** the two machines' Windows clocks differ by about 720 ms, so wall-clock checks don't work between them.

## Working with this user
- If something needs the user (a headset, a sign-in, a download), ask right away so the work isn't held up later.
- Commit as work lands. **Push only when the user asks.**
- Keep the user's email private.
- Don't copy GPL code (Jamulus, SonoBus, NINJAM, VCV Rack). Never compile DaisySP-LGPL.
- No trademarked instrument names or look-alike panels.
