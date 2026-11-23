// Finds where a still target is in the room, and so how big it is, from the
// directions it is seen in as WebXR tracks the camera around it: the point the
// rays from each camera position towards it pass closest to. Tracking alone puts
// a target's distance only as right as its assumed size and the camera's focal
// length; the crossing rays need neither, just the camera to have moved sideways.
// Content placed there lines up from every side, as it is drawn with the same
// projection the rays came from.

const MAX_RAYS = 90;
const MIN_RAYS = 10;
// How far the camera has to have moved across the line of sight, root mean
// square, as a share of the target's distance, for the rays to cross steeply
// enough to place it. Tracking gives the directions to well under a thousandth
// of a radian, so this places it to within a few percent.
const MIN_BASELINE = 0.03;
// How closely, root mean square and as a share of the distance, the rays have to
// pass the point for it to count: much further means the target moved.
const MAX_MISS = 0.02;
// Rays missing the point by this share of its distance, this many in a row, mean
// the target has moved, so the rays so far no longer meet.
const MOVED_SHARE = 0.05;
const MOVED_RAYS = 3;

class Triangulator {
  constructor() {
    this.reset();
  }

  reset() {
    this.rays = [];
    this.solution = null;
    this.misses = 0;
  }

  // centre: the target's centre in the camera's GL axes, in target pixels.
  // camera: the camera's transform, as in camera-motion.js.
  add(centre, camera) {
    const origin = [camera[12], camera[13], camera[14]];
    const toward = [0, 1, 2].map((j) => camera[j] * centre[0] + camera[4 + j] * centre[1] + camera[8 + j] * centre[2]);
    const pixels = Math.hypot(...toward);
    const ray = {origin, direction: toward.map((v) => v / pixels), pixels};
    if (this.solution) {
      const {point} = this.solution;
      if (offRay(point, ray) > MOVED_SHARE * distance(point, origin)) {
        if (++this.misses < MOVED_RAYS) return;
        this.reset();
      } else {
        this.misses = 0;
      }
    }
    this.rays.push(ray);
    if (this.rays.length > MAX_RAYS) this.rays.shift();
    this.solution = this._solve();
  }

  // {point (in the room, meters), pixelsPerMeter}, or null until the rays cross
  // at a wide enough angle.
  get() {
    return this.solution;
  }

  _solve() {
    const rays = this.rays;
    if (rays.length < MIN_RAYS) return null;
    // The least squares point: the sum over rays of (I - d d^T) (p - o) = 0.
    const A = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
    const b = [0, 0, 0];
    for (const {origin: o, direction: d} of rays) {
      for (let j = 0; j < 3; j++) {
        for (let i = 0; i < 3; i++) {
          const m = (i === j ? 1 : 0) - d[j] * d[i];
          A[j][i] += m;
          b[j] += m * o[i];
        }
      }
    }
    const point = solve3(A, b);
    if (!point) return null;

    // In front of every camera position, passed closely by the rays, and seen
    // from far enough apart.
    const centroid = [0, 1, 2].map((i) => rays.reduce((s, r) => s + r.origin[i], 0) / rays.length);
    const sight = [0, 1, 2].map((i) => point[i] - centroid[i]);
    const far = Math.hypot(...sight);
    if (!(far > 0)) return null;
    const axis = sight.map((v) => v / far);
    let miss = 0;
    let across = 0;
    for (const ray of rays) {
      const v = [0, 1, 2].map((i) => point[i] - ray.origin[i]);
      if (v[0] * ray.direction[0] + v[1] * ray.direction[1] + v[2] * ray.direction[2] <= 0) return null;
      miss += offRay(point, ray) ** 2;
      const offset = [0, 1, 2].map((i) => ray.origin[i] - centroid[i]);
      const along = offset[0] * axis[0] + offset[1] * axis[1] + offset[2] * axis[2];
      across += offset[0] ** 2 + offset[1] ** 2 + offset[2] ** 2 - along * along;
    }
    if (Math.sqrt(miss / rays.length) > MAX_MISS * far) return null;
    if (Math.sqrt(across / rays.length) < MIN_BASELINE * far) return null;

    // Each ray's length in target pixels is its distance times the scale.
    let both = 0;
    let squared = 0;
    for (const ray of rays) {
      const d = distance(point, ray.origin);
      both += ray.pixels * d;
      squared += d * d;
    }
    return {point, pixelsPerMeter: both / squared};
  }
}

const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);

// How far point is from the line of ray.
const offRay = (point, {origin, direction}) => {
  const v = [point[0] - origin[0], point[1] - origin[1], point[2] - origin[2]];
  const along = v[0] * direction[0] + v[1] * direction[1] + v[2] * direction[2];
  return Math.hypot(v[0] - along * direction[0], v[1] - along * direction[1], v[2] - along * direction[2]);
};

// Cramer's rule, or null for a singular A.
const solve3 = (A, b) => {
  const det = (m) => m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
    m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  const d = det(A);
  if (Math.abs(d) < 1e-12) return null;
  return [0, 1, 2].map((k) => det(A.map((row, j) => row.map((v, i) => (i === k ? b[j] : v)))) / d);
};

export {
  Triangulator,
  offRay,
};
