class_name PoseBuffer
extends RefCounted
## A remote player's recent poses (head and both hands), stamped with the
## shared clock, for playing them back a little late: avatars are shown when
## their sound reaches you, so a strum or a hit lines up with what you hear.

const PARTS := ["head", "left", "right"]
const KEEP := 10.0 # seconds of history (covers 2-bar interval mode)
const FLOATS := 21 # 3 parts x (position xyz + rotation quaternion xyzw)
const MAX_AHEAD := 0.1 # seconds to extrapolate past the newest pose before holding it

var _times: PackedFloat64Array = []
var _poses: Array[PackedFloat32Array] = []


## Packs head/left/right Transform3Ds (missing = identity) into 21 floats.
static func pack(pose: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(FLOATS)
	for i in PARTS.size():
		var tr: Transform3D = pose.get(PARTS[i], Transform3D.IDENTITY)
		var q := tr.basis.get_rotation_quaternion()
		var o := i * 7
		out[o] = tr.origin.x
		out[o + 1] = tr.origin.y
		out[o + 2] = tr.origin.z
		out[o + 3] = q.x
		out[o + 4] = q.y
		out[o + 5] = q.z
		out[o + 6] = q.w
	return out


static func unpack(f: PackedFloat32Array) -> Dictionary:
	var pose := {}
	if f.size() != FLOATS:
		return pose
	for i in PARTS.size():
		var o := i * 7
		var q := Quaternion(f[o + 3], f[o + 4], f[o + 5], f[o + 6])
		if not q.is_normalized():
			q = q.normalized() if q.length_squared() > 1e-8 else Quaternion.IDENTITY
		pose[PARTS[i]] = Transform3D(Basis(q), Vector3(f[o], f[o + 1], f[o + 2]))
	return pose


## Adds a pose stamped at shared time t (out-of-order packets are slotted in).
func add(t: float, packed: PackedFloat32Array) -> void:
	if packed.size() != FLOATS or is_nan(t):
		return
	var i := _times.size()
	while i > 0 and _times[i - 1] > t:
		i -= 1
	if i > 0 and _times[i - 1] == t:
		return # duplicate
	_times.insert(i, t)
	_poses.insert(i, packed)
	var newest := _times[_times.size() - 1]
	while _times.size() > 2 and _times[0] < newest - KEEP:
		_times.remove_at(0)
		_poses.remove_at(0)


func is_empty() -> bool:
	return _times.is_empty()


func size() -> int:
	return _times.size()


## The pose at shared time t, interpolated between the stamps around it.
## Just past the newest pose (the next one hasn't arrived yet) it carries on
## along the last motion for up to MAX_AHEAD, then holds; before the first it
## holds. Empty if nothing has arrived.
func sample(t: float) -> Dictionary:
	if _times.is_empty():
		return {}
	if t <= _times[0]:
		return unpack(_poses[0])
	var last := _times.size() - 1
	var lo: int
	var hi: int
	if t >= _times[last]:
		if last == 0:
			return unpack(_poses[0])
		lo = last - 1
		hi = last
		t = minf(t, _times[last] + MAX_AHEAD)
	else:
		hi = _times.bsearch(t, false) # first stamp > t
		lo = hi - 1
	var k := (t - _times[lo]) / (_times[hi] - _times[lo])
	var a := unpack(_poses[lo])
	var b := unpack(_poses[hi])
	var out := {}
	for part in PARTS:
		out[part] = (a[part] as Transform3D).interpolate_with(b[part], k)
	return out
