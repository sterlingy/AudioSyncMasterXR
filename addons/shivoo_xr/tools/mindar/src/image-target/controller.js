import {memory,nextFrame,env} from '@tensorflow/tfjs';

const tf = {memory,nextFrame,env};
// Polls for GPU reads through postMessage rather than setTimeout, which browsers
// delay by at least 4 ms once it repeats.
tf.env().set('USE_SETTIMEOUTCUSTOM', true);
import ControllerWorker  from "./controller.worker.js?worker&inline";
import {Tracker} from './tracker/tracker.js';
import {CropDetector} from './detector/crop-detector.js';
import {Compiler} from './compiler.js';
import {InputLoader} from './input-loader.js';
import {OneEuroFilter} from '../libs/one-euro-filter.js';
import {PoseFilter} from '../libs/pose-filter.js';
import {predictSearchTransform} from './tracker/motion-model.js';
import {Stabilizer} from './stabilizer.js';
import {Triangulator} from './triangulator.js';
import {relativeMotion, moveModelView} from '../libs/camera-motion.js';
import {buildModelViewProjectionTransform, computeScreenCoordiate} from './estimation/utils.js';

const DEFAULT_FILTER_CUTOFF = 0.001; // 1Hz. time period in milliseconds
const DEFAULT_FILTER_BETA = 1000;
// Frames a newly found target has to keep being tracked before it shows. A wrong
// match rarely survives tracking a frame or two.
const DEFAULT_WARMUP_TOLERANCE = 2;
// How long to keep showing a target after losing it, with and without the
// camera's transform, and how long to ease back once it is found again, in
// milliseconds (see Stabilizer).
const DEFAULT_HOLD_TIME = 1000;
const DEFAULT_BLIND_HOLD_TIME = 250;
const DEFAULT_BLEND_TIME = 300;
// Tracking that finds fewer than this share of a keyframe's features is often
// several pixels out, as through motion blur, so it is not trusted to place the
// target in the room, or to take back a held target, which guesses where to look
// rather than following frame to frame.
const RELIABLE_FEATURE_SHARE = 0.5;
// A pose fitted to fewer features than this can be badly wrong yet fit them, so
// it is taken only if it lands within this share of the target's size on screen
// of where the target was predicted, with its facing turned by at most this many
// degrees.
const CONFIDENT_POINTS = 10;
const MAX_JUMP_SHARE = 0.15;
const MAX_TILT_JUMP = 25;
// For filterMode 'pose': Hz when still, the rise in Hz per focal length per second
// the corners move on screen, and Hz for smoothing that speed.
const DEFAULT_POSE_FILTER_MIN_CUTOFF = 1.0;
const DEFAULT_POSE_FILTER_BETA = 300;
const DEFAULT_POSE_FILTER_DERIVATIVE_CUTOFF = 1.5;
// The most of the time spent detecting while searching, leaving the GPU to the page
// for the rest, and while every target sought is held on show, when tracking from
// where they should be finds them as they come back into view and detecting only
// finds ones that have moved.
const DEFAULT_DETECTION_DUTY_CYCLE = 0.5;
const DEFAULT_HELD_DETECTION_DUTY_CYCLE = 0.1;
// While tracking, how much better the other tilt of the target has to fit to be
// taken (see refineEstimate's mirrorMargin), or 0 not to try it.
const DEFAULT_TRACKING_MIRROR_MARGIN = 0.5;
// How long after losing a target to keep looking where it was, in milliseconds.
const RELOCALIZE_TIME = 2000;

class Controller {
  constructor({inputWidth, inputHeight, onUpdate=null, debugMode=false, maxTrack=1, 
    warmupTolerance=null, holdTime=DEFAULT_HOLD_TIME, blindHoldTime=DEFAULT_BLIND_HOLD_TIME, blendTime=DEFAULT_BLEND_TIME,
    filterMinCF=null, filterBeta=null, motionPrediction=true, trackerOptions={},
    filterMode='pose', poseFilterMinCutOff=DEFAULT_POSE_FILTER_MIN_CUTOFF, poseFilterBeta=DEFAULT_POSE_FILTER_BETA,
    poseFilterDerivativeCutOff=DEFAULT_POSE_FILTER_DERIVATIVE_CUTOFF, detectionDutyCycle=DEFAULT_DETECTION_DUTY_CYCLE,
    heldDetectionDutyCycle=DEFAULT_HELD_DETECTION_DUTY_CYCLE,
    trackingMirrorMargin=DEFAULT_TRACKING_MIRROR_MARGIN, projectionTransform=null, targetWidths=null,
    confidentPoints=CONFIDENT_POINTS, maxJumpShare=MAX_JUMP_SHARE, maxTiltJump=MAX_TILT_JUMP, worldAnchoring=false,
    anchorTolerance=undefined, onProfile=null}) {

    this.inputWidth = inputWidth;
    this.inputHeight = inputHeight;
    this.maxTrack = maxTrack;
    this.filterMinCF = filterMinCF === null? DEFAULT_FILTER_CUTOFF: filterMinCF;
    this.filterBeta = filterBeta === null? DEFAULT_FILTER_BETA: filterBeta;
    this.warmupTolerance = warmupTolerance === null? DEFAULT_WARMUP_TOLERANCE: warmupTolerance;
    this.holdTime = holdTime;
    this.blindHoldTime = blindHoldTime;
    this.blendTime = blendTime;
    this.motionPrediction = motionPrediction;
    this.trackerOptions = trackerOptions;
    this.filterMode = filterMode;
    this.poseFilterMinCutOff = poseFilterMinCutOff;
    this.poseFilterBeta = poseFilterBeta;
    this.poseFilterDerivativeCutOff = poseFilterDerivativeCutOff;
    this.detectionDutyCycle = detectionDutyCycle;
    this.heldDetectionDutyCycle = heldDetectionDutyCycle;
    this.trackingMirrorMargin = trackingMirrorMargin;
    this.confidentPoints = confidentPoints;
    this.maxJumpShare = maxJumpShare;
    this.maxTiltJump = maxTiltJump;
    // Whether targets stay put in the room, so are held still there (see
    // WorldAnchor) when the camera's whole transform is given.
    this.worldAnchoring = worldAnchoring;
    // How far, as a share of its distance, a held target's pose may wander
    // before it counts as moved.
    this.anchorTolerance = anchorTolerance;
    // Each target's printed width in meters, to put the camera's translation in
    // its pixels. Without them only the camera's rotation is used, until the
    // camera's motion shows how big the target is (see Triangulator), which then
    // overrides them in pixelsPerMeter.
    this.targetWidths = targetWidths;
    this.nextDetectTime = 0;
    // Called with (stage name, milliseconds) as each frame is processed.
    this.onProfile = onProfile;
    this.cropDetector = new CropDetector(this.inputWidth, this.inputHeight, debugMode);
    this.inputLoader = new InputLoader(this.inputWidth, this.inputHeight);
    this.markerDimensions = null;
    this.onUpdate = onUpdate;
    this.debugMode = debugMode;
    this.processingVideo = false;
    this.interestedTargetIndex = -1;
    this.trackingStates = [];

    const near = 10;
    const far = 100000;
    const fovy = 45.0 * Math.PI / 180; // 45 in radian. field of view vertical
    const f = (this.inputHeight/2) / Math.tan(fovy/2);
    //     [fx  s cx]
    // K = [ 0 fx cy]
    //     [ 0  0  1]
    // A 45 degree vertical field of view is assumed unless the camera's is known.
    this.projectionTransform = projectionTransform || [
      [f, 0, this.inputWidth / 2],
      [0, f, this.inputHeight / 2],
      [0, 0, 1]
    ];

    this.projectionMatrix = this._glProjectionMatrix({
      projectionTransform: this.projectionTransform,
      width: this.inputWidth,
      height: this.inputHeight,
      near: near,
      far: far,
    });

    this.worker = new ControllerWorker()//new Worker(new URL('./controller.worker.js', import.meta.url));
    this.workerMatchDone = null;
    this.workerTrackDone = null;
    this.worker.onmessage = (e) => {
      if (e.data.type === 'matchDone' && this.workerMatchDone !== null) {
        this.workerMatchDone(e.data);
      }
      if (e.data.type === 'trackUpdateDone' && this.workerTrackDone !== null) {
        this.workerTrackDone(e.data);
      }
    }
  }

  showTFStats() {
    console.log(tf.memory().numTensors);
    console.table(tf.memory());
  }

  addImageTargets(fileURL) {
    return new Promise(async (resolve, reject) => {
      const content = await fetch(fileURL);
      const buffer = await content.arrayBuffer();
      const result = this.addImageTargetsFromBuffer(buffer);
      resolve(result);
    });
  }

  // buffer: a compiled .mind file, or a list of them.
  addImageTargetsFromBuffer(buffer) {
    const compiler = new Compiler();
    const dataList = (Array.isArray(buffer) ? buffer : [buffer]).flatMap((b) => compiler.importData(b));

    const trackingDataList = [];
    const matchingDataList = [];
    const imageListList = [];
    const dimensions = [];
    for (let i = 0; i < dataList.length; i++) {
      matchingDataList.push(dataList[i].matchingData);
      trackingDataList.push(dataList[i].trackingData);
      dimensions.push([dataList[i].targetImage.width, dataList[i].targetImage.height]);
    }

    this.tracker = new Tracker(dimensions, trackingDataList, this.projectionTransform, this.inputWidth, this.inputHeight, this.debugMode, this.trackerOptions);

    this.worker.postMessage({
      type: 'setup',
      inputWidth: this.inputWidth,
      inputHeight: this.inputHeight,
      projectionTransform: this.projectionTransform,
      debugMode: this.debugMode,
      matchingDataList,
    });

    this.markerDimensions = dimensions;

    return {dimensions: dimensions, matchingDataList, trackingDataList};
  }

  dispose() {
    this.stopProcessVideo();
    this.worker.postMessage({
      type: "dispose"
    });
  }

  // warm up gpu - build kernels is slow
  dummyRun(input) {
    const inputT = this.inputLoader.loadInput(input);
    this.cropDetector.detect(inputT);
    this.cropDetector.warmUp(inputT);
    this.tracker.dummyRun(inputT);
    inputT.dispose();
  }

  getProjectionMatrix() {
    return this.projectionMatrix;
  }

  getRotatedZ90Matrix(m) { // rotate 90 degree along z-axis
    // rotation matrix
    // |  0  -1  0  0 |
    // |  1   0  0  0 |
    // |  0   0  1  0 |
    // |  0   0  0  1 |
    const rotatedMatrix = [
      -m[1], m[0], m[2], m[3],
      -m[5], m[4], m[6], m[7],
      -m[9], m[8], m[10], m[11],
      -m[13], m[12], m[14], m[15]
    ];
    return rotatedMatrix;
  }

  // Places the target in the room from where the camera has seen it from (see
  // Triangulator), once it has moved enough, which also gives the target's size.
  _placeInRoom(trackingState, targetIndex, modelViewTransform, camera) {
    const [width, height] = this.markerDimensions[targetIndex];
    const m = this._glModelViewMatrix(modelViewTransform, targetIndex);
    const centre = [0, 1, 2].map((j) => m[j] * width / 2 + m[4 + j] * height / 2 + m[12 + j]);
    trackingState.triangulator.add(centre, camera);
    const solution = trackingState.triangulator.get();
    if (solution) {
      this.pixelsPerMeter[targetIndex] = solution.pixelsPerMeter;
      trackingState.stabilizer.pixelsPerMeter = solution.pixelsPerMeter;
    }
    trackingState.stabilizer.setAnchorPoint(solution && solution.point);
  }

  // Whether enough of the target would be in view to track.
  _onScreen(modelViewTransform, targetIndex) {
    const box = this._screenBox(modelViewTransform, targetIndex);
    return box !== null && box.width > 32 && box.height > 32;
  }

  // The target's bounding box on screen, clipped to the input.
  _screenBox(modelViewTransform, targetIndex) {
    const [w, h] = this.markerDimensions[targetIndex];
    const M = buildModelViewProjectionTransform(this.projectionTransform, modelViewTransform);
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const [x, y] of [[0, 0], [w, 0], [w, h], [0, h]]) {
      const p = computeScreenCoordiate(M, x, y, 0);
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    minX = Math.max(0, minX); minY = Math.max(0, minY);
    maxX = Math.min(this.inputWidth, maxX); maxY = Math.min(this.inputHeight, maxY);
    if (!(maxX > minX && maxY > minY)) return null;
    return {x: minX, y: minY, width: maxX - minX, height: maxY - minY};
  }

  getWorldMatrix(modelViewTransform, targetIndex) {
    return this._glModelViewMatrix(modelViewTransform, targetIndex);
  }

  async _detectAndMatch(inputT, targetIndexes, timestamp) {
    // Look where a target was lost on every other frame for a while, since that
    // is where it most likely is.
    this.detectCount = (this.detectCount || 0) + 1;
    const recent = targetIndexes.map((i) => this.trackingStates[i])
      .filter((s) => s.lastSeenBox && timestamp - s.lastSeenTime < RELOCALIZE_TIME)
      .sort((a, b) => b.lastSeenTime - a.lastSeenTime)[0];
    const started = performance.now();
    const timing = {cpu: 0, wait: 0};
    const {featurePoints} = await (recent && this.detectCount % 2 === 0 ?
      this.cropDetector.detectAround(inputT, recent.lastSeenBox, timing) :
      this.cropDetector.detectMoving(inputT, timing));
    // Rests the GPU for long enough that detecting takes at most its share of the time.
    const finished = performance.now();
    const held = targetIndexes.every((i) => this.trackingStates[i].showing);
    const dutyCycle = held ? Math.min(this.detectionDutyCycle, this.heldDetectionDutyCycle) : this.detectionDutyCycle;
    this.nextDetectTime = finished + (finished - started) * (1 / dutyCycle - 1);
    this._profile('detect cpu', timing.cpu);
    this._profile('detect gpu wait', timing.wait);
    const {targetIndex: matchedTargetIndex, modelViewTransform} = await this._workerMatch(featurePoints, targetIndexes);
    this._profile('match (worker)', performance.now() - finished);
    return {targetIndex: matchedTargetIndex, modelViewTransform}
  }
  // Null if the target was lost, else {modelViewTransform, points, reliable}.
  async _trackAndUpdate(inputT, lastModelViewTransform, targetIndex, searchTransform=null) {
    const timing = {cpu: 0, wait: 0};
    const {worldCoords, screenCoords, featureCount} = await this.tracker.trackAsync(inputT, lastModelViewTransform, targetIndex, searchTransform, timing);
    this._profile('track cpu', timing.cpu);
    this._profile('track gpu wait', timing.wait);
    this.lastTrackedPoints = worldCoords.length;
    if (worldCoords.length < 4) return null;
    const started = performance.now();
    const modelViewTransform = await this._workerTrackUpdate(lastModelViewTransform, {worldCoords, screenCoords});
    this._profile('refine (worker)', performance.now() - started);
    if (modelViewTransform === null) return null;
    return {modelViewTransform, points: worldCoords.length, reliable: worldCoords.length >= RELIABLE_FEATURE_SHARE * featureCount};
  }

  // Whether a tracked pose agrees well enough with the prediction: predicted, a
  // projection of the target (used for its corners), and moved, the last pose
  // turned with the camera (used for which way the target faces).
  _plausible({modelViewTransform, points}, predicted, moved, targetIndex) {
    if (points >= this.confidentPoints) return true;
    const [w, h] = this.markerDimensions[targetIndex];
    const M = buildModelViewProjectionTransform(this.projectionTransform, modelViewTransform);
    const corners = [[0, 0], [w, 0], [w, h], [0, h]];
    const at = corners.map(([x, y]) => computeScreenCoordiate(M, x, y, 0));
    const expected = corners.map(([x, y]) => computeScreenCoordiate(predicted, x, y, 0));
    // Its size as seen, which for a target larger than the view is the view's.
    const size = Math.min(Math.hypot(expected[2].x - expected[0].x, expected[2].y - expected[0].y),
      Math.hypot(this.inputWidth, this.inputHeight));
    const jump = Math.max(...at.map((p, k) => Math.hypot(p.x - expected[k].x, p.y - expected[k].y)));
    if (!(jump <= this.maxJumpShare * size)) return false;
    const T = modelViewTransform;
    const cos = T[0][2] * moved[0][2] + T[1][2] * moved[1][2] + T[2][2] * moved[2][2];
    return cos >= Math.cos(this.maxTiltJump * Math.PI / 180);
  }

  _profile(name, ms) {
    if (this.onProfile) this.onProfile(name, ms);
  }

  resetTracking() {
    this.cropDetector.viewIndex = 0;
    this.detectCount = 0;
    this.nextDetectTime = 0;
    this.trackingStates = [];
    this.pixelsPerMeter = this.markerDimensions.map(([width], i) =>
      this.targetWidths && this.targetWidths[i] > 0 ? width / this.targetWidths[i] : 0);
    for (let i = 0; i < this.markerDimensions.length; i++) {
      const [width, height] = this.markerDimensions[i];
      this.trackingStates.push({
	showing: false,
	isTracking: false,
	currentModelViewTransform: null,
	// The camera's transform when currentModelViewTransform was tracked.
	currentCamera: null,
	trackCount: 0,
	triangulator: new Triangulator(),
	stabilizer: new Stabilizer({
	  filter: this.filterMode === 'matrix' ?
	    new OneEuroFilter({minCutOff: this.filterMinCF, beta: this.filterBeta}) :
	    new PoseFilter({minCutOff: this.poseFilterMinCutOff, beta: this.poseFilterBeta, derivativeCutOff: this.poseFilterDerivativeCutOff, width, height}),
	  width, height, pixelsPerMeter: this.pixelsPerMeter[i],
	  holdTime: this.holdTime, blindHoldTime: this.blindHoldTime, blendTime: this.blendTime, worldAnchoring: this.worldAnchoring,
	  anchorTolerance: this.anchorTolerance,
	}),
      });
    }
  }

  processVideo(input) {
    if (this.processingVideo) return;

    this.processingVideo = true;
    this.resetTracking();

    const startProcessing = async() => {
      while (this.processingVideo) {
	await this.processFrame(input, Date.now());
	await tf.nextFrame();
      }
    }
    startProcessing();
  }

  // Tracks one frame. timestamp is in milliseconds; for video, prefer the frame's
  // capture time over the time it is processed. camera, if known, is the camera's
  // transform when the frame was captured, as in camera-motion.js: from WebXR, or
  // just the rotation from a gyroscope.
  async processFrame(input, timestamp, camera=null) {
    if (this.trackingStates.length !== this.markerDimensions.length) this.resetTracking();

	const frameStart = performance.now();
	const inputT = this.inputLoader.loadInput(input);
	this._profile('camera upload', performance.now() - frameStart);

	const nTracking = this.trackingStates.reduce((acc, s) => {
	  return acc + (!!s.isTracking? 1: 0);
	}, 0);

	// detect and match only if less then maxTrack
	if (nTracking < this.maxTrack && performance.now() >= this.nextDetectTime) {

	  const matchingIndexes = [];
	  for (let i = 0; i < this.trackingStates.length; i++) {
	    const trackingState = this.trackingStates[i];
	    if (trackingState.isTracking === true) continue;
	    if (this.interestedTargetIndex !== -1 && this.interestedTargetIndex !== i) continue;

	    matchingIndexes.push(i);
	  }

	  const {targetIndex: matchedTargetIndex, modelViewTransform} = await this._detectAndMatch(inputT, matchingIndexes, timestamp);

	  if (matchedTargetIndex !== -1) {
	    const trackingState = this.trackingStates[matchedTargetIndex];
	    trackingState.isTracking = true;
	    trackingState.currentModelViewTransform = modelViewTransform;
	    trackingState.currentCamera = camera;
	    trackingState.previousModelViewTransform = null;
	    trackingState.currentTime = timestamp;
	  }
	}

	for (let i = 0; i < this.trackingStates.length; i++) {
	  const trackingState = this.trackingStates[i];
	  // Where a pose tracked from camera transform from is now, if the target
	  // stayed put while the camera moved.
	  const move = (transform, from) => transform && from && camera ?
	    moveModelView(transform, relativeMotion(from, camera), this.pixelsPerMeter[i]) : transform;
	  const moved = move(trackingState.currentModelViewTransform, trackingState.currentCamera);

	  let tracked = null;
	  const continuing = trackingState.isTracking;
	  if (continuing) {
	    // With the camera's motion taken out, what is left is the target's own and
	    // whatever of the camera's the transforms leave out, which keep their pace.
	    const searchTransform = !this.motionPrediction ? null : predictSearchTransform({
	      projectionTransform: this.projectionTransform,
	      markerWidth: this.markerDimensions[i][0],
	      markerHeight: this.markerDimensions[i][1],
	      previous: move(trackingState.previousModelViewTransform, trackingState.previousCamera),
	      current: moved,
	      previousTime: trackingState.previousTime,
	      currentTime: trackingState.currentTime,
	      time: timestamp,
	    });
	    tracked = await this._trackAndUpdate(inputT, moved, i, searchTransform);
	    const predicted = searchTransform || buildModelViewProjectionTransform(this.projectionTransform, moved);
	    if (tracked !== null && !this._plausible(tracked, predicted, moved, i)) {
	      tracked = null;
	    }
	    if (tracked === null) {
	      trackingState.isTracking = false;
	    }
	  } else if (trackingState.showing && moved && this._onScreen(moved, i)) {
	    // Held: tracking from where it should be is far cheaper than detecting.
	    tracked = await this._trackAndUpdate(inputT, moved, i, null);
	    if (tracked && !tracked.reliable) tracked = null;
	    trackingState.isTracking = tracked !== null;
	  }
	  if (tracked !== null) {
	    const {modelViewTransform} = tracked;
	    trackingState.previousModelViewTransform = continuing ? trackingState.currentModelViewTransform : null;
	    trackingState.previousCamera = trackingState.currentCamera;
	    trackingState.previousTime = trackingState.currentTime;
	    trackingState.currentModelViewTransform = modelViewTransform;
	    trackingState.currentCamera = camera;
	    trackingState.currentTime = timestamp;
	    trackingState.lastSeenBox = this._screenBox(modelViewTransform, i);
	    trackingState.lastSeenTime = timestamp;
	    if (camera && tracked.reliable) this._placeInRoom(trackingState, i, modelViewTransform, camera);
	  } else if (!trackingState.isTracking) {
	    trackingState.previousModelViewTransform = null;
	  }

	  // A newly found target shows once it has been tracked for a few frames.
	  if (!trackingState.showing) {
	    trackingState.trackCount = trackingState.isTracking ? trackingState.trackCount + 1 : 0;
	    if (trackingState.trackCount > this.warmupTolerance) {
	      trackingState.showing = true;
	      trackingState.stabilizer.reset();
	    }
	  }

	  if (trackingState.showing) {
	    const worldMatrix = trackingState.isTracking ? this._glModelViewMatrix(trackingState.currentModelViewTransform, i) : null;
	    const shown = trackingState.stabilizer.update(timestamp, worldMatrix, camera);
	    if (!shown) {
	      trackingState.showing = false;
	      trackingState.trackCount = 0;
	      this.onUpdate && this.onUpdate({type: 'updateMatrix', targetIndex: i, worldMatrix: null});
	      continue;
	    }
	    let clone = shown.slice();
	    const isInputRotated = input.width === this.inputHeight && input.height === this.inputWidth;
	    if (isInputRotated) {
	      clone = this.getRotatedZ90Matrix(clone);
	    }
	    this.onUpdate && this.onUpdate({type: 'updateMatrix', targetIndex: i, worldMatrix: clone, rawWorldMatrix: worldMatrix, tracked: trackingState.isTracking, points: this.lastTrackedPoints});
	  }
	}

	inputT.dispose();
	this._profile('whole frame', performance.now() - frameStart);
        this.onUpdate && this.onUpdate({type: 'processDone'});
  }

  stopProcessVideo() {
    this.processingVideo = false;
  }

  async detect(input) {
    const inputT = this.inputLoader.loadInput(input);
    const {featurePoints, debugExtra} = await this.cropDetector.detect(inputT);
    inputT.dispose();
    return {featurePoints, debugExtra};
  }

  async match(featurePoints, targetIndex) {
    const {modelViewTransform, debugExtra} = await this._workerMatch(featurePoints, [targetIndex]);
    return {modelViewTransform, debugExtra};
  }

  async track(input, modelViewTransform, targetIndex) {
    const inputT = this.inputLoader.loadInput(input);
    const result = this.tracker.track(inputT, modelViewTransform, targetIndex);
    inputT.dispose();
    return result;
  }

  async trackUpdate(modelViewTransform, trackFeatures) {
    if (trackFeatures.worldCoords.length < 4 ) return null;
    const modelViewTransform2 = await this._workerTrackUpdate(modelViewTransform, trackFeatures);
    return modelViewTransform2;
  }

  _workerMatch(featurePoints, targetIndexes) {
    return new Promise(async (resolve, reject) => {
      this.workerMatchDone = (data) => {
        resolve({targetIndex: data.targetIndex, modelViewTransform: data.modelViewTransform, debugExtra: data.debugExtra});
      }
      this.worker.postMessage({type: 'match', featurePoints: featurePoints, targetIndexes});
    });
  }

  _workerTrackUpdate(modelViewTransform, trackingFeatures) {
    return new Promise(async (resolve, reject) => {
      this.workerTrackDone = (data) => {
        resolve(data.modelViewTransform);
      }
      const {worldCoords, screenCoords} = trackingFeatures;
      this.worker.postMessage({type: 'trackUpdate', modelViewTransform, worldCoords, screenCoords, mirrorMargin: this.trackingMirrorMargin});
    });
  }

  _glModelViewMatrix(modelViewTransform, targetIndex) {
    const height = this.markerDimensions[targetIndex][1];

    // Question: can someone verify this interpreation is correct? 
    // I'm not very convinced, but more like trial and error and works......
    //
    // First, opengl has y coordinate system go from bottom to top, while the marker corrdinate goes from top to bottom,
    //    since the modelViewTransform is estimated in marker coordinate, we need to apply this transform before modelViewTransform
    //    I can see why y = h - y*, but why z = z* ? should we intepret it as rotate 90 deg along x-axis and then translate y by h?
    //
    //    [1  0  0  0]
    //    [0 -1  0  h]
    //    [0  0 -1  0]
    //    [0  0  0  1]
    //    
    //    This is tested that if we reverse marker coordinate from bottom to top and estimate the modelViewTransform,
    //    then the above matrix is not necessary.
    //
    // Second, in opengl, positive z is away from camera, so we rotate 90 deg along x-axis after transform to fix the axis mismatch
    //    [1  1  0  0]
    //    [0 -1  0  0]
    //    [0  0 -1  0]
    //    [0  0  0  1]
    //
    // all together, the combined matrix is
    //
    //    [1  1  0  0]   [m00, m01, m02, m03]   [1  0  0  0]
    //    [0 -1  0  0]   [m10, m11, m12, m13]   [0 -1  0  h]
    //    [0  0 -1  0]   [m20, m21, m22, m23]   [0  0 -1  0]
    //    [0  0  0  1]   [  0    0    0    1]   [0  0  0  1]
    //
    //    [ m00,  -m01,  -m02,  (m01 * h + m03) ]
    //    [-m10,   m11,   m12, -(m11 * h + m13) ]
    //  = [-m20,   m21,   m22, -(m21 * h + m23) ]
    //    [   0,     0,     0,                1 ]
    //
    //
    // Finally, in threejs, matrix is represented in col by row, so we transpose it, and get below:
    const openGLWorldMatrix = [
      modelViewTransform[0][0], -modelViewTransform[1][0], -modelViewTransform[2][0], 0,
      -modelViewTransform[0][1], modelViewTransform[1][1], modelViewTransform[2][1], 0,
      -modelViewTransform[0][2], modelViewTransform[1][2], modelViewTransform[2][2], 0,
      modelViewTransform[0][1] * height + modelViewTransform[0][3], -(modelViewTransform[1][1] * height + modelViewTransform[1][3]), -(modelViewTransform[2][1] * height + modelViewTransform[2][3]), 1
    ];
    return openGLWorldMatrix;
  }

  // build openGL projection matrix
  // ref: https://strawlab.org/2011/11/05/augmented-reality-with-OpenGL/
  _glProjectionMatrix({projectionTransform, width, height, near, far}) {
    const proj = [
      [2 * projectionTransform[0][0] / width, 0, -(2 * projectionTransform[0][2] / width - 1), 0],
      [0, 2 * projectionTransform[1][1] / height, -(2 * projectionTransform[1][2] / height - 1), 0],
      [0, 0, -(far + near) / (far - near), -2 * far * near / (far - near)],
      [0, 0, -1, 0]
    ];
    const projMatrix = [];
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 4; j++) {
	projMatrix.push(proj[j][i]);
      }
    }
    return projMatrix;
  }
}

export {
 Controller
}
