// Frame-stepped tracking benchmark. Each sequence moves the target along a known
// path at a simulated 30 fps, feeds every frame to the controller, and compares
// the pose it reports with the truth, POT-style (Liang et al. 2018): the error is
// the mean distance between the true and tracked corners of the target, in pixels.
//
// URL parameters:
//   seq=static,orbit   sequences to run (default: all)
//   target=card        web/targets/<target>.mind and .png (default: card)
//   clean=1            no blur, noise or exposure changes
//   blockingReads=1    read the GPU the way the page's worker does
//   gyro=1             give the controller the camera's rotation, as a phone's
//                      gyroscope would
//   xr=1               give it the camera's whole transform, as WebXR would
//   focalError=1.05    tell it a focal length 5% off the real one
//   anything else      passed to the Controller constructor, parsed as JSON
//                      when possible, e.g. filterBeta=500
import {Controller} from '../src/image-target/controller.js';
import {blockReads} from '../src/libs/readback.js';
import {SyntheticCamera, multiply, translation, rotationX, rotationY, rotationZ} from './synthetic.js';

const FPS = 30;
const WIDTH = 640;
const HEIGHT = 480;
const SHUTTER = 0.5 / FPS;
const SUB_FRAMES = 5;
const SUCCESS_PIXELS = 5;
// Height of the point standing in for 3D content, in target widths.
const APEX = 0.5;

const {sin} = Math;
const pose = (x, y, z, yaw, pitch, roll) =>
  multiply(translation(x, y, z), multiply(rotationY(yaw), multiply(rotationX(pitch), rotationZ(roll))));
// The transform of a camera that does not move.
const STILL = Array.from(translation(0, 0, 0));
// The target held still while the camera turns by turn(t) = [yaw, pitch, roll]
// about a point pivot units behind it, as a phone does in a hand. view is the
// camera's transform, in target widths.
const turning = (frames, target, pivot, turn, camera) => ({
  frames,
  camera,
  pose: (t) => {
    const [yaw, pitch, roll] = turn(t);
    return multiply(translation(0, 0, pivot), multiply(rotationZ(-roll), multiply(rotationX(-pitch),
      multiply(rotationY(-yaw), multiply(translation(0, 0, -pivot), target)))));
  },
  view: (t) => {
    const [yaw, pitch, roll] = turn(t);
    return Array.from(multiply(translation(0, 0, pivot), multiply(rotationY(yaw), multiply(rotationX(pitch),
      multiply(rotationZ(roll), translation(0, 0, -pivot))))));
  },
});
// What the controller is told of the camera's transform: a gyroscope gives only
// its rotation, WebXR all of it.
const cameraInput = (sequence, t) => {
  if (!gyro && !xr) return null;
  const view = sequence.view ? sequence.view(t) : STILL;
  return xr ? view : [...view.slice(0, 12), 0, 0, 0, 1];
};
const facing = pose(0.05, -0.03, -2.2, 0.3, -0.25, 0);
// The target fixed in the room while the camera walks around it at radius,
// facing it, at angle(t) about the vertical and bob(t) up and down.
const walking = (frames, radius, angle, bob) => {
  const view = (t) => multiply(rotationY(angle(t)), translation(0, bob(t), radius));
  return {
    frames,
    pose: (t) => multiply(translation(0, -bob(t), -radius), rotationY(-angle(t))),
    view: (t) => Array.from(view(t)),
  };
};
// Up at 0 until start, 1 from start + ramp to end - ramp, back to 0 at end.
const bump = (t, start, end, ramp) => {
  const s = (x) => Math.min(1, Math.max(0, x)) ** 2 * (3 - 2 * Math.min(1, Math.max(0, x)));
  return s((t - start) / ramp) * s((end - t) / ramp);
};
const orbit = (t) => pose(0.35 * sin(0.7 * t), 0.2 * sin(0.9 * t), -2.2 - 0.6 * sin(0.5 * t),
  0.6 * sin(0.8 * t), 0.45 * sin(0.6 * t), 0);

const SEQUENCES = {
  // Held still: everything reported here is jitter.
  static: {frames: 150, pose: () => pose(0.05, -0.03, -2.2, 0.3, -0.25, 0)},
  // Held still, about 360 px wide and off centre: firstFrame is how long finding it takes.
  mid: {frames: 90, pose: () => pose(0.25, 0.12, -1.6, -0.2, 0.15, 0)},
  // Hand tremor of under a degree at 8 to 11 Hz around a fixed pose.
  shake: {frames: 240, pose: (t) => pose(0.05 + 0.004 * sin(9.1 * t), -0.03 + 0.004 * sin(11.3 * t), -2.0,
    0.3 + 0.012 * sin(8.3 * t), -0.25 + 0.012 * sin(10.7 * t), 0.01 * sin(7.7 * t))},
  orbit: {frames: 300, pose: orbit},
  fast: {frames: 300, pose: (t) => orbit(t * 3)},
  // About 120 px wide.
  far: {frames: 240, pose: (t) => pose(0.6 * sin(0.5 * t), 0.4 * sin(0.7 * t), -4.8 - 0.6 * sin(0.4 * t),
    0.4 * sin(0.6 * t), 0.3 * sin(0.5 * t), 0)},
  // Fills most of the frame and sometimes leaves it.
  near: {frames: 240, pose: (t) => pose(0.25 * sin(0.6 * t), 0.15 * sin(0.8 * t), -1.05 - 0.2 * sin(0.5 * t),
    0.35 * sin(0.7 * t), 0.3 * sin(0.5 * t), 0)},
  // Swings out to 66 degrees from face-on.
  oblique: {frames: 300, pose: (t) => pose(0, 0, -2.0, 1.15 * sin(0.5 * t), 0.3 * sin(0.4 * t), 0)},
  // Turns all the way round in the image plane.
  spin: {frames: 300, pose: (t) => pose(0, 0, -2.2, 0.2, 0.2, 0.9 * t)},
  // Swinging the phone around.
  whip: {frames: 240, pose: (t) => orbit(t * 6)},
  // About 75 px wide.
  tiny: {frames: 240, pose: (t) => pose(0.3 * sin(0.5 * t), 0.2 * sin(0.6 * t), -7.5,
    0.3 * sin(0.5 * t), 0.2 * sin(0.4 * t), 0)},
  // Slides in from off screen; firstFrame is how long finding it takes.
  enter: {frames: 150, pose: (t) => pose(Math.min(0, -2.2 + 1.1 * t), 0.1, -2.2, 0.25, -0.2, 0)},
  // A hand passes over it.
  occlude: {frames: 240, pose: (t) => orbit(t * 0.5),
    camera: (t) => ({occluder: [-220 + 110 * t, 150, 170, 400]})},
  // A reflection crosses it, then the exposure drops.
  glare: {frames: 240, pose: (t) => orbit(t * 0.5),
    camera: (t) => ({glare: [100 + 60 * t, 220, 90, 0.9], gain: t < 4 ? 1 : 0.55})},
  lowlight: {frames: 240, pose: orbit, camera: () => ({gain: 0.45, noise: 0.05})},
  // Held still in a dim room: heavy sensor noise, so what is reported is mostly jitter.
  grainy: {frames: 180, pose: () => pose(0.05, -0.03, -2.6, 0.3, -0.25, 0), camera: () => ({gain: 0.4, noise: 0.09})},
  // Out to 75 degrees from face-on.
  steep: {frames: 300, pose: (t) => pose(0, 0, -1.8, 1.32 * sin(0.4 * t), 0.1, 0)},
  // Wider than the view, so only part of it is ever visible.
  closeup: {frames: 240, pose: (t) => pose(0.15 * sin(0.6 * t), 0.08 * sin(0.8 * t), -0.6 - 0.1 * sin(0.5 * t),
    0.25 * sin(0.7 * t), 0.2 * sin(0.5 * t), 0)},
  // The camera looks around a little, turning from the wrist.
  pan: turning(300, facing, 1.5, (t) => [0.25 * sin(0.9 * t), 0.15 * sin(1.3 * t), 0.05 * sin(0.7 * t)]),
  // Shaken from side to side at up to a radian a second.
  swing: turning(240, facing, 1.5, (t) => [0.25 * sin(4 * t), 0.1 * sin(3.1 * t), 0.04 * sin(2.3 * t)]),
  // Walking around it, from 40 degrees one side to the other.
  walk: walking(300, 2.2, (t) => 0.7 * sin(0.5 * t), (t) => 0.06 * sin(1.7 * t)),
  // Turned away until the target is out of view for about half a second, and back.
  glance: turning(180, facing, 1.5, (t) => [0.9 * bump(t, 2, 3, 0.3), 0.1 * bump(t, 2, 3, 0.3), 0]),
};

const params = new URLSearchParams(window.location.search);
const clean = params.get('clean') === '1';
const selected = (params.get('seq') || Object.keys(SEQUENCES).join(',')).split(',');
blockReads(params.get('blockingReads') === '1');
const gyro = params.get('gyro') === '1';
const xr = params.get('xr') === '1';
// How far the focal length the controller is told is from the camera's real one,
// as when the frames tracked are not quite the view shown. Poses are drawn with
// the real one, as the view is.
const focalError = Number(params.get('focalError') || 1);
const FOCAL = (HEIGHT / 2) / Math.tan(22.5 * Math.PI / 180);
// The target is 1 unit wide, and WebXR's transforms are in those units.
const controllerOptions = xr ? {targetWidths: [1], worldAnchoring: true} : {};
if (focalError !== 1) {
  const f = FOCAL * focalError;
  controllerOptions.projectionTransform = [[f, 0, WIDTH / 2], [0, f, HEIGHT / 2], [0, 0, 1]];
}
for (const [key, value] of params) {
  if (['seq', 'clean', 'blockingReads', 'gyro', 'xr', 'target', 'focalError'].includes(key)) continue;
  try {
    controllerOptions[key] = JSON.parse(value);
  } catch {
    controllerOptions[key] = value;
  }
}

const status = document.getElementById('status');
const overlay = document.getElementById('overlay');
const targetPath = `/@fs/${__REPOSITORY__}/web/targets/${params.get('target') || 'card'}`;
const mindUrl = targetPath + '.mind';
const imageUrl = targetPath + '.png';

async function main() {
  const image = new Image();
  image.src = imageUrl;
  await image.decode();
  const camera = new SyntheticCamera(WIDTH, HEIGHT, image);
  document.getElementById('view').prepend(camera.canvas);

  const buffer = await (await fetch(mindUrl)).arrayBuffer();
  // Frames are stepped as fast as they run, so throttling detection by time would
  // only make the frame counts depend on this machine.
  const controller = new Controller({inputWidth: WIDTH, inputHeight: HEIGHT, detectionDutyCycle: 1, heldDetectionDutyCycle: 1,
    ...controllerOptions});
  const {dimensions} = controller.addImageTargetsFromBuffer(buffer);

  camera.render([SEQUENCES.static.pose(0)]);
  controller.dummyRun(camera.canvas);

  const results = {};
  for (const name of selected) {
    status.textContent = `Running ${name}...`;
    results[name] = await runSequence(controller, camera, SEQUENCES[name], dimensions[0]);
  }
  results.overall = overall(Object.values(results));
  window.benchResults = {options: controllerOptions, clean, results};
  status.textContent = 'Done.';
  document.getElementById('results').textContent = formatTable(results);
  console.log(formatTable(results));
}

async function runSequence(controller, camera, sequence, [markerWidth, markerHeight]) {
  controller.resetTracking();
  let reported = null;
  controller.onUpdate = (data) => {
    if (data.type === 'updateMatrix') {
      reported = data.worldMatrix ? {filtered: data.worldMatrix, raw: data.rawWorldMatrix, points: data.points} : null;
    }
  };

  const frames = [];
  for (let i = 0; i < sequence.frames; i++) {
    const t = i / FPS;
    const models = [];
    for (let k = 0; k < SUB_FRAMES && !clean; k++) {
      models.push(sequence.pose(t + (k / (SUB_FRAMES - 1) - 0.5) * SHUTTER));
    }
    if (clean) models.push(sequence.pose(t));
    const conditions = clean ? {} : {gain: 0.92 + 0.08 * sin(1.3 * t), noise: 0.012, seed: (i * 0.618) % 1};
    camera.render(models, {...conditions, ...(sequence.camera ? sequence.camera(t) : {})});

    reported = null;
    const start = performance.now();
    await controller.processFrame(camera.canvas, t * 1000, cameraInput(sequence, t));
    const ms = performance.now() - start;

    const truth = camera.corners(sequence.pose(t), APEX);
    const filtered = reported && markerCorners(reported.filtered, markerWidth, markerHeight);
    const raw = reported && reported.raw && markerCorners(reported.raw, markerWidth, markerHeight);
    frames.push({truth, filtered, raw, ms, points: reported && reported.points, matrix: raw && Array.from(reported.raw), model: Array.from(sequence.pose(t))});
    draw(truth, filtered);
  }
  // For digging into a run from DevTools.
  window.benchFrames = window.benchFrames || {};
  window.benchFrames[selected.find((name) => SEQUENCES[name] === sequence)] = frames;
  // How wide the controller ended up taking the target to be, in target widths.
  const width = controller.pixelsPerMeter[0] ? markerWidth / controller.pixelsPerMeter[0] : NaN;
  return {...summarize(frames), width};
}

// The target's corners from a MindAR world matrix (column-major, target pixels
// with the origin at the bottom-left), in the same order as SyntheticCamera.corners,
// then the point APEX target widths above its centre.
function markerCorners(m, w, h) {
  const f = FOCAL;
  return [[0, h, 0], [w, h, 0], [w, 0, 0], [0, 0, 0], [w / 2, h / 2, APEX * w]].map(([x, y, z]) => {
    const cx = m[0] * x + m[4] * y + m[8] * z + m[12];
    const cy = m[1] * x + m[5] * y + m[9] * z + m[13];
    const cz = m[2] * x + m[6] * y + m[10] * z + m[14];
    return [WIDTH / 2 + f * cx / -cz, HEIGHT / 2 - f * cy / -cz];
  });
}

function apexError(a, b) {
  return Math.hypot(a[4][0] - b[4][0], a[4][1] - b[4][1]);
}

function cornerError(a, b) {
  let sum = 0;
  for (let i = 0; i < 4; i++) sum += Math.hypot(a[i][0] - b[i][0], a[i][1] - b[i][1]);
  return sum / 4;
}

// Shake that is not in the true motion: the RMS second difference of the tracked
// corners minus that of the true corners, over runs of three tracked frames.
function jitter(frames, key, points = [0, 1, 2, 3]) {
  let sum = 0;
  let count = 0;
  for (let i = 2; i < frames.length; i++) {
    const [a, b, c] = [frames[i - 2], frames[i - 1], frames[i]];
    if (!a[key] || !b[key] || !c[key]) continue;
    for (const k of points) {
      for (let d = 0; d < 2; d++) {
        const tracked = c[key][k][d] - 2 * b[key][k][d] + a[key][k][d];
        const truth = c.truth[k][d] - 2 * b.truth[k][d] + a.truth[k][d];
        sum += (tracked - truth) ** 2;
        count++;
      }
    }
  }
  return count ? Math.sqrt(sum / count) : NaN;
}

function summarize(allFrames) {
  // A pose held while the target is out of view is out of view too, and errors
  // there grow without bound towards the edge of the field of view.
  const inView = (truth) => {
    const x = truth.slice(0, 4).reduce((sum, p) => sum + p[0], 0) / 4;
    const y = truth.slice(0, 4).reduce((sum, p) => sum + p[1], 0) / 4;
    return x >= 0 && x <= WIDTH && y >= 0 && y <= HEIGHT;
  };
  const frames = allFrames.filter((f) => !f.filtered || f.raw || inView(f.truth));
  const first = frames.findIndex((f) => f.filtered);
  const shown = frames.filter((f) => f.filtered);
  const errors = shown.map((f) => cornerError(f.filtered, f.truth)).sort((a, b) => a - b);
  const rawErrors = shown.filter((f) => f.raw).map((f) => cornerError(f.raw, f.truth)).sort((a, b) => a - b);
  let lost = 0;
  for (let i = 1; i < frames.length; i++) {
    if (frames[i - 1].filtered && !frames[i].filtered) lost++;
  }
  const ms = frames.map((f) => f.ms).sort((a, b) => a - b);
  return {
    frames: frames.length,
    firstFrame: first,
    tracked: first < 0 ? 0 : shown.length / (frames.length - first),
    lost,
    success: errors.filter((e) => e < SUCCESS_PIXELS).length / frames.length,
    error: percentile(errors, 0.5),
    error95: percentile(errors, 0.95),
    rawError: percentile(rawErrors, 0.5),
    jitter: jitter(frames, 'filtered'),
    rawJitter: jitter(frames, 'raw'),
    apexError: percentile(shown.map((f) => apexError(f.filtered, f.truth)).sort((a, b) => a - b), 0.5),
    apexJitter: jitter(frames, 'filtered', [4]),
    rawApexJitter: jitter(frames, 'raw', [4]),
    ms: ms.reduce((a, b) => a + b, 0) / ms.length,
    ms95: percentile(ms, 0.95),
    trace: allFrames.map((f) => f.filtered ? Math.round(cornerError(f.filtered, f.truth) * 100) / 100 : null),
    rawTrace: allFrames.map((f) => f.raw ? Math.round(cornerError(f.raw, f.truth) * 100) / 100 : null),
    sample: frames[Math.max(0, first) + 10],
  };
}

function overall(list) {
  const mean = (key) => {
    const values = list.map((r) => r[key]).filter((v) => Number.isFinite(v));
    return values.reduce((a, b) => a + b, 0) / values.length;
  };
  const result = {};
  for (const key of Object.keys(list[0])) {
    if (key !== 'trace' && key !== 'rawTrace' && key !== 'sample') result[key] = mean(key);
  }
  result.lost = list.reduce((a, r) => a + r.lost, 0);
  return result;
}

function percentile(sorted, p) {
  if (!sorted.length) return NaN;
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
}

function formatTable(results) {
  const columns = [
    ['success', (v) => (v * 100).toFixed(1) + '%'],
    ['tracked', (v) => (v * 100).toFixed(1) + '%'],
    ['firstFrame', (v) => v.toFixed(0)],
    ['lost', (v) => v.toFixed(0)],
    ['error', (v) => v.toFixed(2)],
    ['error95', (v) => v.toFixed(2)],
    ['rawError', (v) => v.toFixed(2)],
    ['jitter', (v) => v.toFixed(3)],
    ['rawJitter', (v) => v.toFixed(3)],
    ['apexError', (v) => v.toFixed(2)],
    ['apexJitter', (v) => v.toFixed(3)],
    ['rawApexJitter', (v) => v.toFixed(3)],
    ['ms', (v) => v.toFixed(1)],
    ['ms95', (v) => v.toFixed(1)],
    ['width', (v) => v.toFixed(2)],
  ];
  const rows = [['sequence', ...columns.map(([name]) => name)]];
  for (const [name, r] of Object.entries(results)) {
    rows.push([name, ...columns.map(([key, format]) => Number.isFinite(r[key]) ? format(r[key]) : '-')]);
  }
  const widths = rows[0].map((_, i) => Math.max(...rows.map((row) => row[i].length)));
  return rows.map((row) => row.map((cell, i) => cell.padStart(widths[i])).join('  ')).join('\n');
}

function draw(truth, tracked) {
  const context = overlay.getContext('2d');
  context.clearRect(0, 0, WIDTH, HEIGHT);
  const outline = (corners, color) => {
    context.strokeStyle = color;
    context.lineWidth = 2;
    context.beginPath();
    corners.slice(0, 4).forEach(([x, y], i) => (i ? context.lineTo(x, y) : context.moveTo(x, y)));
    context.closePath();
    context.stroke();
  };
  outline(truth, '#3c3');
  if (tracked) outline(tracked, '#f60');
}

main().catch((error) => {
  status.textContent = 'Error: ' + error.message;
  window.benchResults = {error: error.message};
  console.error(error);
});
