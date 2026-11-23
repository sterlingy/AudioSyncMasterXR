// How the camera moved between frames, from transforms that take its GL axes
// (x right, y up, looking down -z) into a fixed frame: column-major 4x4 matrices
// in meters, as WebXR gives them. A gyroscope gives one with no translation.
//
// MindAR poses are in target pixels, so moving them takes the target's pixels
// per meter; with 0 the camera's translation is left out.

// {R, t}: the rigid motion taking coordinates in the camera at transform from to
// those in the camera at transform to, with R a row-major 3x3 array and t in meters.
const relativeMotion = (from, to) => {
  const R = [[], [], []];
  const d = [from[12] - to[12], from[13] - to[13], from[14] - to[14]];
  const t = [];
  for (let j = 0; j < 3; j++) {
    for (let i = 0; i < 3; i++) {
      R[j][i] = to[j * 4] * from[i * 4] + to[j * 4 + 1] * from[i * 4 + 1] + to[j * 4 + 2] * from[i * 4 + 2];
    }
    t[j] = to[j * 4] * d[0] + to[j * 4 + 1] * d[1] + to[j * 4 + 2] * d[2];
  }
  return {R, t};
};

// A MindAR world matrix (column-major, GL axes, target pixels) seen from the camera
// after it moved by motion.
const moveWorldMatrix = (m, {R, t}, pixelsPerMeter) => {
  const out = m.slice();
  for (const o of [0, 4, 8, 12]) {
    for (let j = 0; j < 3; j++) out[o + j] = R[j][0] * m[o] + R[j][1] * m[o + 1] + R[j][2] * m[o + 2];
  }
  for (let j = 0; j < 3; j++) out[12 + j] += t[j] * pixelsPerMeter;
  return out;
};

// A MindAR model-view transform (3x4 rows, computer vision axes: y down, looking
// down +z) seen from the camera after it moved by motion.
const moveModelView = (T, {R, t}, pixelsPerMeter) => {
  const flip = [1, -1, -1];
  const out = [[], [], []];
  for (let j = 0; j < 3; j++) {
    for (let i = 0; i < 4; i++) {
      out[j][i] = 0;
      for (let k = 0; k < 3; k++) out[j][i] += flip[j] * flip[k] * R[j][k] * T[k][i];
    }
    out[j][3] += flip[j] * t[j] * pixelsPerMeter;
  }
  return out;
};

export {
  relativeMotion,
  moveWorldMatrix,
  moveModelView,
};
