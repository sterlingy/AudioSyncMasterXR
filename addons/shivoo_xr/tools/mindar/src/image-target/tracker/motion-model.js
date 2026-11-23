import {buildModelViewProjectionTransform} from '../estimation/utils.js';
import {solveHomography} from '../utils/homography.js';

// Constant-velocity prediction of where the target will appear, so the tracker
// searches where it is likely to be rather than where it was. Extrapolating the
// 6-DoF pose amplifies noise along directions the image barely constrains (depth
// against tilt), so this extrapolates the target's projected corners instead and
// returns the homography through them, for the tracker's search only.

// How many frame intervals ahead to extrapolate at most, for when frames are dropped.
const MAX_STEPS = 2;

const predictSearchTransform = ({projectionTransform, markerWidth, markerHeight, previous, current, previousTime, currentTime, time}) => {
  if (!previous || !(currentTime > previousTime)) return null;
  const steps = Math.min((time - currentTime) / (currentTime - previousTime), MAX_STEPS);
  if (!(steps > 0)) return null;

  const corners = [[0, 0], [markerWidth, 0], [markerWidth, markerHeight], [0, markerHeight]];
  const currentTransform = buildModelViewProjectionTransform(projectionTransform, current);
  const before = project(buildModelViewProjectionTransform(projectionTransform, previous), corners);
  const now = project(currentTransform, corners);
  if (!before || !now) return null;
  const predicted = now.map(([x, y], i) => [x + (x - before[i][0]) * steps, y + (y - before[i][1]) * steps]);

  const H = solveHomography(corners, predicted);
  if (!H) return null;
  // Keep the magnitudes of a real projection: the tracker scales it down by a
  // fixed factor to fit half-float textures on phones.
  const scale = currentTransform[2][3] / H[8];
  return [
    [H[0] * scale, H[1] * scale, 0, H[2] * scale],
    [H[3] * scale, H[4] * scale, 0, H[5] * scale],
    [H[6] * scale, H[7] * scale, 0, H[8] * scale],
  ];
};

const project = (M, points) => {
  const result = [];
  for (const [x, y] of points) {
    const z = M[2][0] * x + M[2][1] * y + M[2][3];
    if (!(z > 0)) return null;
    result.push([(M[0][0] * x + M[0][1] * y + M[0][3]) / z, (M[1][0] * x + M[1][1] * y + M[1][3]) / z]);
  }
  return result;
};

export {
  predictSearchTransform,
};
