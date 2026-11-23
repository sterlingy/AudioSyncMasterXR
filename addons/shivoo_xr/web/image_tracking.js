// Image tracking for the Godot web export. MindAR (web/mindar_image.js), in a
// worker, tracks the targets in a camera feed that is shown behind the transparent
// Godot canvas. scripts/image_tracking.gd starts it and reads frameJson every frame.
//
// By default the feed shown is not the live camera but the last frame that was
// tracked, swapped in by present() when Godot applies that frame's poses, so the
// content stays fixed to the image instead of trailing it by the tracking time.
// ?sync=0 shows the live camera instead.
//
// ?source=synthetic replaces the camera with a rendered target moving along a
// known path, for testing without a camera. truthJson then holds the real pose.
//
// ?profile=1 shows where the time goes, over the last few seconds; profileJson
// holds the same figures.
//
// ?gyro=0 leaves out the device's orientation, which otherwise keeps content in
// place through brief losses of tracking.
//
// With a WebXR immersive-ar session (see prepareXR() and start()'s source option),
// MindAR tracks the session's camera images instead, and frameJson gives where
// the camera was for each, so Godot can keep content where its image is in the
// room. Where the session gives no camera images (headset browsers leave
// camera-access out), it tracks a getUserMedia world camera instead, and the
// viewer's pose stands in for the camera's.
//
// ?mindar={...} overrides MindAR Controller options, e.g.
// ?mindar={"trackerOptions":{"searchRadius":6}}, for tuning on a device.
(function () {
	if (window.ShivooImageTracking) {
		return;
	}

	const tracking = {
		// idle, starting, warming up, running, or an error message.
		state: 'idle',
		// How the camera feed was acquired: '', 'webxr' for the session's camera
		// images, or 'getusermedia' for the world camera, where headset browsers
		// leave camera-access out.
		cameraMode: '',
		// {"frame": n, "poses": [16 floats or null per target], "camera": 16 floats or
		// null, "pixelsPerMeter": [per target]}, column-major like WebGL. Poses are
		// from the camera; with WebXR, camera is where it was, in the session's
		// reference space, and pixelsPerMeter how big each target has turned out to
		// be (0 until known, if no width was given).
		frameJson: '',
		// [[width, height], ...] of each target image in pixels.
		dimensionsJson: '',
		// Size of the frames MindAR sees, and its focal length in those pixels.
		sourceWidth: 0,
		sourceHeight: 0,
		focal: 0,
		truthJson: '',
		profileJson: '',
	};

	let worker = null;
	let workerUrl = null;
	// When the frame in flight was sent to the worker, and the camera transform
	// sent with it.
	let sentAt = 0;
	let sentCamera = null;
	let source = null;
	let targetsBuffers = [];
	let options = {};
	let poses = [];
	let frame = 0;
	// Bumped when the controller restarts, so the old loop stops.
	let generation = 0;
	// The frame being tracked, the tracked frame waiting for present(), and the one
	// on screen.
	let capture = null;
	let pending = null;
	let display = null;
	let pendingReady = false;
	// Whether the source itself shows, over display, rather than the tracked frames.
	let showingLive = false;
	// The elements shown behind the canvas, and the canvas rectangle they were fitted to.
	const backgrounds = [];
	let laidOut = '';

	tracking.param = function (name) {
		return new URLSearchParams(window.location.search).get(name) || '';
	};

	// WebXR shows the camera itself, and Godot places content in its space.
	function syncDisplay() {
		return !xr && tracking.param('sync') !== '0';
	}

	// Samples of [time, milliseconds] per stage, kept for PROFILE_WINDOW.
	const PROFILE_WINDOW = 3000;
	const profileSamples = new Map();
	const profiling = tracking.param('profile') === '1';

	function record(name, ms) {
		if (!profiling) {
			return;
		}
		const now = performance.now();
		if (!profileSamples.has(name)) {
			profileSamples.set(name, []);
		}
		const samples = profileSamples.get(name);
		samples.push([now, ms]);
		while (samples.length && samples[0][0] < now - PROFILE_WINDOW) {
			samples.shift();
		}
	}

	function startProfiling() {
		const panel = document.createElement('pre');
		panel.style.cssText = 'position:fixed;left:0;bottom:0;margin:0;padding:6px;z-index:10;' +
			'pointer-events:none;font:11px/1.3 monospace;color:#fff;background:rgba(0,0,0,0.65);';
		document.body.appendChild(panel);

		let last = performance.now();
		const tick = (now) => {
			record('page frame', now - last);
			last = now;
			requestAnimationFrame(tick);
		};
		requestAnimationFrame(tick);
		// Anything that held the main thread for over 50 ms, which Godot then waits on.
		if (window.PerformanceObserver && PerformanceObserver.supportedEntryTypes.includes('longtask')) {
			new PerformanceObserver((list) => {
				for (const entry of list.getEntries()) {
					record('main thread stall', entry.duration);
				}
			}).observe({type: 'longtask'});
		}

		setInterval(() => {
			const now = performance.now();
			const rows = [];
			const summary = {state: tracking.state, source: [tracking.sourceWidth, tracking.sourceHeight]};
			for (const [name, samples] of profileSamples) {
				const recent = samples.filter(([time]) => time >= now - PROFILE_WINDOW).map(([, ms]) => ms);
				if (!recent.length) {
					continue;
				}
				const sorted = recent.slice().sort((a, b) => a - b);
				const stats = {
					perSecond: recent.length / (PROFILE_WINDOW / 1000),
					mean: recent.reduce((a, b) => a + b, 0) / recent.length,
					p95: sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))],
					max: sorted[sorted.length - 1],
				};
				summary[name] = stats;
				rows.push(name.padEnd(18) + stats.perSecond.toFixed(1).padStart(5) + '/s' +
					stats.mean.toFixed(1).padStart(7) + stats.p95.toFixed(1).padStart(7) + stats.max.toFixed(1).padStart(7));
			}
			tracking.profileJson = JSON.stringify(summary);
			panel.textContent = tracking.state + '  ' + tracking.sourceWidth + 'x' + tracking.sourceHeight + '\n' +
				'stage (ms)            rate   mean    p95    max\n' + rows.join('\n');
		}, 500);
	}

	// Godot draws into an offscreen framebuffer and, each frame, Emscripten asks
	// WebGL for the scissor test and framebuffer bindings before copying it to the
	// screen. On phones those queries wait for the GPU process to finish everything
	// queued, tracking work included, which took half the main thread. Answer them
	// from state tracked here instead.
	function shadowCanvasState() {
		const canvas = document.getElementById('canvas');
		const gl = canvas && canvas.getContext('webgl2');
		if (!gl || gl.shivooShadowed) {
			return;
		}
		const SCISSOR_TEST = 0x0C11;
		const FRAMEBUFFER = 0x8D40;
		const READ_FRAMEBUFFER = 0x8CA8;
		const DRAW_FRAMEBUFFER = 0x8CA9;
		const DRAW_FRAMEBUFFER_BINDING = 0x8CA6;
		const READ_FRAMEBUFFER_BINDING = 0x8CAA;
		const state = {
			scissor: gl.isEnabled(SCISSOR_TEST),
			draw: gl.getParameter(DRAW_FRAMEBUFFER_BINDING),
			read: gl.getParameter(READ_FRAMEBUFFER_BINDING),
		};
		const getParameter = gl.getParameter.bind(gl);
		const enable = gl.enable.bind(gl);
		const disable = gl.disable.bind(gl);
		const bindFramebuffer = gl.bindFramebuffer.bind(gl);
		const deleteFramebuffer = gl.deleteFramebuffer.bind(gl);
		gl.enable = (cap) => {
			if (cap === SCISSOR_TEST) {
				state.scissor = true;
			}
			enable(cap);
		};
		gl.disable = (cap) => {
			if (cap === SCISSOR_TEST) {
				state.scissor = false;
			}
			disable(cap);
		};
		gl.bindFramebuffer = (target, framebuffer) => {
			if (target === FRAMEBUFFER || target === DRAW_FRAMEBUFFER) {
				state.draw = framebuffer;
			}
			if (target === FRAMEBUFFER || target === READ_FRAMEBUFFER) {
				state.read = framebuffer;
			}
			bindFramebuffer(target, framebuffer);
		};
		gl.deleteFramebuffer = (framebuffer) => {
			if (framebuffer && state.draw === framebuffer) {
				state.draw = null;
			}
			if (framebuffer && state.read === framebuffer) {
				state.read = null;
			}
			deleteFramebuffer(framebuffer);
		};
		gl.getParameter = (name) => {
			if (name === SCISSOR_TEST) {
				return state.scissor;
			}
			if (name === DRAW_FRAMEBUFFER_BINDING) {
				return state.draw;
			}
			if (name === READ_FRAMEBUFFER_BINDING) {
				return state.read;
			}
			return getParameter(name);
		};
		gl.shivooShadowed = true;
	}
	shadowCanvasState();

	if (profiling) {
		if (document.body) {
			startProfiling();
		} else {
			window.addEventListener('DOMContentLoaded', startProfiling);
		}
	}

	function showBehindCanvas(element) {
		element.style.cssText = 'position:fixed;object-fit:cover;z-index:-1;pointer-events:none;';
		if (syncDisplay() && element !== display) {
			// Still in the document, so the browser keeps decoding it.
			element.style.opacity = '0';
		}
		document.body.prepend(element);
		backgrounds.push(element);
		laidOut = '';
		layout();
		document.documentElement.style.background = 'transparent';
		document.body.style.background = 'transparent';
		const canvas = document.getElementById('canvas');
		if (canvas) {
			canvas.style.background = 'transparent';
		}
	}

	// Godot's camera is fitted to its canvas, so the feed has to cover exactly that.
	// 100vh would not: on phones it is taller than the page while the browser's bars
	// show, which scales the feed up and shifts it down.
	function layout() {
		const canvas = document.getElementById('canvas');
		const rect = canvas ? canvas.getBoundingClientRect() :
			{left: 0, top: 0, width: window.innerWidth, height: window.innerHeight};
		const key = [rect.left, rect.top, rect.width, rect.height].join();
		if (key === laidOut) {
			return;
		}
		laidOut = key;
		for (const element of backgrounds) {
			element.style.left = rect.left + 'px';
			element.style.top = rect.top + 'px';
			element.style.width = rect.width + 'px';
			element.style.height = rect.height + 'px';
		}
	}
	window.addEventListener('resize', layout);

	// A camera whose feed shows behind the canvas, or with show false one that only
	// feeds MindAR, for the XR fallback where the session shows the room instead.
	async function openCamera(show = true) {
		const constraints = {width: {ideal: 640}, height: {ideal: 480}};
		let stream = null;
		let error = null;
		try {
			stream = await navigator.mediaDevices.getUserMedia({audio: false, video: Object.assign({facingMode: 'environment'}, constraints)});
			const track = stream.getVideoTracks()[0];
			// Browsers that expose one camera ignore facingMode and hand out the selfie one.
			if (track && track.getSettings().facingMode === 'user') {
				error = new Error('camera faces the user');
				for (const other of stream.getTracks()) {
					other.stop();
				}
				stream = null;
			}
		} catch (caught) {
			error = caught;
		}
		if (!stream) {
			stream = await openBackCamera(error, constraints);
		}
		const video = document.createElement('video');
		video.setAttribute('autoplay', '');
		video.setAttribute('muted', '');
		video.setAttribute('playsinline', '');
		video.muted = true;
		video.srcObject = stream;
		if (show) {
			showBehindCanvas(video);
		} else {
			// Still in the document, so the browser keeps decoding it.
			video.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none;';
			document.body.appendChild(video);
		}
		if (video.readyState < 1) {
			await new Promise((resolve) => video.addEventListener('loadedmetadata', resolve, {once: true}));
		}
		await video.play();
		// MindAR reads the frame size from the width and height attributes.
		video.width = video.videoWidth;
		video.height = video.videoHeight;
		if (show) {
			// Phones swap the frame size when they rotate.
			video.addEventListener('resize', () => {
				if (video.videoWidth !== video.width || video.videoHeight !== video.height) {
					video.width = video.videoWidth;
					video.height = video.videoHeight;
					startController();
				}
			});
		}
		return video;
	}

	// Headset browsers label their cameras, and the world-facing ones are what a
	// marker can be seen with. Tried in turn, back cameras first, because a browser
	// that offers several may hand out an unrelated one for facingMode.
	async function openBackCamera(error, constraints) {
		const devices = await navigator.mediaDevices.enumerateDevices();
		const cameras = devices.filter((device) => device.kind === 'videoinput');
		const back = cameras.filter((device) => /back|rear|environment|world/i.test(device.label) &&
			!/front|user|face|avatar/i.test(device.label));
		if (!cameras.length) {
			throw error || new Error('no camera');
		}
		console.info('Image tracking: ' + back.length + ' of ' + cameras.length + ' cameras face away (' +
			(error && error.message ? error.message : 'facingMode not honoured') + ')');
		let lastError = error;
		for (const device of back.concat(cameras.filter((camera) => !back.includes(camera)))) {
			try {
				return await navigator.mediaDevices.getUserMedia({
					audio: false,
					video: Object.assign({deviceId: {exact: device.deviceId}}, constraints),
				});
			} catch (caught) {
				lastError = caught;
			}
		}
		throw lastError || new Error('no camera');
	}

	// Opened ahead of the XR session, which asks the browser for the world camera
	// itself, so its camera is already running when Godot starts tracking.
	let preparedCamera = null;

	function prepareCamera() {
		if (!preparedCamera) {
			preparedCamera = openCamera(false).catch((error) => {
				preparedCamera = null;
				throw error;
			});
		}
		return preparedCamera;
	}

	function releasePreparedCamera() {
		const pending = preparedCamera;
		preparedCamera = null;
		if (!pending) {
			return;
		}
		pending.then((video) => {
			for (const track of video.srcObject.getTracks()) {
				track.stop();
			}
			video.remove();
		}, () => {});
	}

	// A desktop or headset grants the camera from a gesture; phones keep their own
	// camera access for the session's camera images, which a second client would
	// contend with. Quest's UA has no Android; its browser adds OculusBrowser.
	window.addEventListener('pointerdown', () => {
		if (!/Android/i.test(navigator.userAgent)) {
			prepareCamera().catch(() => {});
		}
	}, {once: true});
	window.addEventListener('pagehide', releasePreparedCamera);

	// The camera's recent orientations, as [time, row-major 3x3 rotation into a fixed
	// frame] in the screen's axes (x right, y up, z out of the screen), which are a
	// phone's back camera's GL axes. MindAR turns what it shows with these while a
	// target is lost, and searches where they say the target went.
	const orientations = [];
	tracking.orientationSource = 'none';

	function noteOrientation(time, rotation) {
		orientations.push([time, rotation]);
		while (time - orientations[0][0] > 1000) {
			orientations.shift();
		}
	}

	// The camera's transform from the orientation nearest time, if there is one
	// close enough to stand for it: column-major 4x4, rotation only.
	function cameraAt(time) {
		let best = null;
		for (const sample of orientations) {
			if (!best || Math.abs(sample[0] - time) < Math.abs(best[0] - time)) {
				best = sample;
			}
		}
		if (!best || Math.abs(best[0] - time) >= 100) {
			return null;
		}
		const r = best[1];
		return [r[0], r[3], r[6], 0, r[1], r[4], r[7], 0, r[2], r[5], r[8], 0, 0, 0, 0, 1];
	}

	function startOrientation() {
		// The fused gyroscope and accelerometer as a quaternion, without the gimbal
		// lock that deviceorientation's angles have with the phone held upright.
		if (typeof RelativeOrientationSensor === 'function') {
			try {
				const sensor = new RelativeOrientationSensor({frequency: 60, referenceFrame: 'screen'});
				sensor.addEventListener('reading', () => {
					const [x, y, z, w] = sensor.quaternion;
					noteOrientation(sensor.timestamp, [
						1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
						2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
						2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
					]);
					tracking.orientationSource = 'sensor';
				});
				sensor.addEventListener('error', () => {
					sensor.stop();
					listenDeviceOrientation();
				});
				sensor.start();
				return;
			} catch (error) {
				// Blocked by a permissions policy or not supported; try the event.
			}
		}
		listenDeviceOrientation();
	}

	function listenDeviceOrientation() {
		const listen = () => window.addEventListener('deviceorientation', (event) => {
			if (event.alpha === null) {
				return;
			}
			// Device to fixed frame, Rz(alpha) Rx(beta) Ry(gamma), then screen to
			// device, Rz(-screen angle).
			const radians = Math.PI / 180;
			const rotation = multiply3(multiply3(multiply3(rotationZ3(event.alpha * radians), rotationX3(event.beta * radians)),
				rotationY3(event.gamma * radians)), rotationZ3(-((screen.orientation && screen.orientation.angle) || 0) * radians));
			noteOrientation(event.timeStamp, rotation);
			tracking.orientationSource = 'deviceorientation';
		});
		// iOS asks first, and only from a tap.
		if (typeof DeviceOrientationEvent !== 'undefined' && typeof DeviceOrientationEvent.requestPermission === 'function') {
			DeviceOrientationEvent.requestPermission().then((state) => state === 'granted' && listen()).catch(() => {});
		} else {
			listen();
		}
	}

	function multiply3(a, b) {
		const out = [];
		for (let row = 0; row < 3; row++) {
			for (let column = 0; column < 3; column++) {
				out.push(a[row * 3] * b[column] + a[row * 3 + 1] * b[3 + column] + a[row * 3 + 2] * b[6 + column]);
			}
		}
		return out;
	}

	function rotationX3(a) {
		return [1, 0, 0, 0, Math.cos(a), -Math.sin(a), 0, Math.sin(a), Math.cos(a)];
	}

	function rotationY3(a) {
		return [Math.cos(a), 0, Math.sin(a), 0, 1, 0, -Math.sin(a), 0, Math.cos(a)];
	}

	function rotationZ3(a) {
		return [Math.cos(a), -Math.sin(a), 0, Math.sin(a), Math.cos(a), 0, 0, 0, 1];
	}

	// MindAR runs in a worker made from this source, which scripts/image_tracking.gd
	// sets before start(). Its GPU reads and shader compiles stall whichever thread
	// runs them, and on the page's thread that made Godot drop frames.
	tracking.library = '';

	function startController() {
		generation += 1;
		const current = generation;
		if (worker) {
			worker.terminate();
		}
		if (!workerUrl) {
			workerUrl = URL.createObjectURL(new Blob([tracking.library], {type: 'text/javascript'}));
		}
		worker = new Worker(workerUrl);
		const width = source.width;
		const height = source.height;
		if (syncDisplay()) {
			capture = makeCanvas(width, height);
			pending = makeCanvas(width, height);
			if (!display) {
				display = makeCanvas(width, height);
				showBehindCanvas(display);
			}
			display.width = width;
			display.height = height;
		}
		tracking.sourceWidth = width;
		tracking.sourceHeight = height;
		tracking.state = 'warming up';
		const settings = {maxTrack: options.maxTrack || 1, profile: profiling};
		if (xr) {
			settings.projectionTransform = xr.projectionTransform;
			settings.worldAnchoring = true;
		}
		for (const key of ['poseFilterMinCutOff', 'poseFilterBeta', 'poseFilterDerivativeCutOff', 'detectionDutyCycle', 'holdTime', 'targetWidths']) {
			if (options[key] !== undefined) {
				settings[key] = options[key];
			}
		}
		Object.assign(settings, JSON.parse(tracking.param('mindar') || '{}'));
		const requestFrame = frameRequester(current);
		worker.onmessage = ({data}) => {
			if (current !== generation) {
				return;
			}
			if (data.type === 'ready') {
				poses = data.dimensions.map(() => null);
				tracking.dimensionsJson = JSON.stringify(data.dimensions);
				tracking.focal = data.focal;
				tracking.state = 'running';
				requestFrame();
			} else if (data.type === 'result') {
				onResult(data);
				requestFrame();
			} else if (data.type === 'inspected') {
				inspections.get(data.id)(data.value);
				inspections.delete(data.id);
			} else if (data.type === 'error') {
				tracking.state = 'error: ' + data.message;
				console.error(data.message);
			}
		};
		worker.postMessage({type: 'start', targets: targetsBuffers.map((buffer) => buffer.slice(0)), width: width, height: height, options: settings});
	}

	// Returns a function that sends the next new camera frame to the worker, stamped
	// with when it was captured and where the camera was. One frame is in flight at
	// a time.
	function frameRequester(current) {
		const send = (bitmap, timestamp, camera) => {
			if (current !== generation) {
				bitmap.close();
				return;
			}
			sentAt = performance.now();
			sentCamera = camera;
			worker.postMessage({type: 'frame', id: frame, bitmap: bitmap, timestamp: timestamp, camera: camera}, [bitmap]);
		};
		if (xr) {
			return () => xr.next(send);
		}
		const video = source instanceof HTMLVideoElement && source.requestVideoFrameCallback ? source : null;
		const next = (callback) => video ? video.requestVideoFrameCallback(callback) : requestAnimationFrame(callback);
		const step = async (now, metadata) => {
			if (current !== generation) {
				return;
			}
			const timestamp = metadata ? (metadata.captureTime || metadata.expectedDisplayTime || now) : now;
			const start = performance.now();
			const bitmap = await createImageBitmap(source);
			if (capture) {
				// Kept to show once its poses come back.
				capture.getContext('2d').drawImage(bitmap, 0, 0);
			}
			record('camera grab', performance.now() - start);
			send(bitmap, timestamp, cameraAt(timestamp));
		};
		return () => next(step);
	}

	function onResult(data) {
		record('worker round trip', performance.now() - sentAt);
		for (const [name, ms] of data.profile) {
			record(name, ms);
		}
		poses = data.poses;
		if (capture) {
			[pending, capture] = [capture, pending];
			pendingReady = true;
		}
		frame += 1;
		tracking.frameJson = JSON.stringify({frame: frame, poses: poses, camera: xr ? sentCamera : null,
			pixelsPerMeter: data.pixelsPerMeter});
	}

	// With ?profile=1, runs the body of an async function in the worker, given
	// {controller, tf}, and resolves to what it returns.
	const inspections = new Map();
	let inspectionId = 0;
	tracking.inspect = function (code) {
		const id = ++inspectionId;
		return new Promise((resolve) => {
			inspections.set(id, resolve);
			worker.postMessage({type: 'inspect', id: id, code: code});
		});
	};

	// Godot calls this in the same frame that it applies the poses from frameJson.
	// With nothing to line up with, the live feed shows instead, since tracked
	// frames come slowly while the worker searches.
	tracking.present = function () {
		layout();
		if (!display) {
			return;
		}
		const live = !poses.some(Boolean);
		if (pendingReady && !live) {
			const start = performance.now();
			display.getContext('2d').drawImage(pending, 0, 0);
			pendingReady = false;
			record('feed present', performance.now() - start);
		}
		if (live !== showingLive) {
			showingLive = live;
			source.style.opacity = live ? '1' : '0';
		}
	};

	function makeCanvas(width, height) {
		const canvas = document.createElement('canvas');
		canvas.width = width;
		canvas.height = height;
		return canvas;
	}

	function decodeBase64(text) {
		const bytes = Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
		return bytes.buffer;
	}

	// targetsJson: the compiled .mind files, as a list of base64. optionsJson: {maxTrack,
	// poseFilterMinCutOff, poseFilterBeta, poseFilterDerivativeCutOff,
	// detectionDutyCycle, holdTime, targetWidths (meters), syntheticImage (PNG as
	// base64), source ('xr' to track the camera of the WebXR session Godot has
	// started, after prepareXR()), referenceSpace (that session's)}.
	tracking.start = function (targetsJson, optionsJson) {
		if (tracking.state !== 'idle' && !tracking.state.startsWith('error')) {
			return;
		}
		tracking.state = 'starting';
		targetsBuffers = JSON.parse(targetsJson).map(decodeBase64);
		options = JSON.parse(optionsJson || '{}');
		let open = openCamera;
		if (options.source === 'xr') {
			open = () => openXR(options.referenceSpace || 'local');
		} else if (tracking.param('source') === 'synthetic') {
			open = openSynthetic;
		} else if (tracking.param('gyro') !== '0') {
			startOrientation();
		}
		open().then((opened) => {
			source = opened;
			return startController();
		}).catch((error) => {
			tracking.state = 'error: ' + (error && error.message ? error.message : String(error));
			console.error(error);
		});
	};

	tracking.stop = function () {
		generation += 1;
		if (worker) {
			worker.terminate();
			worker = null;
		}
		xrFrameHandler = null;
		xr = null;
		// The fallback's feed is a camera of its own, which the session's camera
		// images contend with if it is left running.
		if (source instanceof HTMLVideoElement) {
			if (source.srcObject) {
				for (const track of source.srcObject.getTracks()) {
					track.stop();
				}
			}
			if (!backgrounds.includes(source)) {
				source.remove();
			}
		}
		releasePreparedCamera();
		tracking.cameraMode = '';
		poses = [];
		tracking.frameJson = '';
		tracking.state = 'idle';
	};

	// WebXR: the session's frames are caught on their way to Godot, which asks for
	// each with XRSession.requestAnimationFrame, so its camera images can be tracked.
	let xrSession = null;
	let xrFrameHandler = null;
	// The XR source being tracked, if any.
	let xr = null;
	// MindAR sees the camera image scaled to this many pixels across its short side.
	const XR_FRAME_SIZE = 480;
	// Meters.
	const XR_DEPTH_NEAR = 0.01;

	// ARCore keeps the camera's focus fixed for WebXR, which blurs targets held
	// close, except with Chrome's experimental image tracking (behind the "WebXR
	// Incubations" flag), which turns autofocus on when it is given an image it can
	// track. So immersive-ar sessions ask for it with the target image; browsers
	// without it ignore the request. imageBase64 is a PNG.
	let trackedImage = null;
	tracking.setXRTrackedImage = function (imageBase64, widthInMeters) {
		const bytes = Uint8Array.from(atob(imageBase64), (c) => c.charCodeAt(0));
		createImageBitmap(new Blob([bytes], {type: 'image/png'})).then((image) => {
			trackedImage = {image: image, widthInMeters: widthInMeters};
		});
	};

	// Call before Godot requests its session. Every immersive-ar request then also
	// asks for camera-access, which MindAR needs and which a scene that starts its
	// own session (XR Tools' Enter AR) does not ask for.
	tracking.prepareXR = function () {
		if (typeof XRSession === 'undefined' || XRSession.prototype.shivooCaught) {
			return;
		}
		const requestSession = XRSystem.prototype.requestSession;
		XRSystem.prototype.requestSession = function (mode, init) {
			if (mode === 'immersive-ar') {
				const required = (init && init.requiredFeatures) || [];
				const optional = [...((init && init.optionalFeatures) || [])];
				const extra = {};
				if (!required.includes('camera-access') && !optional.includes('camera-access')) {
					optional.push('camera-access');
				}
				if (trackedImage) {
					optional.push('image-tracking');
					extra.trackedImages = [trackedImage];
				}
				init = Object.assign({}, init, {optionalFeatures: optional}, extra);
			}
			return requestSession.call(this, mode, init);
		};
		const request = XRSession.prototype.requestAnimationFrame;
		XRSession.prototype.requestAnimationFrame = function (callback) {
			const session = this;
			return request.call(session, (time, frame) => {
				// Nothing here may keep the page's own frame from running: the
				// stereo path drives Godot from this callback, and skipping one
				// frame stops the headset loop for good.
				try {
					if (xrSession !== session) {
						xrSession = session;
						session.addEventListener('end', () => {
							if (xrSession === session) {
								xrSession = null;
							}
						});
						// WebXR clips at 10 cm by default, which a small target held close
						// is nearer than. Browsers that refuse it still render.
						try {
							session.updateRenderState({depthNear: XR_DEPTH_NEAR});
						} catch (error) {
							console.warn('Image tracking: depthNear not applied: ' + error);
						}
					}
					if (xrFrameHandler) {
						try {
							xrFrameHandler(time, frame);
						} catch (error) {
							console.error(error);
						}
					}
				} finally {
					callback(time, frame);
				}
			});
		};
		XRSession.prototype.shivooCaught = true;
	};

	// Frames from the camera of Godot's immersive-ar session, which needs the
	// camera-access feature, each with the camera's transform in the session's
	// reference space of type spaceType, the one Godot uses. Resolves once the
	// first camera image says how big the frames are and what lens took them.
	async function openXR(spaceType) {
		for (let waited = 0; !xrSession; waited += 50) {
			if (waited > 5000) {
				throw new Error('no WebXR session');
			}
			await new Promise((resolve) => setTimeout(resolve, 50));
		}
		const session = xrSession;
		const space = await session.requestReferenceSpace(spaceType);
		// No camera-access means no camera images to read, so the world camera has
		// to come from getUserMedia. Deciding here also leaves the session's own GL
		// context and layer alone, which a second XR-compatible context can disturb.
		const features = Array.from(session.enabledFeatures || []);
		const hasCameraImages = features.indexOf('camera-access') >= 0;
		console.info('Image tracking: session features ' + features.join(', ') +
			(hasCameraImages ? '' : '; no camera-access, using getUserMedia'));
		if (!hasCameraImages) {
			return openXRVideo(spaceType);
		}
		// A context of its own, so Godot's GL state is left alone.
		const canvas = document.createElement('canvas');
		const gl = canvas.getContext('webgl2', {xrCompatible: true, alpha: false, antialias: false, depth: false});
		await gl.makeXRCompatible();
		const binding = new XRWebGLBinding(session, gl);
		const program = linkProgram(gl,
			`#version 300 es
			out vec2 uv;
			void main() {
				vec2 position = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
				uv = position;
				gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);
			}`,
			`#version 300 es
			precision mediump float;
			uniform sampler2D image;
			in vec2 uv;
			out vec4 color;
			void main() {
				color = texture(image, uv);
			}`);

		let waiting = null;
		const capture = {
			width: 0,
			height: 0,
			projectionTransform: null,
			// Calls back with (ImageBitmap, timestamp, camera transform) for the next frame.
			next: (callback) => {
				waiting = callback;
			},
		};
		// Headset browsers leave camera-access out, so no view ever has a camera:
		// after a second of frames, take the world camera from getUserMedia instead
		// and keep the session's viewer pose as the camera pose.
		let missingCameraFrames = 0;
		return new Promise((resolve, reject) => {
			const fallback = () => {
				if (capture.width) {
					// The session's own camera images worked; a later failure is not
					// something the browser camera can stand in for mid-session.
					tracking.state = 'error: camera image unavailable';
					return;
				}
				xrFrameHandler = null;
				console.info('Image tracking: no WebXR camera in ' + missingCameraFrames + ' frames');
				openXRVideo(spaceType).then(resolve, reject);
			};
			xrFrameHandler = (time, frame) => {
				const pose = frame.getViewerPose(space);
				const view = pose && pose.views[0];
				if (!view) {
					return;
				}
				if (!view.camera) {
					if (++missingCameraFrames < 20) {
						return;
					}
					fallback();
					return;
				}
				if (!capture.width) {
					const scale = XR_FRAME_SIZE / Math.min(view.camera.width, view.camera.height);
					const width = capture.width = Math.round(view.camera.width * scale);
					const height = capture.height = Math.round(view.camera.height * scale);
					canvas.width = width;
					canvas.height = height;
					// The camera image matches the view, so its projection gives the lens.
					const p = view.projectionMatrix;
					capture.projectionTransform = [
						[p[0] * width / 2, 0, width / 2 * (1 - p[8])],
						[0, p[5] * height / 2, height / 2 * (1 + p[9])],
						[0, 0, 1],
					];
					xr = capture;
					tracking.cameraMode = 'webxr';
					releasePreparedCamera();
					resolve(capture);
				}
				if (!waiting) {
					return;
				}
				const start = performance.now();
				const callback = waiting;
				waiting = null;
				gl.viewport(0, 0, canvas.width, canvas.height);
				gl.useProgram(program);
				gl.activeTexture(gl.TEXTURE0);
				try {
					gl.bindTexture(gl.TEXTURE_2D, binding.getCameraImage(view.camera));
					gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
				} catch (error) {
					// Past the first image, some browsers refuse to hand out more.
					console.error(error);
					waiting = callback;
					fallback();
					return;
				}
				const camera = Array.from(view.transform.matrix);
				createImageBitmap(canvas).then((bitmap) => {
					record('camera grab', performance.now() - start);
					callback(bitmap, time, camera);
				}, (error) => {
					console.error(error);
					waiting = waiting || callback;
				});
			};
		});
	}

	// The world camera through getUserMedia, for browsers whose session gives no
	// camera images (headset browsers leave camera-access out). The session's viewer
	// pose stands in for the camera's pose, so content is placed relative to where
	// the headset is; the camera's offset from the eyes remains.
	async function openXRVideo(spaceType) {
		for (let waited = 0; !xrSession; waited += 50) {
			if (waited > 5000) {
				throw new Error('no WebXR session');
			}
			await new Promise((resolve) => setTimeout(resolve, 50));
		}
		const session = xrSession;
		const space = await session.requestReferenceSpace(spaceType);
		let video;
		if (preparedCamera) {
			try {
				video = await preparedCamera;
			} catch (error) {
				video = await prepareCamera();
			}
		} else {
			video = await prepareCamera();
		}
		if (video.readyState < 1) {
			await new Promise((resolve) => video.addEventListener('loadedmetadata', resolve, {once: true}));
		}
		if (video.paused) {
			await video.play();
		}
		if (!video.videoWidth || !video.videoHeight) {
			throw new Error('camera gave no frames');
		}

		// Where the viewer is, as of the last frame the session rendered.
		let camera = null;
		let waiting = null;
		const capture = {
			width: video.videoWidth,
			height: video.videoHeight,
			projectionTransform: null,
			// Calls back with (ImageBitmap, timestamp, camera transform) for the next frame.
			next: (callback) => {
				waiting = callback;
				schedule();
			},
		};
		const step = async (now, metadata) => {
			const callback = waiting;
			waiting = null;
			if (!callback) {
				return;
			}
			const timestamp = metadata ? (metadata.captureTime || metadata.expectedDisplayTime || now) : now;
			const start = performance.now();
			let bitmap;
			try {
				bitmap = await createImageBitmap(video);
			} catch (error) {
				console.error(error);
				waiting = waiting || callback;
				schedule();
				return;
			}
			record('camera grab', performance.now() - start);
			callback(bitmap, timestamp, camera);
		};
		const schedule = () => {
			if (typeof video.requestVideoFrameCallback === 'function') {
				video.requestVideoFrameCallback(step);
			} else {
				requestAnimationFrame(step);
			}
		};

		return new Promise((resolve, reject) => {
			const timeout = setTimeout(() => {
				xrFrameHandler = null;
				reject(new Error('no XR pose for camera fallback'));
			}, 10000);
			xrFrameHandler = (time, frame) => {
				const pose = frame.getViewerPose(space);
				if (!pose || !pose.views.length) {
					return;
				}
				camera = Array.from(pose.transform.matrix);
				if (capture.projectionTransform) {
					return;
				}
				// The stream is what MindAR sees, so its size stands for the camera's;
				// the view's projection gives the lens.
				const p = pose.views[0].projectionMatrix;
				capture.projectionTransform = [
					[p[0] * capture.width / 2, 0, capture.width / 2 * (1 - p[8])],
					[0, p[5] * capture.height / 2, capture.height / 2 * (1 + p[9])],
					[0, 0, 1],
				];
				xr = capture;
				tracking.cameraMode = 'getusermedia';
				console.info('Image tracking: using getUserMedia camera fallback');
				clearTimeout(timeout);
				resolve(capture);
			};
		});
	}

	// Synthetic feed: the target image on a dark textured background, seen by a
	// camera with MindAR's assumed 45 degree vertical field of view. The target is
	// 1 unit wide; ?speed=2 doubles how fast it moves.
	async function openSynthetic() {
		const image = new Image();
		image.src = 'data:image/png;base64,' + options.syntheticImage;
		await image.decode();

		const canvas = document.createElement('canvas');
		canvas.width = 640;
		canvas.height = 480;
		const gl = canvas.getContext('webgl2', {preserveDrawingBuffer: true, antialias: true});
		const program = linkProgram(gl,
			`#version 300 es
			in vec2 position;
			uniform mat4 mvp;
			uniform vec2 halfSize;
			out vec2 uv;
			void main() {
				uv = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
				gl_Position = mvp * vec4(position * halfSize, 0.0, 1.0);
			}`,
			`#version 300 es
			precision mediump float;
			in vec2 uv;
			uniform sampler2D image;
			out vec4 color;
			void main() { color = texture(image, uv); }`);
		const quad = gl.createBuffer();
		gl.bindBuffer(gl.ARRAY_BUFFER, quad);
		gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
		const texture = gl.createTexture();
		gl.bindTexture(gl.TEXTURE_2D, texture);
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
		gl.generateMipmap(gl.TEXTURE_2D);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);

		const aspect = image.height / image.width;
		const speed = parseFloat(tracking.param('speed') || '1');
		const projection = perspective(45 * Math.PI / 180, canvas.width / canvas.height, 0.05, 100);
		const start = performance.now();
		const draw = () => {
			const t = (performance.now() - start) / 1000 * speed;
			const model = multiply(
				translation(0.35 * Math.sin(t * 0.7), 0.2 * Math.sin(t * 0.9), -2.2 - 0.6 * Math.sin(t * 0.5)),
				multiply(rotationY(0.6 * Math.sin(t * 0.8)), rotationX(0.45 * Math.sin(t * 0.6))));
			gl.viewport(0, 0, canvas.width, canvas.height);
			gl.clearColor(0.18, 0.17, 0.16, 1);
			gl.clear(gl.COLOR_BUFFER_BIT);
			gl.useProgram(program);
			gl.uniformMatrix4fv(gl.getUniformLocation(program, 'mvp'), false, multiply(projection, model));
			gl.uniform2f(gl.getUniformLocation(program, 'halfSize'), 0.5, 0.5 * aspect);
			gl.bindBuffer(gl.ARRAY_BUFFER, quad);
			const position = gl.getAttribLocation(program, 'position');
			gl.enableVertexAttribArray(position);
			gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
			gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
			tracking.truthJson = JSON.stringify({time: t, model: Array.from(model)});
			requestAnimationFrame(draw);
		};
		draw();
		showBehindCanvas(canvas);
		return canvas;
	}

	function linkProgram(gl, vertexSource, fragmentSource) {
		const program = gl.createProgram();
		for (const [type, text] of [[gl.VERTEX_SHADER, vertexSource], [gl.FRAGMENT_SHADER, fragmentSource]]) {
			const shader = gl.createShader(type);
			gl.shaderSource(shader, text);
			gl.compileShader(shader);
			if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
				throw new Error(gl.getShaderInfoLog(shader));
			}
			gl.attachShader(program, shader);
		}
		gl.linkProgram(program);
		return program;
	}

	// Column-major 4x4 matrices, as WebGL expects.
	function multiply(a, b) {
		const out = new Float32Array(16);
		for (let column = 0; column < 4; column++) {
			for (let row = 0; row < 4; row++) {
				let sum = 0;
				for (let k = 0; k < 4; k++) {
					sum += a[k * 4 + row] * b[column * 4 + k];
				}
				out[column * 4 + row] = sum;
			}
		}
		return out;
	}

	function perspective(fovy, aspect, near, far) {
		const f = 1 / Math.tan(fovy / 2);
		return new Float32Array([
			f / aspect, 0, 0, 0,
			0, f, 0, 0,
			0, 0, (far + near) / (near - far), -1,
			0, 0, 2 * far * near / (near - far), 0,
		]);
	}

	function translation(x, y, z) {
		return new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]);
	}

	function rotationX(a) {
		const c = Math.cos(a);
		const s = Math.sin(a);
		return new Float32Array([1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]);
	}

	function rotationY(a) {
		const c = Math.cos(a);
		const s = Math.sin(a);
		return new Float32Array([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]);
	}

	// The element the camera feed (or the synthetic feed) shows in, which draw order
	// puts on top, for capture.js to composite under Godot's canvas.
	tracking.backgroundElement = function () {
		return backgrounds.length ? backgrounds[backgrounds.length - 1] : null;
	};

	window.ShivooImageTracking = tracking;
})();
