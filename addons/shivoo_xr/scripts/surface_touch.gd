class_name SurfaceTouch
extends RefCounted
## A finger on the screen during a SurfaceTracking session. The same object comes
## with every signal for one touch, updated each time.

## Tells touches apart; the same for every signal of one touch.
var id := 0
## Where the finger's ray starts, in global space, pointing along its -Z.
var ray := Transform3D.IDENTITY
## Where the ray meets real surfaces, nearest first, in global space, each with +Y
## out of its surface. Empty until the browser has found one under the finger.
var hits: Array[Transform3D] = []


func has_hit() -> bool:
	return not hits.is_empty()


## The nearest surface under the finger. Check has_hit() first.
func hit() -> Transform3D:
	return hits[0]
