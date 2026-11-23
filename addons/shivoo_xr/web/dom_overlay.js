// Page half of ShivooDOMOverlay. scripts/dom_overlay.gd loads this, installs the
// overlay, and wraps the immersive-ar request so Chrome composites the element.
//
// The project owns the markup and CSS. Controls can emit events declaratively:
//   data-shivoo-event="overlay:ping" data-shivoo-data='{"text":"hi"}'
//   data-shivoo-exit
// Elements with data-shivoo-status and data-shivoo-log are updated here.
// JavaScript can use ShivooDOMOverlay.emit()/end(), and listen for the
// shivoo:godot DOM event; Godot receives page events through the callback set by
// setGodotCallback().
(function () {
	if (window.ShivooDOMOverlay) {
		return;
	}

	const overlay = {
		installed: false,
		// active is true only while the browser is compositing the overlay.
		active: false,
		session: null,
		type: '',
		root: null,
		godotCallback: null,
		options: null,
		// True while a pointer is on the card. surface_tracking.js checks this so
		// a cancelled transient touch (an auxiliary action) cannot drive the scene.
		blockSceneInput: false,
		cardPointerDown: false,
		blockSceneTimer: 0,
	};
	window.ShivooDOMOverlay = overlay;

	function status(text) {
		document.querySelectorAll('[data-shivoo-status]').forEach((node) => {
			node.textContent = text;
		});
	}

	function log(text) {
		document.querySelectorAll('[data-shivoo-log]').forEach((node) => {
			const lines = (node.textContent || '').split('\n').filter((line) => line !== '');
			lines.push(text);
			while (lines.length > 4) {
				lines.shift();
			}
			node.textContent = lines.join('\n');
		});
	}

	function notifyGodot(name, data) {
		if (typeof overlay.godotCallback === 'function') {
			overlay.godotCallback(JSON.stringify({name: name, data: data || {}}));
		}
	}

	function addOverlayFeature(init, root) {
		const features = (init && init.optionalFeatures) || [];
		return Object.assign({}, init, {
			optionalFeatures: features.indexOf('dom-overlay') === -1
				? features.concat('dom-overlay')
				: features,
			domOverlay: {root: root},
		});
	}

	function onSession(session) {
		overlay.session = session;
		overlay.type = session.domOverlayState ? session.domOverlayState.type : '';
		overlay.active = overlay.type !== '';
		if (overlay.options.hideOutsideXr) {
			overlay.root.style.visibility = 'visible';
		}
		status(overlay.type
			? 'Overlay active: ' + overlay.type
			: 'Browser ignored dom-overlay; the session is running without it.');
		log(overlay.type
			? 'Session overlay type: ' + overlay.type
			: 'Session started without a DOM overlay.');
		notifyGodot('shivoo:session-start', {active: overlay.active, type: overlay.type});
		session.addEventListener('end', () => {
			overlay.session = null;
			overlay.active = false;
			overlay.type = '';
			if (overlay.options.hideOutsideXr) {
				overlay.root.style.visibility = 'hidden';
			}
			status('Session ended.');
			log('Session ended.');
			notifyGodot('shivoo:session-end', {});
		});
	}

	function bind(root) {
		root.addEventListener('click', (event) => {
			const target = event.target instanceof Element ? event.target : null;
			if (!target) {
				return;
			}
			const exit = target.closest('[data-shivoo-exit]');
			if (exit && root.contains(exit)) {
				event.preventDefault();
				overlay.end();
				return;
			}
			const source = target.closest('[data-shivoo-event]');
			if (!source || !root.contains(source)) {
				return;
			}
			let data = {};
			const raw = source.getAttribute('data-shivoo-data');
			if (raw) {
				try {
					data = JSON.parse(raw);
				} catch (error) {
					log('Bad data-shivoo-data: ' + raw);
				}
			}
			overlay.emit(source.getAttribute('data-shivoo-event'), data);
		});
		// Taps on the card should not also click the scene behind it. Taps outside
		// the card must reach the scene. Capture on the root as well as bubble:
		// some implementations fire beforexrselect at the control without letting
		// it bubble to the overlay root.
		const suppressSceneSelect = (event) => {
			const target = event.target instanceof Element ? event.target : null;
			if (target && target.closest('.shivoo-card')) {
				event.preventDefault();
				overlay.blockSceneInput = true;
				clearTimeout(overlay.blockSceneTimer);
				if (!overlay.cardPointerDown) {
					overlay.blockSceneTimer = setTimeout(() => {
						overlay.blockSceneInput = false;
					}, 150);
				}
			}
		};
		root.addEventListener('beforexrselect', suppressSceneSelect, true);
		root.addEventListener('beforexrselect', suppressSceneSelect);

		// A cancelled select on a transient input source is still reported as an
		// auxiliary touch. Keep surface tracking off while the card has a pointer.
		const trackCardPointer = (event) => {
			const target = event.target instanceof Element ? event.target : null;
			if (!target || !target.closest('.shivoo-card')) {
				return;
			}
			if (event.type === 'pointerdown') {
				overlay.cardPointerDown = true;
				overlay.blockSceneInput = true;
				clearTimeout(overlay.blockSceneTimer);
			} else {
				overlay.cardPointerDown = false;
				clearTimeout(overlay.blockSceneTimer);
				overlay.blockSceneTimer = setTimeout(() => {
					overlay.blockSceneInput = false;
				}, 150);
			}
		};
		root.addEventListener('pointerdown', trackCardPointer, true);
		root.addEventListener('pointerup', trackCardPointer, true);
		root.addEventListener('pointercancel', trackCardPointer, true);

		if (overlay.options.logInput) {
			const describe = (event) => {
				const target = event.target instanceof Element ? event.target : null;
				const name = target
					? (target.getAttribute('data-shivoo-event') || target.tagName.toLowerCase())
					: '?';
				const pointer = event.pointerType ? ' ' + event.pointerType : '';
				return name + ' x=' + Math.round(event.clientX) + ' y=' + Math.round(event.clientY) + pointer;
			};
			root.addEventListener('pointerdown', (event) => log('Input: down ' + describe(event)));
			root.addEventListener('pointerup', (event) => log('Input: up ' + describe(event)));
			root.addEventListener('click', (event) => log('Input: click ' + describe(event)));
			root.addEventListener('input', (event) => {
				const target = event.target;
				if (!(target instanceof Element) || !('value' in target)) {
					return;
				}
				log('Input: ' + target.tagName.toLowerCase() + ' = ' + target.value);
				const source = target.closest('[data-shivoo-input-event]');
				if (source) {
					overlay.emit(source.getAttribute('data-shivoo-input-event'), {value: target.value});
				}
			});
			root.addEventListener('keydown', (event) => log('Input: key ' + event.key));
		}
	}

	overlay.install = function (optionsJson) {
		if (overlay.installed) {
			return false;
		}
		let options = {};
		try {
			options = JSON.parse(optionsJson || '{}');
		} catch (error) {
			console.error('ShivooDOMOverlay: bad install options', error);
			return false;
		}
		const id = options.id || 'shivoo-dom-overlay';
		let root = document.getElementById(id);
		if (!root) {
			root = document.createElement('div');
			root.id = id;
			document.body.appendChild(root);
		}
		root.classList.add('shivoo-dom-overlay');
		if (options.html) {
			root.innerHTML = options.html;
		}
		if (options.css) {
			const styleId = id + '-styles';
			let style = document.getElementById(styleId);
			if (!style) {
				style = document.createElement('style');
				style.id = styleId;
				document.head.appendChild(style);
			}
			style.textContent = options.css;
		}
		if (options.hideOutsideXr) {
			root.style.visibility = 'hidden';
		}
		overlay.root = root;
		overlay.options = {
			hideOutsideXr: !!options.hideOutsideXr,
			logInput: !!options.logInput,
		};
		bind(root);
		overlay.installed = true;
		status('Waiting for an immersive-ar session.');
		log('Overlay installed.');

		if (typeof XRSystem === 'undefined') {
			status('This browser has no WebXR.');
			return true;
		}
		const requestSession = XRSystem.prototype.requestSession;
		XRSystem.prototype.requestSession = function (mode, init) {
			if (mode === 'immersive-ar') {
				init = addOverlayFeature(init, root);
			}
			const promise = requestSession.call(this, mode, init);
			if (mode === 'immersive-ar') {
				promise.then(onSession).catch((error) => {
					status('requestSession failed: ' + error);
				});
			}
			return promise;
		};
		return true;
	};

	overlay.setGodotCallback = function (callback) {
		overlay.godotCallback = callback || null;
	};

	overlay.emit = function (name, data) {
		const event = {name: name, data: data || {}};
		log('Overlay -> Godot: ' + name + ' ' + JSON.stringify(event.data));
		notifyGodot(name, event.data);
		window.dispatchEvent(new CustomEvent('shivoo:overlay', {detail: event}));
		return event;
	};

	overlay.receive = function (json) {
		let event;
		try {
			event = JSON.parse(json);
		} catch (error) {
			log('Bad Godot event: ' + json);
			return;
		}
		log('Godot -> overlay: ' + event.name + ' ' + JSON.stringify(event.data || {}));
		window.dispatchEvent(new CustomEvent('shivoo:godot', {detail: event}));
	};

	overlay.end = function () {
		if (overlay.session) {
			overlay.session.end();
		}
	};
})();
