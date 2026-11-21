# XR Jam Session — Design

## Goal
A multiplayer XR app where musicians in different locations jam together live. Each participant sees the others as avatars and hears everyone in sync, with spatial audio placed at each avatar. Players play real instruments (mic or audio interface) or the app's built-in virtual instruments, with per-player sequencers and loopers, a shared master looper and a universal metronome.

## Platforms
| Platform | Mode | When |
|---|---|---|
| **Windows desktop** | Flat (2D panels, mouse/keyboard/MIDI) | First: everything is built and tested here |
| **Windows + OpenXR** (PC VR) | XR | With the XR milestone |
| **Android XR**: XReal Aura, Samsung Galaxy XR | XR, passthrough | Main headset target |
| **Meta Quest** | XR, passthrough | Same OpenXR path through the vendors plugin |
| **Android phone/tablet** | Flat, no AR | Later: recording and playing live with others |

Web is out: browsers can't do the UDP audio AOO needs.

Engine: **Godot 4.7.2**, GL Compatibility renderer (mobile GPUs). XR rig, hand tracking, passthrough and QR codes come from the studio's **Shivoo XR** addon (`addons/shivoo_xr`, submodule). MIDI (USB on desktop; USB + Bluetooth LE on Android, Wi-Fi relay) is adapted from ChordMasterXR.

## The core constraint: latency
Latency can't be eliminated, only kept under the threshold musicians notice, or designed around.
- Fiber carries signals at roughly 200 km/ms, and real internet routes are longer than a straight line.
- **Target: about 25–30 ms one-way, mouth/instrument to ear.** That feels like standing 8–10 m apart on a stage, which musicians handle naturally.
- Above about 50 ms, tight rhythmic playing breaks down.
- Real-time play is realistic within about 1,000 km (one region or coast). Intercontinental sessions need a fallback mode (see "Jam modes").

## Architecture: two channels

### 1. Audio channel: fast, UDP, per-person streams
- Library: **AOO (Audio over OSC)**, a C/C++ library with a simple C API, BSD-licensed, designed for embedding. Codecs: raw PCM or Opus.
  - Official repo: https://git.iem.at/aoo/aoo (GitHub mirror: Spacechild1/aoo)
- **Send each person's audio as its own stream; do not mix on a server.** Each listener needs every voice separately so it can spatialize it at that person's avatar.
- Topology: up to 6 players, **P2P mesh** (everyone sends to everyone). A forwarding server (SFU) that relays without mixing comes later for bigger groups.
- Streams carry **voice and real instruments**, and a virtual instrument's output only when that instrument is switched to audio mode (see "Virtual instruments: notes or audio").

### 2. State channel: avatars, gestures, notes, session data
- Godot's built-in multiplayer (ENet, or WebRTC for NAT traversal).
- Carries avatar poses, hand tracking, note and parameter events, sequencer and looper data, presets, session/room info.
- More tolerant of delay than audio, except note events, which go unreliable-ordered with timestamps.

## Sync techniques
1. **Delay each avatar to match its audio.** Buffer each remote avatar's pose by that peer's measured audio latency, so strums, hits and lip movement line up with the sound.
2. **Send notes, not audio, for virtual instruments.** Timestamped note and controller events (a few bytes each), synthesized locally on every client.
3. **Shared musical clock.** One client (the host) is clock master; the rest sync to it by NTP-style ping exchange (≈1 ms on a LAN). Metronome, sequencers and loopers are scheduled against it and rendered locally, sample-accurately, compensating for each device's output latency, so they are in sync for everyone. Only live-played parts carry network delay.
4. **Spatial audio.** Each player's sound plays through an `AudioStreamPlayer3D` at their avatar or instrument.
5. **Latency display.** Per-peer latency is shown in the app; above about 40 ms the app suggests interval mode.

## Universal metronome and tempo
- The host sets tempo and time signature. Anyone can tap or suggest a tempo; the host approves.
- A tempo change is scheduled for the next bar line, so every client switches on the same beat.
- The click is synthesized on each client's audio thread at clock time + output-latency compensation. Count-in, accent on beat 1, per-player click volume and mute.

## Jam modes
- **Live mode** (latency under about 30–40 ms): real-time play as described above.
- **Interval mode** (high latency or intercontinental): NINJAM-style. Remote parts are delayed by exactly one bar (or N bars) against the shared clock, so they arrive late but perfectly in time.

## Virtual instruments
Six instruments, all synthesized in C++ inside the GDExtension (`jamcore`). Each is a custom `AudioStream` (MetaSounds-style: native oscillators, filters, envelopes, effects) with its parameters exposed to Godot and the panels. Names are our own; designs are "inspired by" classic hardware, never using trademarks or trade dress.

| Name | Role | Design |
|---|---|---|
| **Pulsar** | Drums / beat maker | Synthesized kick, snare, clap, closed/open hat, tom, cymbal. Per voice: tune, decay, tone, snap/noise, level, pan. Master drive and compressor |
| **Undertow** | Bass | Model D-style: 3 VCOs (range 32'–2', tri/saw/square/pulse shapes, osc 2–3 detune, osc 3 as LFO), mixer with noise and external in, 24 dB/oct ladder filter (cutoff, emphasis that self-oscillates, contour amount, key tracking), filter and loudness contours (attack, decay, sustain, release switch), glide, mod wheel, pitch bend. Mono, last-note priority |
| **Comet** | Lead | 2 VCOs with hard sync and detune, sub, multimode filter + envelope, amp envelope, vibrato LFO with delay, portamento, drive, tempo-synced ping-pong delay. Mono/legato |
| **Lumen** | Keys | 8-voice polyphonic, 2 VCOs per voice + noise, filter with envelope, amp envelope, velocity response, stereo spread, chorus, reverb. Pads, e-piano-ish and stab sounds |
| **Tangle** | Modular | Patchable modules connected by cables (below) |
| **Driftwood** | Plucks / mallets | Physical modeling: Karplus-Strong plucked string, modal mallet (marimba, kalimba, bells). Exciter, damping, brightness, body/material, decay, reverb |

DSP rules: band-limited oscillators (PolyBLEP), nonlinear ladder filter model, parameter smoothing (no zipper noise), denormal protection, no allocation on the audio thread. Our own code or permissive libraries (DaisySP, MIT, checked per file).

### Tangle modules
| # | Module | Function |
|---|---|---|
| 1 | MIDI→CV | Pitch (1 V/oct), gate, velocity, mod wheel, aftertouch from the player's input |
| 2 | Clock | Shared session clock; divide/multiply, swing, reset |
| 3 | VCO | Sine, triangle, saw, pulse; PWM, FM in, hard sync |
| 4 | Noise / S&H | White and pink noise; sample & hold |
| 5 | VCF | LP/BP/HP, resonance, cutoff CV |
| 6 | VCA | Dual, linear/exponential |
| 7 | ADSR | Envelope with gate and retrigger |
| 8 | LFO | Multiple shapes, clock sync |
| 9 | Step Sequencer | 8/16 steps of pitch and gate, built-in scale quantizer |
| 10 | Utility | Mixer, mults, attenuverters, offset, slew |
| 11 | Delay | Tempo-synced, feedback, tone |
| 12 | Reverb + Output | Reverb, then out to the 3D audio source |

Signals run at audio rate between modules. A patch is a graph of module instances and cables, saved and shared like any preset.

### Virtual instruments: notes or audio
- **Default: note events.** Lowest latency, tiny bandwidth, sound is identical on every client (patches and parameter changes are synced as events).
- **Fallback: audio.** Any instrument can switch to streaming its rendered output through the same AOO stream used for real instruments, for devices that can't render every player's instruments.
- Each client renders every remote instrument from notes, whether or not that instrument is visible.
- To start, **one instrument per player**. Duplicates are allowed (two players can both play Undertow, each with their own patch).

### Real instruments
Mic or audio interface, captured natively (WASAPI on Windows; AAudio/Oboe on Android), streamed per person over AOO. Players monitor themselves directly.

## Playing input
- **MIDI**: USB on Windows; USB and Bluetooth LE MIDI on Android (ChordMasterXR's Android plugin); Wi-Fi MIDI relay from a laptop to a headset. MIDI learn for knobs; pitch bend, mod wheel, sustain.
- **Computer keyboard** and on-screen keys/pads in flat mode; hands and controllers in XR.

## Quantize
- Toggle plus a grid value: 1/1, 1/2, 1/4, 1/8, 1/16, 1/32, with triplet variants.
- **Always applies to what gets recorded** into loopers and sequencers, without delaying what you hear.
- **Live quantize** is a separate toggle, off by default: it delays each live note to the next grid point.

## Sequencers
Every player has a sequencer for their instrument, running on the shared clock.
- **Pulsar**: step grid, one row per drum voice, per-step velocity, up to 64 steps.
- **Undertow / Comet / Lumen / Driftwood**: steps with note (chords for Lumen), velocity, gate length, slide and accent; up to 64 steps.
- **Tangle**: its Step Sequencer module, plus the same note sequencer driving MIDI→CV.

## Loopers
### Personal looper
- Virtual instruments record **note and parameter events** (editable, re-quantizable). Real instruments record **audio**.
- Length is set in bars; record/stop happen on bar lines of the shared clock.
- Record, overdub, undo last layer, clear, mute; several loop slots per player.

### Master looper
- Every player can contribute: record straight into it, or push a personal loop to it.
- Anyone can mute any layer for themselves; only the layer's owner or the host can delete it.
- Players joining mid-session receive its current contents.
- Recorded remote audio is time-aligned using the stream timestamps and the shared clock.

### Listening
Per headset: **master + everyone live**, **own loops + everyone live**, or **own loops only**. Plus per-player volume and mute.

## Presets and sharing
- 8 factory presets per instrument; save your own.
- Share a preset by **QR code** (compressed patch; a synth patch is a few hundred bytes, a large Tangle patch fits in one code) or a copyable text code. Headsets read QR codes through Shivoo XR marker tracking.

## Saving a jam
Export a session: **WAV stems** per player, a stereo **mixdown**, **MIDI** of all note events, and the session file (tempo, patches, loops) to reload.

## Space and look
- **Passthrough** by default: other players appear as avatars in your real room, each with their instrument.
- **VR stage toggle**: everyone appears at their instruments on a shared virtual stage. Audio cost is the same either way (instruments render from notes regardless); the cost is drawing up to 6 instruments and avatars, so measure frame rate on the headset.
- **Flat panels first**, then **stylized 3D models** of each instrument made in Blender: clear silhouettes, a color identity per instrument, mid-poly with baked detail for mobile GPUs.

## Engine integration (Godot)
- GDExtension `jamcore` (C++, godot-cpp, SCons) holds: the synth engine and instruments, the clock, AOO streaming, native audio capture/playback.
- Playback: instrument or decoded stream → custom `AudioStream` → `AudioStreamPlayer3D` on each avatar.
- Capture: native (WASAPI / AAudio-Oboe); `AudioEffectCapture` only as a fallback.
- If Godot's output buffering (`audio/driver/output_latency`) is too high, move playback native too and let Godot handle only positioning.

## Hardware constraints
- **Standalone headsets (Aura, Galaxy XR, Quest):** Wi-Fi only. The Android audio path adds about 20–40 ms by itself. Requirements: Wi-Fi 6, 5 GHz, router in the same room, the low-latency AAudio path. **No Bluetooth audio** (Bluetooth MIDI is fine).
- **PC on wired Ethernet:** the best case.
- Real instruments need an audio interface; buffers 64–128 samples where the platform allows.

## Licensing notes
I'm not a lawyer: check each file you include before shipping.
- **AOO**: BSD. **Opus**: BSD. **Oboe**: Apache-2.0. **godot-cpp**: MIT. **DaisySP**: MIT (check per file).
- **JackTrip**: core MIT, GUI and some DSP GPL/LGPL; check file by file.
- **Jamulus** (GPL-2.0+), **SonoBus** (GPL-3.0), **NINJAM** (GPL), **VCV Rack** (GPL-3.0): reference or study only.
- **WebRTC**: BSD; fine for the state channel or video, not tight audio.
- No trademarked instrument names or look-alike panels (Moog, Minimoog, etc.).

## Milestones
Built on Windows desktop first; headset steps run once a headset is connected. Blocked steps are skipped and noted, not waited on.
1. **M1: Synth engine + instruments.** `jamcore` GDExtension; all six instruments with full parameters, 8 presets each, flat panels, computer-keyboard and MIDI play. Headless audio tests.
2. **M2: Clock, metronome, sequencers, quantize.** Shared clock (local first), metronome, per-instrument sequencers.
3. **M3: Loopers.** Personal and master loopers (local first), listening modes.
4. **M4: Networking on LAN.** State channel, note/param events, clock sync, AOO audio for mic/interface and audio-mode instruments, latency display, per-player volume/mute, master looper sync.
5. **M5: Presets sharing + jam export.** QR/text codes, WAV stems, mixdown, MIDI, session files.
6. **M6: XR.** Shivoo XR rig, passthrough, avatars delayed to audio latency, VR stage toggle, hand-played instruments; Aura / Galaxy XR / Quest; native AAudio/Oboe path; Bluetooth MIDI on headset.
7. **M7: Stylized 3D instruments** (Blender).
8. **M8: Internet.** NAT traversal / connection server, region tests.
9. **M9: Interval mode, Android flat app, SFU for larger groups.**

## Decisions log
- 2026-11-21 (M5): Live notes scheduled on the audio link's network thread straight into the synth (second SPSC queue). Audio loops recorded from a timestamped input ring and played as clips from the clock; clips sent once per player. Jam export records what's heard on one machine (event log at apply time + output taps), starting on a bar line; stems as 32-bit float WAV. QR encoder is our own.
- 2026-11-21 (M4): Live notes go peer to peer over UDP (not through the host) with shared-clock stamps and a per-sender jitter delay; sequencers and loops are mirrored and played from the clock, never streamed. Clock pings on their own port and thread. AOO built without its NET layer (the Session exchanges addresses). Default audio format PCM 16-bit on LAN, Opus selectable. A player's own input isn't played back (direct monitoring).
- 2026-11-21: Instruments first; six instruments (two added for 6 players); one instrument per player for now; host controls tempo; record-time quantize always, live quantize optional; notes by default with audio fallback; passthrough + VR stage toggle; stylized 3D after flat panels; git stays local.

## Open questions
- Avatar style for remote players in passthrough.
- Session size beyond 6.
- Video of performers or a spectator stream.
