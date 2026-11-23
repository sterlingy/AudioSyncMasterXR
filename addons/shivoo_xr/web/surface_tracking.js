// Surface tracking for the Godot web export: WebXR hit tests (ARCore, in Chrome on
// Android) find where rays meet real surfaces in Godot's immersive-ar session.
// scripts/surface_tracking.gd calls prepare() before requesting the session and
// start() once it has started, then reads frameJson every frame.
//
// Godot's own WebXR code runs the session and has no hit tests, so the session's
// frames are caught on their way to Godot, which asks for each with
// XRSession.requestAnimationFrame, and frameJson is written just before Godot
// runs that frame.
(function () {
	if (window.ShivooSurfaceTracking) {
		return;
	}

	const surfaces = {
		// idle, starting, running, or an error message.
		state: 'idle',
		// {"frame": n, "center": [hit, ...], "touches": [{"id": n, "phase": "start",
		// "move" or "end", "ray": pose, "hits": [hit, ...]}, ...]}. Each hit and pose
		// is a column-major 4x4 matrix in the reference space of Godot's session.
		// center holds where the ray through the middle of the screen meets
		// surfaces, nearest first; a hit's Y axis is the surface's normal. A touch
		// ray points along its -Z axis from where the finger is on the screen.
		frameJson: '',
	};

	let session = null;
	let space = null;
	let centerSource = null;
	let touchSource = null;
	let frameCount = 0;
	// Touches from selectstart to the frame after selectend, by input source:
	// {id, started, ended, ray, hits}.
	const touches = new Map();
	// Sources already present when the session starts. These may keep reporting
	// transient hit results while not being touched (a mouse pointer in the
	// emulator, for example), so only a real selectstart may create a touch for
	// one. Sources added later are per-touch transient sources.
	const initialSources = new Set();
	let nextTouchId = 1;

	function matrix(pose) {
		return Array.from(pose.transform.matrix);
	}

	function hitMatrices(results) {
		const hits = [];
		for (const result of results) {
			const pose = result.getPose(space);
			if (pose) {
				hits.push(matrix(pose));
			}
		}
		return hits;
	}

	function rayIn(frame, inputSource) {
		const pose = frame.getPose(inputSource.targetRaySpace, space);
		return pose ? matrix(pose) : null;
	}

	// Cancelled selects from a transient source are still auxiliary touches. The
	// DOM overlay marks card interaction here so those touches cannot drive the
	// scene gestures behind it.
	function sceneInputBlocked() {
		const overlay = window.ShivooDOMOverlay;
		return !!(overlay && overlay.blockSceneInput);
	}

	function touchFor(frame, inputSource) {
		let touch = touches.get(inputSource);
		if (touch) {
			return touch;
		}
		touch = {
			id: nextTouchId++,
			started: false,
			ended: false,
			ray: rayIn(frame, inputSource),
			hits: [],
			lastSeen: frameCount,
		};
		touches.set(inputSource, touch);
		return touch;
	}

	function onSelectStart(event) {
		if (!space || !event.inputSource) {
			return;
		}
		const mode = event.inputSource.targetRayMode;
		if (mode !== 'screen' && mode !== 'transient-pointer') {
			return;
		}
		if (sceneInputBlocked()) {
			return;
		}
		const touch = touchFor(event.frame, event.inputSource);
		touch.ray = rayIn(event.frame, event.inputSource) || touch.ray;
		touch.lastSeen = frameCount;
	}

	function onSelectEnd(event) {
		const touch = touches.get(event.inputSource);
		if (!touch) {
			return;
		}
		touch.ended = true;
		// The input source of a touch is gone by the next frame.
		touch.ray = rayIn(event.frame, event.inputSource) || touch.ray;
	}

	// A tap can begin and end between frames, before the browser has hit tested its
	// input source, so the ray of one that ended without hits is hit tested on its
	// own, for up to this many frames, before its end is reported.
	const TAP_HIT_FRAMES = 30;

	function awaitingTapHits(frame, touch) {
		// A transient touch already had its hit-test chance; waiting for a tap
		// hit would keep a finger in the gesture set for ~30 frames after it ends.
		if (touch.hits.length || touch.fromTransient) {
			return false;
		}
		if (!touch.tap) {
			const m = touch.ray;
			const tap = touch.tap = {source: null, failed: false, frames: 0};
			session.requestHitTestSource({
				space: space,
				offsetRay: new XRRay({x: m[12], y: m[13], z: m[14], w: 1}, {x: -m[8], y: -m[9], z: -m[10], w: 0}),
			}).then((source) => {
				tap.source = source;
			}, (error) => {
				console.error(error);
				tap.failed = true;
			});
			return true;
		}
		const tap = touch.tap;
		if (tap.source) {
			touch.hits = hitMatrices(frame.getHitTestResults(tap.source));
		}
		tap.frames += 1;
		const done = touch.hits.length > 0 || tap.failed || tap.frames > TAP_HIT_FRAMES;
		if (done && tap.source) {
			tap.source.cancel();
		}
		return !done;
	}

	function onFrame(frame) {
		const center = centerSource ? hitMatrices(frame.getHitTestResults(centerSource)) : [];
		const seen = new Set();
		if (touchSource) {
			for (const result of frame.getHitTestResultsForTransientInput(touchSource)) {
				const inputSource = result.inputSource;
				if (!inputSource) {
					continue;
				}
				let touch = touches.get(inputSource);
				if (!touch) {
					// A source that existed before the session is a persistent pointer;
					// only selectstart may turn it into a touch. A new source is a finger;
					// create a touch for it once it has a surface hit. No-hit sources are
					// overlay touches or fingers in the air and would otherwise linger.
					if (initialSources.has(inputSource) || result.results.length === 0 || sceneInputBlocked()) {
						continue;
					}
					touch = touchFor(frame, inputSource);
					touch.fromTransient = true;
				}
				if (!touch.ended) {
					touch.hits = hitMatrices(result.results);
					touch.lastSeen = frameCount;
					seen.add(inputSource);
				}
			}
		}
		const events = [];
		for (const [inputSource, touch] of touches) {
			if (!touch.ended && !seen.has(inputSource) && frameCount - touch.lastSeen > 1) {
				touch.ended = true;
			}
			if (!touch.ended) {
				touch.ray = rayIn(frame, inputSource) || touch.ray;
			}
			if (!touch.ray) {
				continue;
			}
			const event = (phase) => events.push({id: touch.id, phase: phase, ray: touch.ray, hits: touch.hits});
			if (!touch.started) {
				touch.started = true;
				event('start');
			} else if (!touch.ended) {
				event('move');
			}
			if (touch.ended && !awaitingTapHits(frame, touch)) {
				event('end');
				touches.delete(inputSource);
			}
		}
		frameCount += 1;
		surfaces.frameJson = JSON.stringify({frame: frameCount, center: center, touches: events});
	}

	function reset() {
		session = null;
		space = null;
		centerSource = null;
		touchSource = null;
		touches.clear();
		initialSources.clear();
		surfaces.frameJson = '';
		surfaces.state = 'idle';
	}

	// Call before Godot requests its session.
	surfaces.prepare = function () {
		if (typeof XRSession === 'undefined' || XRSession.prototype.shivooSurfaces) {
			return;
		}
		const requestSession = XRSystem.prototype.requestSession;
		XRSystem.prototype.requestSession = function (mode, init) {
			return requestSession.call(this, mode, init).then((started) => {
				if (mode === 'immersive-ar') {
					reset();
					session = started;
					started.addEventListener('selectstart', onSelectStart);
					started.addEventListener('selectend', onSelectEnd);
					started.addEventListener('end', () => {
						if (session === started) {
							reset();
						}
					});
				}
				return started;
			});
		};
		const request = XRSession.prototype.requestAnimationFrame;
		XRSession.prototype.requestAnimationFrame = function (callback) {
			const current = this;
			return request.call(current, (time, frame) => {
				if (current === session && space) {
					try {
						onFrame(frame);
					} catch (error) {
						console.error(error);
					}
				}
				callback(time, frame);
			});
		};
		XRSession.prototype.shivooSurfaces = true;
	};

	// Starts hit testing in the session Godot started, whose reference space is of
	// type spaceType.
	surfaces.start = async function (spaceType) {
		if (!session) {
			surfaces.state = 'error: no WebXR session';
			return;
		}
		const current = session;
		surfaces.state = 'starting';
		try {
			const reference = await current.requestReferenceSpace(spaceType);
			const viewer = await current.requestReferenceSpace('viewer');
			const center = await current.requestHitTestSource({space: viewer});
			const touch = await current.requestHitTestSourceForTransientInput({profile: 'generic-touchscreen'});
			if (session !== current) {
				return;
			}
			space = reference;
			centerSource = center;
			touchSource = touch;
			initialSources.clear();
			for (const source of current.inputSources) {
				initialSources.add(source);
			}
			surfaces.state = 'running';
		} catch (error) {
			console.error(error);
			if (session === current) {
				surfaces.state = 'error: ' + error.message;
			}
		}
	};

	window.ShivooSurfaceTracking = surfaces;
})();
