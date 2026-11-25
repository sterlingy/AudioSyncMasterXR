class_name HandPlayer
extends Node
## Play the 3D instrument with your fingertips. The playable parts come from
## the model's own named meshes (keys *_W<i> / *_B<i>, Pulsar pads, Driftwood
## bars and tines), so they always match what you see. A fingertip pushed down
## through a part's top plays it (faster = louder) and lifting releases it.
## Notes go through Midi.inject_*, like the on-screen keys, so looping,
## recording and the session work unchanged.
##
## Tips come from the OpenXR hand trackers (all ten fingertips); tests feed
## them with update_tips().

const WHITE := [0, 2, 4, 5, 7, 9, 11]
const BLACK_AFTER := {0: 1, 1: 3, 3: 6, 4: 8, 5: 10} # white index in octave -> semitone of the black key after it
const BASE_NOTE := {"Undertow": 36, "Comet": 60, "Lumen": 48, "Prism": 48, "Tangle": 48}
const PADS := {"00": 36, "10": 38, "20": 39, "30": 42, "01": 46, "11": 45, "21": 50, "31": 49}
const BARS := [60, 62, 64, 65, 67, 69, 71, 72, 74] # Driftwood, low on the left
const TINES := [84, 79, 76, 72, 74, 77, 81] # kalimba: lowest in the middle
const TIP_RADIUS := 0.006 # the finger pad sits this far below the tracked tip
const PRESS_DEPTH := 0.004 # how far through the top before it plays
const RELEASE_ABOVE := 0.003
const MAX_FROM_BELOW := 0.04 # a tip further under the top than this doesn't press (hand resting on the body)
const SINK := 0.004 # pressed parts move down this much
const FULL_SPEED := 0.8 # m/s downward for full velocity
# Knobs on the models: pinch one (thumb + index), then move your hand right
# (up) or left (down), along the instrument's own left-right.
const KNOB_PARAMS := {
	"Undertow": ["filter.cutoff", "filter.emphasis", "filter.contour", "fenv.attack", "fenv.decay", "fenv.sustain",
		"mix.osc1", "mix.osc2", "mix.osc3", "mix.noise", "lenv.attack", "lenv.decay",
		"ctrl.tune", "ctrl.glide", "osc2.freq", "osc3.freq", "lenv.sustain", "out.volume"],
	"Comet": ["filter.cutoff", "filter.resonance", "filter.env", "aenv.release", "vibrato.depth", "delay.mix", "out.volume"],
	"Lumen": ["filter.cutoff", "filter.resonance", "filter.env", "aenv.attack", "aenv.release", "lfo.rate",
		"chorus.mix", "reverb.size", "reverb.mix", "out.volume"],
	"Pulsar": ["kick.tune", "kick.decay", "snare.tone", "snare.snap", "chat.decay", "ohat.decay", "master.drive", "master.volume"],
	"Prism": ["macro1", "macro2", "macro3", "macro4", "f1.cutoff", "f1.resonance", "a.morph", "env1.release"],
}
const PINCH_ON := 0.022 # thumb-index distance that starts a pinch
const PINCH_OFF := 0.035
const KNOB_REACH := 0.045 # how close the pinch must be to a knob's centre
const KNOB_TRAVEL := 0.12 # sideways hand movement (m) for the full range
const LABEL_COLOR := Color(0.85, 0.87, 0.92)
const LABEL_HELD := Color(0.4, 1.0, 0.9)
const KNOB_SWEEP := 270.0 # degrees from minimum to maximum
const KNOB_HEIGHT := 0.65 # the models' knobs are drawn at this fraction of their height
const KNOB_WIDTH := 0.85 # ... and width, leaving room for the labels between rows

var model: Node3D
var origin: XROrigin3D # hand joints are relative to it
var instrument := ""
var octave_shift := 0 # in octaves, for the keyboards
var zones: Array = [] # {note, min: Vector3, max: Vector3, node, rest: Vector3}, model-local, highest first
var _tips := {} # tip id -> {pos: Vector3 (model-local), zone: int, t}
var _strip: Node3D # Tangle's key strip
var rig: InstrumentRig # whose parameters the knobs set (the local player's)
var knobs: Array = [] # {node, id, name, unit, min, max, log, center (model-local), rest: Basis, label: Label3D}
var _held_knob := {} # hand side -> {knob, x0, t0}
var _pinching := {} # hand side -> bool
var _t_sync := 0.0


## Builds the playable zones for `m` (an InstrumentModels instance) of `type`.
func setup(m: Node3D, type: String) -> void:
	release_all()
	model = m
	instrument = type
	zones.clear()
	if _strip:
		_strip.queue_free()
		_strip = null
	if model == null:
		return
	if type == "Tangle":
		_strip = _build_strip()
		model.add_child(_strip)
	var inv := model.global_transform.affine_inverse() if model.is_inside_tree() else Transform3D.IDENTITY
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var note := _note_for(String(mi.name), type)
		if note < 0:
			continue
		var xf: Transform3D = (inv * mi.global_transform) if model.is_inside_tree() else _local_xf(mi)
		var box: AABB = xf * (mi as MeshInstance3D).get_aabb()
		zones.append({"note": note, "min": box.position, "max": box.end, "node": mi, "rest": mi.position})
	zones.sort_custom(func(a, b): return a.max.y > b.max.y) # black keys before the white keys under them
	_build_knobs()


func _build_knobs() -> void:
	knobs.clear()
	_held_knob.clear()
	var ids: Array = KNOB_PARAMS.get(instrument, [])
	if ids.is_empty() or rig == null:
		return
	var params := {}
	for p in rig.synth.get_param_list():
		params[p.id] = p
	var meshes := {}
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		meshes[String(mi.name)] = mi
	var names := []
	for n in meshes:
		var part: PackedStringArray = n.split("_")
		if part.size() == 2 and ((part[1].begins_with("K") and part[1].substr(1).is_valid_int()) or part[1].begins_with("Knob")):
			names.append(n)
	names.sort() # Undertow_K00..K25 row by row; Comet_K0..; Pulsar_Knob0..
	for i in mini(names.size(), ids.size()):
		var info: Dictionary = params.get(ids[i], {})
		if info.is_empty():
			continue
		var node: MeshInstance3D = meshes[names[i]]
		var dot: Node3D = meshes.get(names[i] + "_dot")
		if dot:
			dot.reparent(node, true) # the marker turns with its knob
		# Lower knobs (2/3 height, still sitting on the panel) so they don't hide the labels behind them.
		var axis := node.basis.y.normalized()
		var h := node.get_aabb().size.y * node.basis.y.length()
		node.basis = node.basis * Basis.from_scale(Vector3(KNOB_WIDTH, KNOB_HEIGHT, KNOB_WIDTH))
		node.position -= axis * h * (1.0 - KNOB_HEIGHT) * 0.5
		var c: Vector3 = model.global_transform.affine_inverse() * node.global_position
		var k := {"node": node, "id": ids[i], "name": str(info.name), "unit": str(info.unit), "min": float(info.min),
			"max": float(info.max), "log": bool(info.log), "center": c, "rest": node.basis}
		k.label = _make_label(k)
		knobs.append(k)
	_sync_knobs()


## Name and value, lying on the panel just in front of (below) the knob, upright for the player.
func _make_label(k: Dictionary) -> Label3D:
	var l := Label3D.new()
	l.name = String(k.node.name) + "_label"
	l.pixel_size = 0.0002
	l.font_size = 24
	l.line_spacing = -3.0
	l.outline_size = 6
	l.modulate = LABEL_COLOR
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	var rest: Basis = k.rest
	var up := rest.y.normalized() # the knob's axis: out of the panel surface
	var toward_player := rest.z.normalized()
	var radius := 0.0
	var aabb: AABB = (k.node as MeshInstance3D).get_aabb()
	radius = maxf(aabb.size.x, aabb.size.z) * 0.5 * KNOB_WIDTH
	# Face out of the surface, text running left to right, top away from the player.
	l.basis = rest.orthonormalized() * Basis(Vector3.RIGHT, deg_to_rad(-90))
	l.position = k.center - up * (0.0045 - 0.009 * (1.0 - KNOB_HEIGHT)) + toward_player * (radius + 0.0015) # 1.5 mm above the surface, close to the knob
	model.add_child(l)
	return l


func _to_t(k: Dictionary, v: float) -> float:
	if k.log and k.min > 0.0:
		return clampf(log(v / k.min) / log(k.max / k.min), 0.0, 1.0)
	return clampf((v - k.min) / (k.max - k.min), 0.0, 1.0)


func _from_t(k: Dictionary, t: float) -> float:
	if k.log and k.min > 0.0:
		return k.min * pow(k.max / k.min, t)
	return lerpf(k.min, k.max, t)


func _show_knob(k: Dictionary, t: float) -> void:
	if is_instance_valid(k.node):
		(k.node as Node3D).basis = (k.rest as Basis) * Basis(Vector3.UP, deg_to_rad(-(t - 0.5) * KNOB_SWEEP))


## Knobs and their labels follow the sound (presets, panel, MIDI controllers).
func _sync_knobs() -> void:
	if rig == null:
		return
	for k in knobs:
		var v := rig.synth.get_param(k.id)
		_show_knob(k, _to_t(k, v))
		_set_label(k, v, false)


func _set_label(k: Dictionary, v: float, held: bool) -> void:
	var l: Label3D = k.get("label")
	if l == null or not is_instance_valid(l):
		return
	var nm: String = k.name
	if nm.length() > 11:
		nm = nm.left(10) + "."
	l.text = "%s\n%s" % [nm, _fmt(v, k.unit)]
	l.modulate = LABEL_HELD if held else LABEL_COLOR


## pinches: hand side -> world position of the pinch (thumb/index midpoint), for
## hands that are pinching now. Grabs, turns and lets go of knobs.
func update_pinches(pinches: Dictionary) -> void:
	if model == null or rig == null:
		return
	var inv := model.global_transform.affine_inverse()
	for side in _held_knob.keys():
		if not pinches.has(side):
			var k: Dictionary = _held_knob[side].knob
			_set_label(k, rig.synth.get_param(k.id), false)
			_held_knob.erase(side)
	for side in pinches:
		var p: Vector3 = inv * (pinches[side] as Vector3)
		if _held_knob.has(side):
			var h: Dictionary = _held_knob[side]
			var k: Dictionary = h.knob
			var t := clampf(float(h.t0) + (p.x - float(h.x0)) / KNOB_TRAVEL, 0.0, 1.0)
			var v := _from_t(k, t)
			rig.set_param(k.id, v)
			_show_knob(k, t)
			_set_label(k, v, true)
			continue
		var best := -1
		var best_d := KNOB_REACH
		for i in knobs.size():
			var d: float = p.distance_to(knobs[i].center)
			if d < best_d:
				best_d = d
				best = i
		if best >= 0:
			var k: Dictionary = knobs[best]
			_held_knob[side] = {"knob": k, "x0": p.x, "t0": _to_t(k, rig.synth.get_param(k.id))}
			_set_label(k, rig.synth.get_param(k.id), true)


static func _fmt(v: float, unit: String) -> String:
	var txt := ("%.0f" % v) if absf(v) >= 100.0 else ("%.2f" % v)
	return txt + (" " + unit if unit != "" else "")


func _local_xf(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur and cur != model:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


func _note_for(name: String, type: String) -> int:
	var parts := name.split("_")
	if parts.size() < 2:
		return -1
	var part := parts[1]
	if type in BASE_NOTE:
		var base: int = BASE_NOTE[type] + 12 * octave_shift
		if part.begins_with("W") and part.substr(1).is_valid_int():
			var i := int(part.substr(1))
			return base + 12 * (i / 7) + WHITE[i % 7]
		if part.begins_with("B") and part.substr(1).is_valid_int():
			var i := int(part.substr(1))
			if BLACK_AFTER.has(i % 7):
				return base + 12 * (i / 7) + BLACK_AFTER[i % 7]
	if type == "Pulsar" and part.begins_with("Pad"):
		return PADS.get(part.substr(3), -1)
	if type == "Driftwood":
		if part.begins_with("Bar") and part.substr(3).is_valid_int():
			var i := int(part.substr(3))
			return BARS[i] if i < BARS.size() else -1
		if part.begins_with("Tine") and part.substr(4).is_valid_int():
			var i := int(part.substr(4))
			return TINES[i] if i < TINES.size() else -1
	return -1


## Tangle has no keys of its own: two octaves in front of its case.
func _build_strip() -> Node3D:
	var strip := Node3D.new()
	strip.name = "Tangle_KeyStrip"
	var ivory := StandardMaterial3D.new()
	ivory.albedo_color = Color(0.88, 0.87, 0.84)
	var ebony := StandardMaterial3D.new()
	ebony.albedo_color = Color(0.03, 0.03, 0.035)
	var ww := 0.022
	var x0 := -ww * 7.5
	for i in 15:
		var k := MeshInstance3D.new()
		k.name = "Tangle_W%d" % i
		var bm := BoxMesh.new()
		bm.size = Vector3(ww * 0.94, 0.016, 0.11)
		k.mesh = bm
		k.material_override = ivory
		k.position = Vector3(x0 + (i + 0.5) * ww, 0.008, 0.17)
		strip.add_child(k)
	for o in 2:
		for kk in [0, 1, 3, 4, 5]:
			var i: int = o * 7 + kk
			var b := MeshInstance3D.new()
			b.name = "Tangle_B%d" % i
			var bm := BoxMesh.new()
			bm.size = Vector3(ww * 0.55, 0.014, 0.068)
			b.mesh = bm
			b.material_override = ebony
			b.position = Vector3(x0 + (i + 1) * ww, 0.023, 0.15)
			strip.add_child(b)
	return strip


func release_all() -> void:
	for id in _tips:
		_lift(_tips[id])
	_tips.clear()


func _process(_delta: float) -> void:
	if model == null or not model.is_inside_tree():
		return
	var tips := {}
	for hand in [XRPositionalTracker.TRACKER_HAND_LEFT, XRPositionalTracker.TRACKER_HAND_RIGHT]:
		var tr := XRServer.get_tracker("/user/hand_tracker/left" if hand == XRPositionalTracker.TRACKER_HAND_LEFT else "/user/hand_tracker/right") as XRHandTracker
		if tr == null or not tr.has_tracking_data:
			continue
		for j in [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
				XRHandTracker.HAND_JOINT_RING_FINGER_TIP, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]:
			if tr.get_hand_joint_flags(j) & XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED:
				tips["%d_%d" % [hand, j]] = _world_tip(tr.get_hand_joint_transform(j).origin)
	update_tips(tips, Time.get_ticks_msec() / 1000.0)
	var pinches := {}
	for side in [0, 1]:
		var tr := XRServer.get_tracker("/user/hand_tracker/left" if side == 0 else "/user/hand_tracker/right") as XRHandTracker
		if tr == null or not tr.has_tracking_data:
			_pinching[side] = false
			continue
		var a := tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
		var b := tr.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
		var d := a.distance_to(b)
		var on: bool = d < (PINCH_OFF if _pinching.get(side, false) else PINCH_ON)
		_pinching[side] = on
		if on:
			pinches[side] = _world_tip((a + b) * 0.5)
	update_pinches(pinches)
	_t_sync -= get_process_delta_time()
	if _t_sync <= 0.0 and _held_knob.is_empty():
		_t_sync = 0.25
		_sync_knobs()


## Hand joints are in the play space, relative to the XROrigin3D.
func _world_tip(p: Vector3) -> Vector3:
	return origin.global_transform * p if origin else p


## tips: id -> world position. Plays and releases zones as tips cross their tops.
func update_tips(tips: Dictionary, t: float) -> void:
	var inv := model.global_transform.affine_inverse()
	for id in _tips.keys():
		if not tips.has(id):
			_lift(_tips[id])
			_tips.erase(id)
	for id in tips:
		var p: Vector3 = inv * (tips[id] as Vector3)
		p.y -= TIP_RADIUS
		var st: Dictionary = _tips.get(id, {"pos": p, "zone": -1, "t": t})
		var dt := maxf(t - float(st.t), 1e-3)
		var speed := (float(st.pos.y) - p.y) / dt # downward speed
		if st.zone >= 0:
			var z: Dictionary = zones[st.zone]
			var inside: bool = p.x > z.min.x - 0.004 and p.x < z.max.x + 0.004 and p.z > z.min.z - 0.004 and p.z < z.max.z + 0.004
			if p.y > z.max.y + RELEASE_ABOVE or not inside:
				_lift(st)
		if st.zone < 0:
			for i in zones.size():
				var z: Dictionary = zones[i]
				if p.x < z.min.x or p.x > z.max.x or p.z < z.min.z or p.z > z.max.z:
					continue
				var top: float = z.max.y
				# Pressed: crossed the top going down (not a hand resting below it).
				if p.y < top - PRESS_DEPTH and p.y > top - MAX_FROM_BELOW and float(st.pos.y) >= top - PRESS_DEPTH:
					if _held_by_other(i, id):
						break
					st.zone = i
					var vel := int(clampf(speed / FULL_SPEED, 0.25, 1.0) * 127.0)
					Midi.inject_note_on(z.note, vel)
					if is_instance_valid(z.node):
						(z.node as Node3D).position = z.rest - Vector3(0, SINK, 0)
				break # the highest zone under the tip decides
		st.pos = p
		st.t = t
		_tips[id] = st


func _held_by_other(zone: int, id: String) -> bool:
	for other in _tips:
		if other != id and _tips[other].zone == zone:
			return true
	return false


func _lift(st: Dictionary) -> void:
	if st.zone < 0 or st.zone >= zones.size():
		st.zone = -1
		return
	var z: Dictionary = zones[st.zone]
	Midi.inject_note_off(z.note)
	if is_instance_valid(z.node):
		(z.node as Node3D).position = z.rest
	st.zone = -1


## Number of zones (for tests and the status line).
func zone_count() -> int:
	return zones.size()
