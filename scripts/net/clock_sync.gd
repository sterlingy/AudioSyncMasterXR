class_name ClockSync
extends RefCounted
## NTP-style clock offset estimate from ping/pong exchanges with the host.
##
## Each exchange gives t0 (our clock, sent), t1 (host clock, answered) and
## t2 (our clock, received). The host's clock minus ours is about
## t1 - (t0 + t2) / 2, exact when both legs take equally long. Legs are
## uneven when one side waits for its next frame, so the sample with the
## shortest round trip in a recent window is trusted (it waited least).

const WINDOW := 24

var samples: Array = [] # [rtt, offset], newest last
var offset := 0.0
var rtt := -1.0 # of the trusted sample
var last_rtt := -1.0


func reset() -> void:
	samples.clear()
	offset = 0.0
	rtt = -1.0
	last_rtt = -1.0


func ready() -> bool:
	return samples.size() >= 4


func add(t0: float, t1: float, t2: float) -> void:
	var r := t2 - t0
	if r < 0.0 or r > 2.0:
		return
	last_rtt = r
	samples.append([r, t1 - (t0 + t2) * 0.5])
	if samples.size() > WINDOW:
		samples.pop_front()
	var best: Array = samples[0]
	for s in samples:
		if s[0] < best[0]:
			best = s
	rtt = best[0]
	offset = best[1]


## Worst-case error of the current offset: half the trusted round trip.
func error_bound() -> float:
	return rtt * 0.5 if rtt >= 0.0 else INF
