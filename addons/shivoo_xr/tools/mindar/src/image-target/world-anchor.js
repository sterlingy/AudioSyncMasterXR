import {dot, slerp, quaternionFromMatrix, matrixFromQuaternion} from '../libs/pose-filter.js';
import {offRay} from './triangulator.js';

// Keeps a target where it is in the room, for when the camera's whole transform is
// known (as from WebXR) and the target is expected to stay put. Its centre is held
// at the point triangulated from where the camera has seen it from (see
// Triangulator), or else at the average of where tracking puts it; its orientation
// at the average of the tracked ones. So it stays still as the camera moves around
// it. It counts as moved once the last few lines of sight to it miss where it is
// held by more than a small tolerance, going by the median, so a single bad fit or
// false detection does not move it but steady motion does; then it follows the
// tracked pose, smoothed, until that has stopped, and is held there again.
//
// Poses are MindAR world matrices (column-major, target pixels, the camera's GL
// axes); camera transforms are as in camera-motion.js.

// Positions within tolerance (a share of the target's distance) or this many
// meters, whichever is more, and orientations within this many degrees per 1%
// of tolerance count as the same.
const DEFAULT_TOLERANCE = 0.03;
const MIN_TOLERANCE = 0.005;
const TOLERANCE_DEGREES_PER_PERCENT = 2;
// How far back, in milliseconds, poses are looked at to tell whether the target
// moved, and the fewest that will do.
const MOVE_WINDOW = 250;
const MOVE_SAMPLES = 3;
// How long, in milliseconds, it has to have moved less than half the tolerance
// to be held again.
const SETTLE_WINDOW = 300;
const SETTLE_SAMPLES = 4;
// The most samples the held pose is an average of, so it can still drift to
// follow slow changes such as the camera's tracking settling.
const MAX_SAMPLES = 30;
// A pose this share of the target's distance from the last one is a bad fit
// rather than motion.
const JUMP_SHARE = 0.25;

class WorldAnchor {
  constructor({width, height, blendTime, tolerance=DEFAULT_TOLERANCE}) {
    this.halfWidth = width / 2;
    this.halfHeight = height / 2;
    this.blendTime = blendTime;
    this.toleranceShare = tolerance;
    this.pixelsPerMeter = 0;
    // Where the target's centre is in the room, as triangulated (see
    // Triangulator), which the held pose keeps to while known; tracking alone puts
    // it only as far as the target's assumed size and the camera's focal length.
    this.point = null;
    this.reset();
  }

  reset() {
    // {q, c, distance}: orientation and centre in the room, in meters.
    this.held = null;
    this.samples = 0;
    this.moving = false;
    // Recent poses in the room, with when each was tracked and its line of sight.
    this.recent = [];
    // The last pose passed over as too far from the others, and how many in a row
    // have agreed with it.
    this.jumped = null;
    this.blend = null;
    // The target's size the held pose was placed with, from tracking alone.
    this.heldScale = 0;
  }

  // measured: the pose tracked this frame; followed: the same, smoothed. Returns
  // the pose to show.
  update(time, measured, followed, camera, pixelsPerMeter) {
    const pose = this._toRoom(measured, camera, pixelsPerMeter);
    this.pixelsPerMeter = pixelsPerMeter;
    // Positions in the room from tracking alone depend on the target's size, which
    // may have been measured afresh since it was placed.
    if (!this.held || (!this.point && Math.abs(this.heldScale / pixelsPerMeter - 1) > this.toleranceShare)) {
      const blend = this.blend;
      this.reset();
      this.blend = blend;
      this.held = this.point ? {...pose, c: this.point} : pose;
      this.samples = 1;
      this.heldScale = pixelsPerMeter;
      return this.show(time, camera);
    }
    const tolerance = Math.max(MIN_TOLERANCE, this.toleranceShare * pose.distance);
    // How far a point is from the line of sight to the target this frame, which
    // unlike its distance along it does not depend on the target's size.
    const origin = [camera[12], camera[13], camera[14]];
    const toward = pose.c.map((v, i) => v - origin[i]);
    const length = Math.hypot(...toward);
    const ray = {origin, direction: toward.map((v) => v / length)};
    const last = this.recent.length ? this.recent[this.recent.length - 1].pose : null;
    if (last ? distance(pose.c, last.c) > JUMP_SHARE * pose.distance : offRay(this.held.c, ray) > JUMP_SHARE * pose.distance) {
      // Passed over unless the next few agree it is somewhere else now, as when it
      // was moved while out of view.
      const agrees = this.jumped && distance(pose.c, this.jumped.pose.c) <= 2 * tolerance;
      this.jumped = {pose, count: agrees ? this.jumped.count + 1 : 1};
      if (this.jumped.count >= MOVE_SAMPLES) {
        this.blend = {from: this.held, start: time};
        this.held = pose;
        this.samples = 1;
        this.moving = false;
        this.recent = [{time, pose, ray}];
        this.jumped = null;
      }
      return this.show(time, camera);
    }
    this.jumped = null;
    this.recent.push({time, pose, ray});
    while (time - this.recent[0].time > Math.max(MOVE_WINDOW, SETTLE_WINDOW)) this.recent.shift();
    const toleranceAngle = this.toleranceShare * 100 * TOLERANCE_DEGREES_PER_PERCENT * Math.PI / 180;
    const within = (window) => this.recent.filter((r) => time - r.time <= window);

    if (!this.moving) {
      const lately = within(MOVE_WINDOW);
      const offset = median(lately.map((r) => offRay(this.held.c, r.ray)));
      const turned = median(lately.map((r) => angle(r.pose.q, this.held.q)));
      if (lately.length >= MOVE_SAMPLES && (offset > tolerance || turned > toleranceAngle)) {
        this.moving = true;
        this.blend = {from: this.held, start: time};
      } else {
        this.samples = Math.min(this.samples + 1, MAX_SAMPLES);
        const t = 1 / this.samples;
        this.held = {
          q: slerp(this.held.q, aligned(pose.q, this.held.q), t),
          c: this.point || this.held.c.map((v, i) => v + t * (pose.c[i] - v)),
          distance: pose.distance,
        };
      }
    }
    if (this.moving) {
      this.held = this._toRoom(followed, camera, pixelsPerMeter);
      const lately = within(SETTLE_WINDOW).map((r) => r.pose);
      const spanned = time - this.recent.find((r) => time - r.time <= SETTLE_WINDOW).time;
      if (lately.length >= SETTLE_SAMPLES && spanned >= SETTLE_WINDOW * 0.75) {
        // Averaging the first and last thirds keeps noise from hiding a stop or
        // faking one.
        const third = Math.ceil(lately.length / 3);
        const before = average(lately.slice(0, third));
        const after = average(lately.slice(-third));
        if (distance(before.c, after.c) <= tolerance / 2 && angle(before.q, after.q) <= toleranceAngle / 2) {
          this.held = average(lately);
          this.heldScale = pixelsPerMeter;
          this.samples = lately.length;
          this.moving = false;
        }
      }
    }
    return this.show(time, camera);
  }

  // Eases what is shown over from pose, as seen from camera, across blendTime.
  easeFrom(time, pose, camera, pixelsPerMeter) {
    this.blend = {from: this._toRoom(pose, camera, pixelsPerMeter), start: time};
  }

  // The held pose as seen from camera, or null if there is none.
  show(time, camera) {
    if (!this.held) return null;
    let {q, c} = this.held;
    if (this.blend) {
      const s = (time - this.blend.start) / this.blendTime;
      if (s >= 1) {
        this.blend = null;
      } else {
        const e = s * s * (3 - 2 * s);
        q = slerp(this.blend.from.q, aligned(q, this.blend.from.q), e);
        c = this.blend.from.c.map((v, i) => v + e * (c[i] - v));
      }
    }
    return this._fromRoom(q, c, camera, this.pixelsPerMeter);
  }

  _toRoom(m, camera, pixelsPerMeter) {
    const centre = [0, 1, 2].map((i) => (m[i] * this.halfWidth + m[4 + i] * this.halfHeight + m[12 + i]) / pixelsPerMeter);
    const rotated = new Array(16).fill(0);
    for (const o of [0, 4, 8]) {
      for (let j = 0; j < 3; j++) rotated[o + j] = camera[j] * m[o] + camera[4 + j] * m[o + 1] + camera[8 + j] * m[o + 2];
    }
    return {
      q: quaternionFromMatrix(rotated),
      c: [0, 1, 2].map((j) => camera[j] * centre[0] + camera[4 + j] * centre[1] + camera[8 + j] * centre[2] + camera[12 + j]),
      distance: Math.hypot(...centre),
    };
  }

  _fromRoom(q, c, camera, pixelsPerMeter) {
    const R = matrixFromQuaternion(q);
    const d = [c[0] - camera[12], c[1] - camera[13], c[2] - camera[14]];
    const out = new Array(16).fill(0);
    // Rotations and positions back into the camera's axes: its rotation transposed.
    for (let column = 0; column < 3; column++) {
      for (let row = 0; row < 3; row++) {
        out[column * 4 + row] = camera[row * 4] * R[0][column] + camera[row * 4 + 1] * R[1][column] + camera[row * 4 + 2] * R[2][column];
      }
    }
    for (let row = 0; row < 3; row++) {
      const centre = (camera[row * 4] * d[0] + camera[row * 4 + 1] * d[1] + camera[row * 4 + 2] * d[2]) * pixelsPerMeter;
      out[12 + row] = centre - (out[row] * this.halfWidth + out[4 + row] * this.halfHeight);
    }
    out[15] = 1;
    return out;
  }
}

const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
const aligned = (q, reference) => dot(q, reference) < 0 ? q.map((v) => -v) : q;
const angle = (a, b) => 2 * Math.acos(Math.min(1, Math.abs(dot(a, b))));

const median = (values) => {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted.length ? sorted[sorted.length >> 1] : 0;
};
const average = (poses) => {
  const sum = [0, 0, 0, 0];
  for (const p of poses) aligned(p.q, poses[0].q).forEach((v, i) => { sum[i] += v; });
  const n = Math.hypot(...sum);
  return {
    q: sum.map((v) => v / n),
    c: [0, 1, 2].map((i) => poses.reduce((s, p) => s + p.c[i], 0) / poses.length),
    distance: poses.reduce((s, p) => s + p.distance, 0) / poses.length,
  };
};

export {
  WorldAnchor,
};
