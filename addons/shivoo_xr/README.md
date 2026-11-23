# Shivoo XR

Shared XR code for Shivoo Studios projects: the player rig, passthrough, hand
tracking, stereo WebXR, web image and surface tracking, the Steam Frame launcher
export patch and the size-optimized web export template.

Consumed as a git submodule at `addons/shivoo_xr`.

## What's in here

|Folder|Contents|
|---|---|
|`scripts/`|`ImageTarget`, `ImageTracking`, `SurfaceTracking`, `SurfacePlacement`, `SurfaceTouch`, `TrackingHud`, `HandTracking`, `HandSkeleton`, `Passthrough`, `FlatPlay`, `SpawnOnHead`, `WebXRActions`, `WebXR Stereo`, `ShivooDOMOverlay` (scripts only; add them to your own nodes)|
|`player/player.tscn`|The `XROrigin3D` rig: camera, hands with XR Tools pickup/teleport/movement, hand tracking, flat (desktop) play|
|`web/*.js`|The page-side halves of the web nodes, loaded by path at runtime, including `dom_overlay.js`|
|`launcher/`|Export plugin: makes Android exports with the Khronos vendor plugin (Steam Frame) launchable by Lepton|
|`export/web_assets_export_plugin.gd`|Puts `web/*.js` into web exports, so presets don't have to list them|
|`templates/`|Size-optimized web export template used by the image tracking preset|
|`tools/mindar/`|MindAR's image target compiler, run with Node.js by `ImageTarget`|
|`tools/build-web-template.ps1`|Rebuilds `templates/` after a Godot upgrade|

Per-project things stay in the project: `project.godot`, `export_presets.cfg`,
`openxr_action_map.tres`, your scenes, your `web/targets/` images and their
compiled `.mind` files.

## Requirements

Godot 4.7 (developed against 4.7.2).

A `plugin.cfg` can't declare dependencies, so install these yourself, with a
compatible version:

- [godot-xr-tools](https://github.com/GodotVR/godot-xr-tools) 4.5.x — `XRToolsStartXR`,
  the hands, pickup, teleport and movement nodes the player rig uses. Enable its
  plugin and its autoloads `XRToolsUserSettings` and `XRToolsRumbleManager`.
- [Godot OpenXR Vendors](https://github.com/GodotVR/godot_openxr_vendors) 5.1.x —
  the Android XR, Meta, Pico, Khronos and Magic Leap loaders the export presets use.

Installing them as plugins in the project (rather than bundling them) keeps them
upgradeable on their own schedule, and stops two copies of the same classes.

Node.js is needed only for the editor, by `ImageTarget`, to compile `.mind` files.
Its packages install themselves on the first compile (`npm ci` in
`addons/shivoo_xr/tools/mindar`); `node_modules/` is not committed.

## Install

```sh
git lfs install                       # the template zip is LFS-tracked
git submodule add https://gitlab.shivoostudios.com/shivoo-core/godot/shivooxrplugin.git addons/shivoo_xr
```

Then enable **Shivoo XR** in Project Settings > Plugins. Cloning a project that
already uses it: `git clone --recurse-submodules`, and `git lfs pull`.

In CI, set `GIT_SUBMODULE_STRATEGY: recursive` and run `git lfs pull`.

## Project settings the addon expects

Copy these from the template project's `project.godot`:

- `[xr]`: `openxr/enabled=true`, the `openxr/*` foveation and extension options,
  and `shaders/enabled=true`.
- `physics/common/physics_ticks_per_second=90` and
  `physics/3d/physics_engine="Jolt Physics"`.
- `[layer_names]` `3d_physics/layer_1..5, 17..23`, which XR Tools uses.
- `rendering/vrs/mode=2` for foveated rendering on headsets.
- Input actions `move_forward`, `move_back`, `move_left`, `move_right` for flat play.
- Copy `openxr_action_map.tres` from the template and keep it as the project's
  action map.

Web image tracking also needs the per-scene overrides the template sets:
`window/size/transparent.image_tracking`, `viewport/transparent_background.image_tracking`
and `anti_aliasing/quality/msaa_3d.image_tracking=0`.

### Export presets

- Web image tracking: set `custom_template/release` to
  `res://addons/shivoo_xr/templates/godot.web.template_release.wasm32.nothreads.tracking.zip`,
  and keep `*.mind` in `include_filter` so your compiled targets ship. Don't add
  `web/*.js`: the addon's export plugin adds them.
- `ShivooDOMOverlay` HTML/CSS files are read with `FileAccess`, so keep them in
  the export preset's `include_filter` too.
- Capture (a project's camera button, `capture.js`) composes the canvas at the end
  of Godot's frame, from the hook the addon's web template calls
  (`ShivooEngine.onFrameEnd`). It needs a template built with that hook: the ones
  in `templates/` are.
- The templates keep the PNG and WebP decoders, which a texture imported as
  Lossless needs at runtime, and leave out JPEG, SVG and the rest to stay small. A
  texture that can't be decoded logs `Failed loading resource` and arrives as
  `null`, so a scene that needs one of the other formats needs its module turned
  back on in `build-web-template.ps1`.
- Steam Frame: enable `xr_features/enable_khronos_plugin`; the launcher export
  plugin then patches the manifest so Lepton can start the app.

## Using it

Add the player rig to a scene: instance `res://addons/shivoo_xr/player/player.tscn`.

Attach these to nodes of your own, or instance `player/player.tscn` for the rig.
Those with a `class_name` are global, so they show up in Add Node:

|Script|Node it goes on|Notes|
|---|---|---|
|`image_tracking.gd` (`ImageTracking`)|`Node3D`|Parent of your `ImageTarget` nodes. Web needs `camera`, `start_button`, `status_label`, and `xr_origin`/`xr_camera` for world tracking. Native needs `xr_origin`, `status_label`, and an XR session started by the scene's player rig. `target_posed` fires for each fresh tracked pose|
|`image_target.gd` (`ImageTarget`)|`Node3D`|One per image; children are placed on the image. Native: set `marker_payload` (QR text) or `marker_id` (ArUco/AprilTag), and `width` to the printed size. For a sheet with the QR inside the artwork, `marker_width`/`marker_offset` say where the QR is; Generate Sheet draws it|
|`qr_code.gd` (`ShivooQR`)|—|QR encoder used by Generate Sheet|
|`site_lock.gd` (`SiteLock`)|`Node3D`|Shared-space mode: during XR, locomotion is off and the XR origin is moved so the tracked `marker` lands on this node. Needs `start_xr`, `image_tracking`, `marker`, `origin`|
|`site_root.gd` (`SiteRoot`), `site_anchor.gd` (`SiteAnchor`)|`Node3D`|Anchors in a marker's frame, built from a registry|
|`surface_tracking.gd` (`SurfaceTracking`)|`Node3D`|Needs `xr_origin`, `xr_camera`, `start_button`, `status_label`|
|`surface_placement.gd` (`SurfacePlacement`)|`Node3D`|Its children preview see-through at the middle of the screen and the place button puts them there. One finger drags, two turn and size, three dragged left or right turn `key_light`; meshes in its `no_preview` group keep their own material|
|`shadow_catcher.gd` (`ShadowCatcher`)|`MeshInstance3D`|A square under placed content that darkens only where that content shadows it, and is see-through otherwise. `CONTACT` draws a soft patch, `DYNAMIC` projects what is on `casters_layer` from a light; keep the patch off that layer. Needs no engine shadow support|
|`surface_touch.gd` (`SurfaceTouch`)|—|Value type for the touch signals|
|`tracking_hud.gd` (`TrackingHud`)|`CanvasLayer`|What a tracking node drives: place/reset, permission notice, capture availability with `set_capture_available()`, `set_capture_in_xr()` plus the `review_closed` signal for a capture taken in a session, and `capture_open()` so a scene drops its own touch gestures while the camera has the screen. Extend it in the project|
|`passthrough.gd`|`Node`|Usable on phones and headsets|
|`dom_overlay.gd` (`ShivooDOMOverlay`)|`Node`|Project HTML/CSS over the page, and inside Chrome Android immersive-ar through the WebXR DOM Overlays API. One per page|
|`webxr_stereo.gd`|`Node`|Needs `start_xr` and `origin`|
|`webxr_actions.gd`|`Node`|In `player.tscn`|
|`hand_tracking.gd`|`Node`|In `player.tscn`|
|`hand_skeleton.gd` (`HandSkeleton`)|`SkeletonModifier3D`|In `player.tscn`|
|`spawn_on_head.gd`|`Node`|In `player.tscn`|
|`flat_play.gd`|`XRToolsMovementProvider`|In `player.tscn`; WASD + mouse when no headset|

Each script's header says what its exported properties are for.

### Native marker tracking

`ImageTracking` uses MindAR on the web and the OpenXR spatial marker extension on
native headsets. The same `ImageTarget` nodes work in both: an image and its
compiled `.mind` for the web, plus a native `marker_payload` (QR text) or
`marker_id` (ArUco/AprilTag). The marker pose is placed with the same
+Y-out/-Z-up convention as the web targets, scaled to the runtime's reported
marker size.

Native support is runtime-dependent:

- **Quest 3 / Horizon OS v83+**: QR codes. QR tracking needs spatial data
  permission; the export plugin adds `USE_SCENE` and `USE_ANCHOR_API` when
  spatial entities are enabled, and the node asks for `USE_SCENE` at runtime.
- **Android XR**: QR codes through `XR_EXT_spatial_marker_tracking`. The node
  asks for `android.permission.SCENE_UNDERSTANDING_COARSE` at runtime.
- **Steam Frame / PCVR**: no marker tracking in the current OpenXR path; use a
  manual or three-point alignment instead.

Enable the OpenXR spatial entity settings in the project:

```ini
[xr]
openxr/extensions/spatial_entity/enabled=true
openxr/extensions/spatial_entity/enable_marker_tracking=true
openxr/extensions/spatial_entity/enable_builtin_marker_tracking=true
```

Native scenes also need an `XROrigin3D` and an XR session started by their player
rig (`XRToolsStartXR`); `image_tracking.tscn` starts XR through the browser's
Start button and is web-only. Keep `persist_in_world` on when a marker establishes
a site: the target keeps its last pose after the runtime pauses the marker, so
content placed around it stays put.

The template project's `scenes/main.tscn` uses this: its `SiteMarker` follows a
QR whose payload is `shivoo-site:demo-a`. Its log lines are
`ImageTracking: markers QR=...` when the session starts and
`ImageTracking: marker ... -> SiteMarker` / `ImageTracking: ... at ...` when
the QR is found. Set `follow_session` on the web so `ImageTracking` tracks the
camera of the AR session the player rig starts.

### Site sheets: one print for web and native

A QR alone is a poor MindAR image: its repeating modules give MindAR almost
nothing to follow (0 and 20 tracking features, where 20+ is good). A site sheet
puts the QR in a white window in the middle of detailed artwork. MindAR tracks
the whole sheet; headsets read the QR. Both use the one `ImageTarget`, whose
origin is the sheet's centre, so they agree by construction:

- `width` is the sheet's printed width, `marker_width` the QR code's own width
  (no quiet zone), and `marker_offset` the QR centre's position on the sheet
  (+X right, +Y up, metres from the centre).
- Natively the node is placed at the QR's pose, then moved back by
  `marker_offset`; the scale is the measured QR size over `marker_width`.
- Set `sheet_artwork`, `sheet_aspect`, `marker_payload`, `marker_width` and
  press **Generate Sheet**. It writes `<artwork>_<payload>.png` with the QR at
  a whole number of pixels per module, sets `marker_width` to the exact printed
  code width, makes the PNG the target's `image` and compiles it. Print that PNG
  at `width`.
- Keep the artwork busy and high-contrast. The template's
  `web/targets/site_artwork.png` is procedurally generated placeholder art; its
  A4 sheet (`width` 0.19 m, 10 cm QR) compiles to 53 and 41 tracking features.
- To check alignment on hardware, turn on `show_image` and look at the print
  from a phone and a headset: the see-through copy should sit on it on both.

### Shared space (`SiteLock`)

For co-located multiplayer, put a `SiteLock` on the scene floor where the
printed marker should be, under the content that sits on it, with its forward
(-Z) the way that content faces. During an XR session it turns off the player
body and teleport (stick move, snap turn and flat play all run through the body),
and each time the marker is tracked it moves the XR origin so the marker lands
on the `SiteLock`, with the marker's top-to-bottom edge along its forward. Only
the horizontal position and heading come from the marker: height stays the
headset's own floor and the origin only turns about the vertical, so the world
stays level. A wall marker uses its face normal as forward. Every device that
sees the marker then shares one world frame, so world-space networked state
(blocks, avatars) lines up in the room on Quest, Android XR and WebXR phones
alike. `continuous` keeps correcting drift while the marker is in view;
`position_tolerance`/`angle_tolerance` skip corrections smaller than tracking
noise. Before the first sighting the world sits wherever the device spawned it;
the `locked` signal fires once it is aligned.

### DOM overlay

Add `ShivooDOMOverlay` (`dom_overlay.gd`) to a web scene to put the project's
HTML/CSS over the page canvas, and to ask Chrome Android's immersive-ar session
for the WebXR DOM Overlay.

- Set `html_file` and `css_file`, or the inline `html` and `css`. Files must be
  in the export preset's `include_filter` (for example
  `web/dom_overlay.html, web/dom_overlay.css`); the addon's JavaScript is added
  automatically.
- `overlay_id` is the root element's id, `shivoo-dom-overlay` by default. If your
  HTML shell already has that element, leave the content fields empty and the
  node uses it.
- `activation_query` gates installation, for example `domoverlay` for
  `?domoverlay=1`. Empty installs on every page.
- `hide_outside_xr` keeps it invisible outside an immersive session; it stays in
  layout so the browser can composite it when the session starts.
- Controls work without extra JavaScript: `data-shivoo-event="name"` with
  optional `data-shivoo-data='{"json": ...}'` emits an event, and
  `data-shivoo-exit` ends the session. `data-shivoo-input-event="name"` on an
  input emits `{value: ...}` as it changes. `data-shivoo-status` and
  `data-shivoo-log` elements are updated by the page script.
- `log_input` adds pointer, touch, key and form-input diagnostics to the
  `data-shivoo-log` element, useful while laying out an overlay.
- In Godot, connect `page_event` and call `send(name, data)`. The node also emits
  `overlay_ready`, `session_started`, `overlay_ignored` and `session_ended`.
- JavaScript can call `ShivooDOMOverlay.emit(name, data)` and listen for
  `shivoo:godot`; page events also dispatch `shivoo:overlay`.

Use one overlay per page. The browser composites it only in immersive-ar where
the DOM Overlays API is implemented (Chrome on Android); elsewhere the element
remains a normal page element above the canvas.

## Updating

The submodule is a full clone: edit code inside `addons/shivoo_xr`, commit and
push there, then commit the new commit id in the project that owns it.

```sh
git -C addons/shivoo_xr commit -am "Fix ..." && git -C addons/shivoo_xr push
git add addons/shivoo_xr && git commit -m "Bump Shivoo XR"
```

In another project:

```sh
git submodule update --remote addons/shivoo_xr    # follow main
git -C addons/shivoo_xr checkout v0.2.0           # or pin a tag, which is
git add addons/shivoo_xr && git commit -m "Shivoo XR v0.2.0"
```

Prefer tags for anything shipped.

### Releasing

Update `plugin.cfg`'s `version` and `CHANGELOG.md`, commit, tag `vX.Y.Z`, push the
tag. Before 1.0, a breaking change to exported properties or global class names
bumps the minor version.

### Rebuilding the web template

Only after upgrading Godot:

```powershell
addons\shivoo_xr\tools\build-web-template.ps1
```

It needs the Godot source and emsdk paths in `-Godot` / `-Emsdk` (or
`GODOT_SOURCE` / `EMSDK`), and commits the result into `templates/`.
