// The One Euro filter (Casiez et al. 2012) applied to a pose rather than to each
// matrix entry: the target's centre is smoothed as a point and its orientation as
// a quaternion, so the result stays a rigid transform.
//
// The cutoff rises with how fast the target's corners move on screen, in focal
// lengths per second (about a screen height). Planar tracking is noisiest in tilt
// and depth, which barely move the corners, so that noise stays smoothed while
// real motion is followed.
//
// Poses are MindAR world matrices: column-major, in target pixels.
import {moveWorldMatrix} from './camera-motion.js';

const smoothing = (dt, cutoff) => {
  const r = 2 * Math.PI * cutoff * dt;
  return r / (r + 1);
};

class PoseFilter {
  // minCutOff: Hz when still; beta: how fast the cutoff rises with speed;
  // derivativeCutOff: Hz, for smoothing the speed itself.
  constructor({minCutOff, beta, derivativeCutOff, width, height}) {
    this.minCutOff = minCutOff;
    this.beta = beta;
    this.derivativeCutOff = derivativeCutOff;
    this.halfWidth = width / 2;
    this.halfHeight = height / 2;
    this.corners = [[0, 0], [width, 0], [width, height], [0, height]];
    this.reset();
  }

  reset() {
    this.previous = null;
  }

  // Moves what the filter remembers as though seen from the camera after it moved
  // by motion (see camera-motion.js), so that only the target's own motion is
  // smoothed and sets the cutoff, not the camera's.
  move(motion, pixelsPerMeter) {
    const previous = this.previous;
    if (!previous) return;
    const moved = moveWorldMatrix(this._compose(previous.q, previous.centre), motion, pixelsPerMeter);
    previous.q = quaternionFromMatrix(moved);
    previous.centre = this._centre(moved);
    previous.raw = moveWorldMatrix(previous.raw, motion, pixelsPerMeter);
    previous.screen = this._screenCorners(previous.raw);
  }

  // time in milliseconds.
  filter(time, m) {
    const q = quaternionFromMatrix(m);
    const centre = this._centre(m);
    const screen = this._screenCorners(m);

    const previous = this.previous;
    if (!previous || !(time > previous.time) || !screen) {
      this.previous = {time, q, centre, screen, velocity: null, raw: m};
      return m;
    }
    const dt = (time - previous.time) / 1000;

    // Each corner's velocity is smoothed before taking its size, as in the One
    // Euro filter, so noise averages out while steady motion does not.
    let velocity = null;
    let speed = 0;
    if (previous.screen) {
      const ad = smoothing(dt, this.derivativeCutOff);
      velocity = screen.map(([x, y], i) => {
        const v = [(x - previous.screen[i][0]) / dt, (y - previous.screen[i][1]) / dt];
        const p = previous.velocity ? previous.velocity[i] : [0, 0];
        return [p[0] + ad * (v[0] - p[0]), p[1] + ad * (v[1] - p[1])];
      });
      for (const [vx, vy] of velocity) speed += Math.hypot(vx, vy) / 4;
    }

    if (dot(q, previous.q) < 0) for (let i = 0; i < 4; i++) q[i] = -q[i];
    const a = smoothing(dt, this.minCutOff + this.beta * speed);
    const filteredCentre = centre.map((c, i) => previous.centre[i] + a * (c - previous.centre[i]));
    const filteredQ = slerp(previous.q, q, a);
    this.previous = {time, q: filteredQ, centre: filteredCentre, screen, velocity, raw: m};
    return this._compose(filteredQ, filteredCentre);
  }

  _centre(m) {
    return [0, 1, 2].map((i) => m[i] * this.halfWidth + m[4 + i] * this.halfHeight + m[12 + i]);
  }

  _compose(q, centre) {
    const R = matrixFromQuaternion(q);
    const out = new Array(16).fill(0);
    for (let column = 0; column < 3; column++) {
      for (let row = 0; row < 3; row++) out[column * 4 + row] = R[row][column];
    }
    for (let i = 0; i < 3; i++) {
      out[12 + i] = centre[i] - (R[i][0] * this.halfWidth + R[i][1] * this.halfHeight);
    }
    out[15] = 1;
    return out;
  }

  // The unfiltered corners in normalised image coordinates (the focal length
  // cancels out of the speed).
  _screenCorners(m) {
    const result = [];
    for (const [x, y] of this.corners) {
      const z = m[2] * x + m[6] * y + m[14];
      if (!(z < 0)) return null;
      result.push([(m[0] * x + m[4] * y + m[12]) / -z, (m[1] * x + m[5] * y + m[13]) / -z]);
    }
    return result;
  }
}

const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];

const slerp = (a, b, t) => {
  const cos = Math.min(1, dot(a, b));
  if (cos > 0.9995) {
    const q = a.map((v, i) => v + t * (b[i] - v));
    const n = Math.hypot(...q);
    return q.map((v) => v / n);
  }
  const angle = Math.acos(cos);
  const sin = Math.sin(angle);
  const wa = Math.sin((1 - t) * angle) / sin;
  const wb = Math.sin(t * angle) / sin;
  return a.map((v, i) => wa * v + wb * b[i]);
};

// [x, y, z, w] from the rotation part of a column-major matrix, normalising its columns.
const quaternionFromMatrix = (m) => {
  const columns = [0, 4, 8].map((o) => {
    const n = Math.hypot(m[o], m[o + 1], m[o + 2]);
    return [m[o] / n, m[o + 1] / n, m[o + 2] / n];
  });
  const r = (row, column) => columns[column][row];
  const trace = r(0, 0) + r(1, 1) + r(2, 2);
  let q;
  if (trace > 0) {
    const s = Math.sqrt(trace + 1) * 2;
    q = [(r(2, 1) - r(1, 2)) / s, (r(0, 2) - r(2, 0)) / s, (r(1, 0) - r(0, 1)) / s, s / 4];
  } else if (r(0, 0) > r(1, 1) && r(0, 0) > r(2, 2)) {
    const s = Math.sqrt(1 + r(0, 0) - r(1, 1) - r(2, 2)) * 2;
    q = [s / 4, (r(0, 1) + r(1, 0)) / s, (r(0, 2) + r(2, 0)) / s, (r(2, 1) - r(1, 2)) / s];
  } else if (r(1, 1) > r(2, 2)) {
    const s = Math.sqrt(1 + r(1, 1) - r(0, 0) - r(2, 2)) * 2;
    q = [(r(0, 1) + r(1, 0)) / s, s / 4, (r(1, 2) + r(2, 1)) / s, (r(0, 2) - r(2, 0)) / s];
  } else {
    const s = Math.sqrt(1 + r(2, 2) - r(0, 0) - r(1, 1)) * 2;
    q = [(r(0, 2) + r(2, 0)) / s, (r(1, 2) + r(2, 1)) / s, s / 4, (r(1, 0) - r(0, 1)) / s];
  }
  const n = Math.hypot(...q);
  return q.map((v) => v / n);
};

const matrixFromQuaternion = ([x, y, z, w]) => [
  [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
];

export {
  PoseFilter,
  dot,
  slerp,
  quaternionFromMatrix,
  matrixFromQuaternion,
};
