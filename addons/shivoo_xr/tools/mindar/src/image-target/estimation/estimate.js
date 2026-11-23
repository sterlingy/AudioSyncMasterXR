import {Matrix, inverse, SingularValueDecomposition, determinant} from 'ml-matrix';
import {solveHomography} from '../utils/homography.js';

// build world matrix with list of matching worldCoords|screenCoords
//
// Step 1. estimate homography with list of pairs
// Ref: https://www.uio.no/studier/emner/matnat/its/TEK5030/v19/lect/lecture_4_3-estimating-homographies-from-feature-correspondences.pdf  (Basic homography estimation from points)
//
// Step 2. decompose homography into rotation and translation matrixes (i.e. world matrix)
// Ref: can anyone provide reference?
const estimate = ({screenCoords, worldCoords, projectionTransform}) => {
  const Harray = solveHomography(worldCoords.map((p) => [p.x, p.y]), screenCoords.map((p) => [p.x, p.y]));
  const H = new Matrix([
    [Harray[0], Harray[1], Harray[2]],
    [Harray[3], Harray[4], Harray[5]],
    [Harray[6], Harray[7], Harray[8]],
  ]);

  const K = new Matrix(projectionTransform);
  const KInv = inverse(K);

  const _KInvH = KInv.mmul(H);
  const KInvH = _KInvH.to1DArray();

  const norm1 = Math.sqrt( KInvH[0] * KInvH[0] + KInvH[3] * KInvH[3] + KInvH[6] * KInvH[6]);
  const norm2 = Math.sqrt( KInvH[1] * KInvH[1] + KInvH[4] * KInvH[4] + KInvH[7] * KInvH[7]);
  const tnorm = (norm1 + norm2) / 2;

  const rotate = [];
  rotate[0] = KInvH[0] / norm1;
  rotate[3] = KInvH[3] / norm1;
  rotate[6] = KInvH[6] / norm1;

  rotate[1] = KInvH[1] / norm2;
  rotate[4] = KInvH[4] / norm2;
  rotate[7] = KInvH[7] / norm2;

  rotate[2] = rotate[3] * rotate[7] - rotate[6] * rotate[4];
  rotate[5] = rotate[6] * rotate[1] - rotate[0] * rotate[7];
  rotate[8] = rotate[0] * rotate[4] - rotate[1] * rotate[3];

  const norm3 = Math.sqrt(rotate[2] * rotate[2] + rotate[5] * rotate[5] + rotate[8] * rotate[8]);
  rotate[2] /= norm3;
  rotate[5] /= norm3;
  rotate[8] /= norm3;

  // The first two columns are only roughly orthogonal. Use the nearest rotation
  // (Zhang 2000, appendix C): refineEstimate only applies rigid updates, so any
  // shear left here would stay in the pose for as long as the target is tracked.
  const svd = new SingularValueDecomposition(new Matrix([
    [rotate[0], rotate[1], rotate[2]],
    [rotate[3], rotate[4], rotate[5]],
    [rotate[6], rotate[7], rotate[8]],
  ]));
  const U = svd.leftSingularVectors;
  const V = svd.rightSingularVectors;
  let R = U.mmul(V.transpose());
  if (determinant(R) < 0) {
    for (let i = 0; i < 3; i++) U.set(i, 2, -U.get(i, 2));
    R = U.mmul(V.transpose());
  }
  for (let i = 0; i < 9; i++) rotate[i] = R.get(Math.floor(i / 3), i % 3);

  const tran = []
  tran[0] = KInvH[2] / tnorm;
  tran[1] = KInvH[5] / tnorm;
  tran[2] = KInvH[8] / tnorm;

  let initialModelViewTransform = [
    [rotate[0], rotate[1], rotate[2], tran[0]],
    [rotate[3], rotate[4], rotate[5], tran[1]],
    [rotate[6], rotate[7], rotate[8], tran[2]]
  ];

  return initialModelViewTransform;
};

export {
  estimate
}
