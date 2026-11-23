// Page-side half of a HUD's camera button: composites the camera feed and what
// Godot drew into a PNG, or records that composite.
//
// The composite is taken at the end of Godot's own frame, from a hook the Shivoo
// web template calls just before it presents the frame: the engine calls
// ShivooEngine.onFrameEnd, which this file sets. The canvas can still be read
// there whatever its context was made with, and video frames stay in step with
// what Godot draws.
//
// In a WebXR session the same hook puts the camera image the session's
// camera-access feature gives us under the layer Godot rendered into, so photos
// and videos taken in AR show the room as well as the content.
//
// The project's HUD reads this object's fields each frame.
(function () {
	if (window.ShivooCapture) {
		return;
	}

	const MAX_SECONDS = 30;
	// Long edge of a recording: at 30 fps a phone-sized canvas makes files far
	// larger than the video is worth. Photos keep the canvas's own size.
	const MAX_VIDEO_EDGE = 1920;
	const FRAME_INTERVAL = 1000 / 30;
	// Texture units the AR composite samples on, away from the low ones Godot binds.
	const CAMERA_UNIT = 14;
	const LAYER_UNIT = 15;
	// Which way up the camera image and Godot's layer read on a device. Flip the one
	// that comes out upside down; the image tracked in AR is the one to try first.
	const FLIP_CAMERA_Y = false;
	const FLIP_LAYER_Y = false;
	// What to say when the page runs on a template without the end-of-frame hook.
	const NO_HOOK_ERROR = 'Capture needs the Shivoo web template.';
	const XR_ERROR = 'AR capture failed.';

	let compositor = null;
	let context = null;
	let frameArt = null;
	let frameArtLoading = null;
	let recorder = null;
	let recordingStream = null;
	let recordingTrack = null;
	let audioStream = null;
	let chunks = [];
	let startedAt = 0;
	let lastFrameAt = 0;
	let pendingPhoto = false;
	let videoElement = null;
	let pageBackground = '';
	// The AR composite's program and vertex array, built on the first frame that
	// needs them, and the session whose camera-access answer it is cached for.
	let xrDraw = null;
	let xrFeatureSession = null;
	let xrFeatureCamera = false;

	function godotCanvas() {
		return document.getElementById('canvas');
	}

	// The element image_tracking.js shows the camera feed (or the synthetic feed) in.
	function backgroundElement() {
		const tracking = window.ShivooImageTracking;
		return tracking && tracking.backgroundElement ? tracking.backgroundElement() : null;
	}

	// The part of a picture that fills the compositor like object-fit: cover.
	function coverRect(sourceWidth, sourceHeight, width, height) {
		const scale = Math.max(width / sourceWidth, height / sourceHeight);
		return {
			x: (width - sourceWidth * scale) / 2,
			y: (height - sourceHeight * scale) / 2,
			width: sourceWidth * scale,
			height: sourceHeight * scale,
		};
	}

	function ensureCompositor(maxEdge) {
		const canvas = godotCanvas();
		let width = Math.max(1, canvas ? canvas.width : window.innerWidth);
		let height = Math.max(1, canvas ? canvas.height : window.innerHeight);
		if (maxEdge && Math.max(width, height) > maxEdge) {
			const scale = maxEdge / Math.max(width, height);
			// Even sizes: the encoders behind MediaRecorder prefer them.
			width = Math.max(2, Math.round(width * scale / 2) * 2);
			height = Math.max(2, Math.round(height * scale / 2) * 2);
		}
		if (!compositor) {
			compositor = document.createElement('canvas');
			context = compositor.getContext('2d');
		}
		if (compositor.width !== width || compositor.height !== height) {
			compositor.width = width;
			compositor.height = height;
		}
		return compositor;
	}

	// The photo frame comes from Godot as a data URL, which decodes asynchronously,
	// so a photo waits for it rather than going out without its frame.
	function loadFrameArt() {
		if (frameArtLoading) {
			return frameArtLoading;
		}
		frameArtLoading = new Promise(function (resolve) {
			if (!capture.frameUrl) {
				resolve(null);
				return;
			}
			const image = new Image();
			image.onload = function () {
				frameArt = image;
				resolve(image);
			};
			image.onerror = function () {
				resolve(null);
			};
			image.src = capture.frameUrl;
		});
		return frameArtLoading;
	}

	// Draws the camera feed, then what Godot drew over it, then the photo frame. The
	// AR composite is already inside the canvas, so its feed is not drawn again.
	function drawLayers(withFrame) {
		ensureCompositor(capture.mode === 'recording' ? MAX_VIDEO_EDGE : 0);
		const width = compositor.width;
		const height = compositor.height;
		context.setTransform(1, 0, 0, 1, 0, 0);
		context.clearRect(0, 0, width, height);
		context.fillStyle = '#000';
		context.fillRect(0, 0, width, height);
		const background = capture.xr ? null : backgroundElement();
		if (background) {
			const sourceWidth = background.videoWidth || background.width;
			const sourceHeight = background.videoHeight || background.height;
			if (sourceWidth && sourceHeight) {
				const rect = coverRect(sourceWidth, sourceHeight, width, height);
				context.drawImage(background, rect.x, rect.y, rect.width, rect.height);
			}
		}
		const canvas = godotCanvas();
		if (canvas && canvas.width && canvas.height) {
			context.drawImage(canvas, 0, 0, width, height);
		}
		if (withFrame && frameArt) {
			if (frameArt.complete && frameArt.naturalWidth) {
				const rect = coverRect(frameArt.naturalWidth, frameArt.naturalHeight, width, height);
				context.drawImage(frameArt, rect.x, rect.y, rect.width, rect.height);
			}
		}
	}

	function releaseResult() {
		if (capture.resultUrl) {
			URL.revokeObjectURL(capture.resultUrl);
		}
		capture.resultUrl = '';
		capture.resultType = '';
		capture.resultDataUrl = '';
	}

	// Asks for a photo; the next end of frame composes it, so the camera image, the
	// frame Godot drew and the photo frame all come from one instant.
	function photo() {
		if (capture.mode === 'recording' || capture.photoPending) {
			return;
		}
		if (!capture.supported) {
			capture.error = NO_HOOK_ERROR;
			return;
		}
		capture.photoPending = true;
		capture.error = '';
		loadFrameArt().then(function () {
			releaseResult();
			pendingPhoto = true;
		});
	}

	function finishPhoto() {
		drawLayers(true);
		// The picture is in the compositor now: the review can show it while the PNG
		// is encoded, which is the slow half.
		capture.taken += 1;
		capture.photoPending = false;
		compositor.toBlob(function (result) {
			if (!result) {
				capture.error = 'The canvas has no pixels.';
				return;
			}
			const reader = new FileReader();
			reader.onload = function () {
				capture.resultDataUrl = String(reader.result);
				capture.resultUrl = URL.createObjectURL(result);
				capture.resultType = 'image';
			};
			reader.readAsDataURL(result);
		}, 'image/png');
	}

	function pickMimeType() {
		const types = ['video/mp4', 'video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm'];
		for (const type of types) {
			if (window.MediaRecorder && MediaRecorder.isTypeSupported(type)) {
				return type;
			}
		}
		return '';
	}

	function startVideo(withAudio) {
		if (capture.mode === 'recording') {
			return Promise.resolve();
		}
		if (!capture.supported) {
			capture.error = NO_HOOK_ERROR;
			return Promise.resolve();
		}
		releaseResult();
		capture.error = '';
		return requestAudio(withAudio).then(function () {
			if (capture.mode === 'recording') {
				return;
			}
			capture.mode = 'recording';
			drawLayers(false);
			// No frames of its own: onFrameEnd asks for one per drawn frame, so the
			// recording matches what the page shows instead of drifting from it.
			recordingStream = compositor.captureStream(0);
			recordingTrack = recordingStream.getVideoTracks()[0];
			if (audioStream) {
				for (const track of audioStream.getAudioTracks()) {
					recordingStream.addTrack(track);
				}
			}
			const mimeType = pickMimeType();
			chunks = [];
			recorder = new MediaRecorder(recordingStream, mimeType ? {mimeType: mimeType} : undefined);
			capture.mimeType = recorder.mimeType || mimeType;
			recorder.ondataavailable = function (event) {
				if (event.data && event.data.size) {
					chunks.push(event.data);
				}
			};
			recorder.onstop = function () {
				const blob = new Blob(chunks, {type: capture.mimeType || 'video/webm'});
				chunks = [];
				capture.resultUrl = URL.createObjectURL(blob);
				capture.resultType = 'video';
			};
			recorder.start(100);
			startedAt = performance.now();
			lastFrameAt = 0;
			capture.progress = 0;
		});
	}

	function requestAudio(withAudio) {
		if (!withAudio) {
			return Promise.resolve();
		}
		return navigator.mediaDevices.getUserMedia({audio: true}).then(function (stream) {
			audioStream = stream;
		}, function (error) {
			capture.error = String(error);
		});
	}

	function stopVideo() {
		const wasRecording = capture.mode === 'recording';
		capture.mode = 'idle';
		capture.progress = 0;
		if (wasRecording) {
			// The recording is in the recorder: the review can open while it closes
			// the file, which is the slow half.
			capture.taken += 1;
		}
		if (recorder && recorder.state !== 'inactive') {
			recorder.stop();
		}
		recorder = null;
		recordingStream = null;
		recordingTrack = null;
		if (audioStream) {
			for (const track of audioStream.getTracks()) {
				track.stop();
			}
			audioStream = null;
		}
		return wasRecording;
	}

	function hideVideo() {
		if (videoElement) {
			videoElement.remove();
			videoElement = null;
		}
		document.body.style.background = pageBackground;
		document.documentElement.style.background = pageBackground;
	}

	// Godot cannot play MediaRecorder output, so the recording shows in a page element
	// under the canvas, given the review area in CSS pixels.
	function showVideo(left, top, width, height) {
		hideVideo();
		if (!capture.resultUrl || capture.resultType !== 'video') {
			return;
		}
		pageBackground = document.body.style.background;
		videoElement = document.createElement('video');
		videoElement.src = capture.resultUrl;
		videoElement.playsInline = true;
		videoElement.autoplay = true;
		videoElement.loop = true;
		videoElement.muted = true;
		videoElement.style.cssText = 'position:fixed;object-fit:contain;z-index:-1;pointer-events:none;' +
			'left:' + left + 'px;top:' + top + 'px;width:' + width + 'px;height:' + height + 'px;';
		document.body.appendChild(videoElement);
		document.body.style.background = '#000';
		document.documentElement.style.background = '#000';
	}

	async function save(name) {
		if (!capture.resultUrl) {
			return;
		}
		capture.error = '';
		let blob;
		try {
			blob = await (await fetch(capture.resultUrl)).blob();
		} catch (error) {
			capture.error = String(error);
			return;
		}
		const extension = blob.type.indexOf('mp4') >= 0 ? 'mp4' : blob.type.indexOf('webm') >= 0 ? 'webm' : 'png';
		const fileName = (name || 'shivoo') + '.' + extension;
		const file = new File([blob], fileName, {type: blob.type});
		if (navigator.canShare && navigator.canShare({files: [file]})) {
			try {
				await navigator.share({files: [file]});
				return;
			} catch (error) {
				if (error && error.name === 'AbortError') {
					return;
				}
			}
		}
		const link = document.createElement('a');
		link.href = capture.resultUrl;
		link.download = fileName;
		document.body.appendChild(link);
		link.click();
		link.remove();
	}

	// --- AR composite -------------------------------------------------------
	//
	// In a session the page canvas is not what shows, so the composite is drawn on
	// Godot's own context: the layer's texture is opaque and only valid there, and
	// so is the camera image. It is a premultiplied layer over the camera image.
	//
	// Godot's GL state is saved and put back around the draw, because Godot caches
	// some of it in JS (Emscripten's current program, for one) and expects the
	// bindings it left behind.

	const XR_VERTEX_SHADER = `#version 300 es
		out vec2 uv;
		void main() {
			vec2 position = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
			uv = position;
			gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);
		}`;

	const XR_FRAGMENT_SHADER = `#version 300 es
		precision highp float;
		uniform sampler2D uCamera;
		uniform sampler2D uLayer;
		uniform vec4 uCameraRect;
		uniform vec4 uLayerRect;
		uniform float uCameraOn;
		in vec2 uv;
		out vec4 outColor;
		void main() {
			vec4 layer = texture(uLayer, uv * uLayerRect.xy + uLayerRect.zw);
			vec3 camera = vec3(0.0);
			if (uCameraOn > 0.5) {
				camera = texture(uCamera, uv * uCameraRect.xy + uCameraRect.zw).rgb;
			}
			outColor = vec4(layer.rgb + camera * (1.0 - layer.a), 1.0);
		}`;

	// The shader stage's own unit of the composite: where in the layer's or the
	// camera's texture a canvas position reads from, as uv * xy + zw.
	function sourceRect(sourceX, sourceY, sourceWidth, sourceHeight, textureWidth, textureHeight,
			width, height, flipY) {
		const scale = Math.max(width / sourceWidth, height / sourceHeight);
		const left = (width - sourceWidth * scale) / 2;
		const top = (height - sourceHeight * scale) / 2;
		const u = width / (scale * textureWidth);
		const v = height / (scale * textureHeight);
		const offsetU = (sourceX - left / scale) / textureWidth;
		const offsetV = (sourceY - top / scale) / textureHeight;
		if (flipY) {
			return [u, -v, offsetU, v + offsetV];
		}
		return [u, v, offsetU, offsetV];
	}

	function linkProgram(gl, vertexSource, fragmentSource) {
		const program = gl.createProgram();
		for (const stage of [[gl.VERTEX_SHADER, vertexSource], [gl.FRAGMENT_SHADER, fragmentSource]]) {
			const shader = gl.createShader(stage[0]);
			gl.shaderSource(shader, stage[1]);
			gl.compileShader(shader);
			if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
				console.error('ShivooCapture: ' + gl.getShaderInfoLog(shader));
				gl.deleteShader(shader);
				gl.deleteProgram(program);
				return null;
			}
			gl.attachShader(program, shader);
			gl.deleteShader(shader);
		}
		gl.linkProgram(program);
		if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
			console.error('ShivooCapture: ' + gl.getProgramInfoLog(program));
			gl.deleteProgram(program);
			return null;
		}
		return program;
	}

	function xrComposite(gl) {
		if (xrDraw && xrDraw.gl === gl) {
			return xrDraw;
		}
		const program = linkProgram(gl, XR_VERTEX_SHADER, XR_FRAGMENT_SHADER);
		if (!program) {
			return null;
		}
		xrDraw = {
			gl: gl,
			program: program,
			// The vertex shader makes its corners from gl_VertexID, but WebGL2 still
			// wants a vertex array bound to draw.
			vertexArray: gl.createVertexArray(),
			camera: gl.getUniformLocation(program, 'uCamera'),
			layer: gl.getUniformLocation(program, 'uLayer'),
			cameraRect: gl.getUniformLocation(program, 'uCameraRect'),
			layerRect: gl.getUniformLocation(program, 'uLayerRect'),
			cameraOn: gl.getUniformLocation(program, 'uCameraOn'),
		};
		return xrDraw;
	}

	const SAVED_ENABLES = ['BLEND', 'DEPTH_TEST', 'CULL_FACE', 'SCISSOR_TEST', 'STENCIL_TEST', 'DITHER'];
	const SAVED_PARAMETERS = ['BLEND_SRC_RGB', 'BLEND_DST_RGB', 'BLEND_SRC_ALPHA', 'BLEND_DST_ALPHA',
		'BLEND_EQUATION_RGB', 'BLEND_EQUATION_ALPHA', 'COLOR_WRITEMASK', 'DEPTH_WRITEMASK'];

	function saveState(gl) {
		const state = {
			drawFramebuffer: gl.getParameter(gl.DRAW_FRAMEBUFFER_BINDING),
			readFramebuffer: gl.getParameter(gl.READ_FRAMEBUFFER_BINDING),
			program: gl.getParameter(gl.CURRENT_PROGRAM),
			vertexArray: gl.getParameter(gl.VERTEX_ARRAY_BINDING),
			arrayBuffer: gl.getParameter(gl.ARRAY_BUFFER_BINDING),
			viewport: gl.getParameter(gl.VIEWPORT),
			scissorBox: gl.getParameter(gl.SCISSOR_BOX),
			enabled: {},
			parameters: {},
			activeTexture: 0,
			textures: {},
		};
		for (const name of SAVED_ENABLES) {
			state.enabled[name] = gl.isEnabled(gl[name]);
		}
		for (const name of SAVED_PARAMETERS) {
			state.parameters[name] = gl.getParameter(gl[name]);
		}
		// The bound texture is only readable for the active unit, so the units the
		// composite uses are visited one at a time.
		for (const unit of [CAMERA_UNIT, LAYER_UNIT]) {
			gl.activeTexture(gl.TEXTURE0 + unit);
			state.textures[unit] = gl.getParameter(gl.TEXTURE_BINDING_2D);
		}
		state.activeTexture = gl.getParameter(gl.ACTIVE_TEXTURE);
		return state;
	}

	function restoreState(gl, state) {
		gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, state.drawFramebuffer);
		gl.bindFramebuffer(gl.READ_FRAMEBUFFER, state.readFramebuffer);
		gl.bindVertexArray(state.vertexArray);
		gl.bindBuffer(gl.ARRAY_BUFFER, state.arrayBuffer);
		gl.useProgram(state.program);
		for (const unit of Object.keys(state.textures)) {
			gl.activeTexture(gl.TEXTURE0 + Number(unit));
			gl.bindTexture(gl.TEXTURE_2D, state.textures[unit]);
		}
		gl.activeTexture(state.activeTexture);
		gl.viewport(state.viewport[0], state.viewport[1], state.viewport[2], state.viewport[3]);
		gl.scissor(state.scissorBox[0], state.scissorBox[1], state.scissorBox[2], state.scissorBox[3]);
		for (const name of SAVED_ENABLES) {
			if (state.enabled[name]) {
				gl.enable(gl[name]);
			} else {
				gl.disable(gl[name]);
			}
		}
		const p = state.parameters;
		gl.blendFuncSeparate(p.BLEND_SRC_RGB, p.BLEND_DST_RGB, p.BLEND_SRC_ALPHA, p.BLEND_DST_ALPHA);
		gl.blendEquationSeparate(p.BLEND_EQUATION_RGB, p.BLEND_EQUATION_ALPHA);
		gl.colorMask(p.COLOR_WRITEMASK[0], p.COLOR_WRITEMASK[1], p.COLOR_WRITEMASK[2], p.COLOR_WRITEMASK[3]);
		gl.depthMask(p.DEPTH_WRITEMASK);
	}

	// Whether this session lets the page have its camera image, asked once per
	// session because the answer cannot change while it runs.
	function xrCameraAccess(xr) {
		if (xrFeatureSession !== xr.session) {
			xrFeatureSession = xr.session;
			const features = xr.session ? xr.session.enabledFeatures : null;
			xrFeatureCamera = !!features && Array.prototype.indexOf.call(features, 'camera-access') >= 0;
		}
		return xrFeatureCamera;
	}

	// Keeps xrReady current, which the HUD polls to decide whether to show the
	// camera button in a session.
	function refreshXRReady() {
		const engine = window.ShivooEngine;
		const xr = engine && engine.webxr;
		capture.xrReady = !!(xr && xr.session && xr.gl && xr.gl_binding && xr.layer && xr.pose) &&
			xr.pose.views.length === 1 && xr.view_count === 1 && xrCameraAccess(xr);
	}

	// Fills the canvas's framebuffer with the camera image under Godot's layer, so
	// the page can composite it like the flat view's feed.
	function drawXR() {
		const engine = window.ShivooEngine;
		const xr = engine && engine.webxr;
		if (!xr || !xr.session || !xr.gl || !xr.gl_binding || !xr.layer || !xr.pose) {
			return;
		}
		const views = xr.pose.views;
		if (views.length !== 1 || !xrCameraAccess(xr)) {
			return;
		}
		const view = views[0];
		const gl = xr.gl;
		const width = gl.drawingBufferWidth;
		const height = gl.drawingBufferHeight;
		if (!width || !height) {
			return;
		}
		const state = saveState(gl);
		const composite = xrComposite(gl);
		const sub = composite ? xr.gl_binding.getViewSubImage(xr.layer, view) : null;
		if (!sub) {
			restoreState(gl, state);
			return;
		}
		const camera = view.camera ? xr.gl_binding.getCameraImage(view.camera) : null;
		const viewport = sub.viewport;
		const cameraRect = camera ? sourceRect(0, 0, view.camera.width, view.camera.height,
			view.camera.width, view.camera.height, width, height, FLIP_CAMERA_Y) : [1, 0, 0, 0];
		const layerRect = sourceRect(viewport.x, viewport.y, viewport.width, viewport.height,
			sub.colorTextureWidth, sub.colorTextureHeight, width, height, FLIP_LAYER_Y);
		gl.bindFramebuffer(gl.FRAMEBUFFER, null);
		gl.viewport(0, 0, width, height);
		gl.disable(gl.SCISSOR_TEST);
		gl.disable(gl.DEPTH_TEST);
		gl.disable(gl.CULL_FACE);
		gl.disable(gl.STENCIL_TEST);
		gl.disable(gl.BLEND);
		gl.colorMask(true, true, true, true);
		gl.depthMask(false);
		gl.useProgram(composite.program);
		gl.bindVertexArray(composite.vertexArray);
		gl.bindBuffer(gl.ARRAY_BUFFER, null);
		gl.activeTexture(gl.TEXTURE0 + CAMERA_UNIT);
		gl.bindTexture(gl.TEXTURE_2D, camera);
		gl.uniform1i(composite.camera, CAMERA_UNIT);
		gl.uniform4f(composite.cameraRect, cameraRect[0], cameraRect[1], cameraRect[2], cameraRect[3]);
		gl.uniform1f(composite.cameraOn, camera ? 1.0 : 0.0);
		gl.activeTexture(gl.TEXTURE0 + LAYER_UNIT);
		gl.bindTexture(gl.TEXTURE_2D, sub.colorTexture);
		gl.uniform1i(composite.layer, LAYER_UNIT);
		gl.uniform4f(composite.layerRect, layerRect[0], layerRect[1], layerRect[2], layerRect[3]);
		gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
		const error = gl.getError();
		restoreState(gl, state);
		if (error) {
			console.error('ShivooCapture: ' + error);
			capture.error = XR_ERROR;
			capture.xrReady = false;
		}
	}

	// --- end of frame -------------------------------------------------------
	//
	// Idle cost: one null check and a boolean, so nothing runs unless a photo or a
	// recording is waiting for this frame.

	function onFrameEnd() {
		if (capture.xr) {
			refreshXRReady();
		}
		if (!pendingPhoto && capture.mode !== 'recording') {
			return;
		}
		if (pendingPhoto) {
			pendingPhoto = false;
			if (capture.xr) {
				drawXR();
			}
			finishPhoto();
			return;
		}
		if (capture.xr) {
			drawXR();
		}
		drawLayers(false);
		const now = performance.now();
		if (now - lastFrameAt >= FRAME_INTERVAL - 2) {
			lastFrameAt = now;
			if (recordingTrack && recordingTrack.readyState === 'live') {
				recordingTrack.requestFrame();
			}
		}
		capture.progress = Math.min(100, (now - startedAt) / (MAX_SECONDS * 10));
		if (capture.progress >= 100) {
			stopVideo();
		}
	}

	const capture = {
		mode: 'idle',
		progress: 0,
		resultUrl: '',
		resultType: '',
		resultDataUrl: '',
		mimeType: '',
		error: '',
		frameUrl: '',
		// Whether the page runs on a template with the end-of-frame hook; without it
		// there is nothing to compose.
		supported: false,
		// Whether a photo is being composed, so a caller can wait for the result.
		photoPending: false,
		// How many captures the page has composed, photo or recording: the project's
		// HUD opens the review screen when this changes, before the encoding or the
		// recorder's file is finished.
		taken: 0,
		// Whether this session can composite the camera image under Godot's layer;
		// the HUD shows the camera button only when it can.
		xrReady: false,
		xr: false,
		photo: photo,
		startVideo: startVideo,
		stopVideo: stopVideo,
		showVideo: showVideo,
		hideVideo: hideVideo,
		save: save,
		setXR: function (on) {
			capture.xr = !!on;
			capture.xrReady = false;
			xrFeatureSession = null;
		},
		close: function () {
			hideVideo();
			releaseResult();
		},
	};

	if (window.ShivooEngine) {
		window.ShivooEngine.onFrameEnd = onFrameEnd;
	}
	capture.supported = !!(window.ShivooEngine && 'onFrameEnd' in window.ShivooEngine);

	window.ShivooCapture = capture;
})();
