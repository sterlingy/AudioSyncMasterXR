import * as tf from '@tensorflow/tfjs';
import {buildModelViewProjectionTransform, computeScreenCoordiate} from '../estimation/utils.js';
import {readSync, readAsync} from '../../libs/readback.js';

const AR2_DEFAULT_TS = 6;
const AR2_DEFAULT_TS_GAP = 1;
const AR2_SEARCH_SIZE = 10;
const AR2_SEARCH_GAP = 1;
const AR2_SIM_THRESH = 0.8;

// The compiled tracking keyframes: 0 is 256px on its short side, 1 is 128px.
const DEFAULT_KEYFRAME = 1;
// Switch to the 256px keyframe once the target is this many times bigger on
// screen than the 128px one, and back below the second factor.
const LARGE_KEYFRAME_ENTER = 1.6;
const LARGE_KEYFRAME_EXIT = 1.3;

// For some mobile device, only 16bit floating point texture is supported
//   ref: https://www.tensorflow.org/js/guide/platform_environment#precision
// Empirical results shows that modelViewProjectTransform can go up beyond that, resulting in error
// We get around this by dividing the transform matrix by 1000, and then multiply back inside webgl program
const PRECISION_ADJUST = 1000;

// options:
//   keyframeSelection: track with the 256px keyframe when the target is large on screen.
//   bilinear: warp the input into keyframe space with bilinear filtering over each
//     keyframe pixel's footprint, rather than nearest-neighbour samples.
//   subpixel: refine each match to a fraction of a keyframe pixel by fitting a
//     parabola through the correlation peak and its neighbours.
//   searchRadius: how far from its predicted place to look for each feature, in
//     keyframe pixels.
//   templateRadius: half the size of the patch matched around each feature.
class Tracker {
  constructor(markerDimensions, trackingDataList, projectionTransform, inputWidth, inputHeight, debugMode=false,
    {keyframeSelection=true, bilinear=true, subpixel=true, searchRadius=AR2_SEARCH_SIZE, templateRadius=AR2_DEFAULT_TS}={}) {
    this.searchRadius = searchRadius;
    this.templateRadius = templateRadius;
    this.markerDimensions = markerDimensions;
    this.trackingDataList = trackingDataList;
    this.projectionTransform = projectionTransform;
    this.inputWidth = inputWidth;
    this.inputHeight = inputHeight;
    this.debugMode = debugMode;
    this.keyframeSelection = keyframeSelection;
    this.bilinear = bilinear;
    this.subpixel = subpixel;

    this.levels = keyframeSelection ? [0, 1] : [DEFAULT_KEYFRAME];
    this.keyframeLevels = markerDimensions.map(() => DEFAULT_KEYFRAME);

    // prebuild feature and marker pixel tensors, per keyframe level
    this.prebuilt = {};
    for (const level of this.levels) {
      let maxCount = 0;
      for (let i = 0; i < trackingDataList.length; i++) {
        maxCount = Math.max(maxCount, trackingDataList[i][level].points.length);
      }
      this.prebuilt[level] = trackingDataList.map((data) => this._prebuild(data[level], maxCount));
    }

    this.kernelCaches = {};
  }

  dummyRun(inputT) {
    let transform = [[1,1,1,1], [1,1,1,1], [1,1,1,1]];
    for (let targetIndex = 0; targetIndex < this.markerDimensions.length; targetIndex++) {
      for (const level of this.levels) {
        this._track(inputT, buildModelViewProjectionTransform(this.projectionTransform, transform), targetIndex, level);
      }
    }
  }

  // searchTransform: optional 3x4 target-to-screen projection to search around
  // instead of the one from lastModelViewTransform.
  track(inputImageT, lastModelViewTransform, targetIndex, searchTransform=null) {
    const modelViewProjectionTransform = searchTransform || buildModelViewProjectionTransform(this.projectionTransform, lastModelViewTransform);
    const level = this._selectKeyframe(modelViewProjectionTransform, targetIndex);
    return this._track(inputImageT, modelViewProjectionTransform, targetIndex, level);
  }

  // Like track, but waits for the GPU without blocking the page.
  trackAsync(inputImageT, lastModelViewTransform, targetIndex, searchTransform=null, timing=null) {
    const modelViewProjectionTransform = searchTransform || buildModelViewProjectionTransform(this.projectionTransform, lastModelViewTransform);
    const level = this._selectKeyframe(modelViewProjectionTransform, targetIndex);
    return readAsync(this._trackSteps(inputImageT, modelViewProjectionTransform, targetIndex, level), timing);
  }

  _track(inputImageT, modelViewProjectionTransform, targetIndex, level) {
    return readSync(this._trackSteps(inputImageT, modelViewProjectionTransform, targetIndex, level));
  }

  // Yields the tensors it needs read back and is resumed with their values.
  *_trackSteps(inputImageT, modelViewProjectionTransform, targetIndex, level) {
    let debugExtra = {};

    const modelViewProjectionTransformT = this._buildAdjustedModelViewTransform(modelViewProjectionTransform);

    const trackingFrame = this.trackingDataList[targetIndex][level];
    const {featurePoints: featurePointsT, imagePixels: imagePixelsT, imageProperties: imagePropertiesT} = this.prebuilt[level][targetIndex];

    const projectedImageT = this._computeProjection(modelViewProjectionTransformT, inputImageT, trackingFrame);

    // Positions and similarities together, as each read is a round trip to the GPU.
    const matchesT = this._computeMatching(featurePointsT, imagePixelsT, imagePropertiesT, projectedImageT);

    const [matches] = yield [matchesT];

    const worldCoords = [];
    const screenCoords = [];
    const goodTrack = [];

    // With sub-pixel matching, a keyframe pixel stands for the centre of the
    // target pixels it was averaged from, with pixel j covering [j, j + 1].
    const offset = this.subpixel ? 0.5 / trackingFrame.scale : 0;
    for (let i = 0; i < matches.length; i++) {
      if (matches[i][2] > AR2_SIM_THRESH && i < trackingFrame.points.length) {
	goodTrack.push(i);
	const point = computeScreenCoordiate(modelViewProjectionTransform, matches[i][0], matches[i][1]);
	screenCoords.push(point);
	worldCoords.push({x: trackingFrame.points[i].x / trackingFrame.scale + offset, y: trackingFrame.points[i].y / trackingFrame.scale + offset, z: 0});
      }
    }

    if (this.debugMode) {
      debugExtra = {
	projectedImage: projectedImageT.arraySync(),
	matchingPoints: matches,
	goodTrack,
	trackedPoints: screenCoords
      }
    }

    // tensors cleanup
    modelViewProjectionTransformT.dispose();
    projectedImageT.dispose();
    matchesT.dispose();

    return {worldCoords, screenCoords, featureCount: trackingFrame.points.length, debugExtra};
  }

  // Picks the keyframe closest in scale to how big the target appears.
  _selectKeyframe(M, targetIndex) {
    if (!this.keyframeSelection) return DEFAULT_KEYFRAME;
    const [w, h] = this.markerDimensions[targetIndex];
    const o = computeScreenCoordiate(M, 0, 0, 0);
    const x = computeScreenCoordiate(M, w, 0, 0);
    const y = computeScreenCoordiate(M, 0, h, 0);
    const screenScale = Math.sqrt(Math.hypot(x.x - o.x, x.y - o.y) / w * Math.hypot(y.x - o.x, y.y - o.y) / h);
    const small = this.trackingDataList[targetIndex][1].scale;
    const current = this.keyframeLevels[targetIndex];
    const threshold = current === 0 ? LARGE_KEYFRAME_EXIT : LARGE_KEYFRAME_ENTER;
    const level = screenScale > small * threshold ? 0 : 1;
    this.keyframeLevels[targetIndex] = level;
    return level;
  }

  _computeMatching(featurePointsT, imagePixelsT, imagePropertiesT, projectedImageT) {
    const templateOneSize = this.templateRadius;
    const templateSize = templateOneSize * 2 + 1;
    const templateGap = AR2_DEFAULT_TS_GAP;
    const searchOneSize = this.searchRadius * templateGap;
    const searchGap = AR2_SEARCH_GAP;
    const searchSize = searchOneSize * 2 + 1;
    const targetHeight = projectedImageT.shape[0];
    const targetWidth = projectedImageT.shape[1];
    const featureCount = featurePointsT.shape[0];

    // The shaders bake in these sizes.
    const kernelKey = featureCount + "-" + targetWidth + "-" + targetHeight;
    if (!this.kernelCaches.computeMatching) this.kernelCaches.computeMatching = {};

    if (!this.kernelCaches.computeMatching[kernelKey]) {
      const kernel1 = {
	variableNames: ['features', 'markerPixels', 'markerProperties', 'targetPixels'],
	outputShape: [featureCount, searchSize * searchSize],
	userCode: `
	  void main() {
	    ivec2 coords = getOutputCoords();

	    int featureIndex = coords[0];
	    int searchOffsetIndex = coords[1];

	    int markerWidth = int(getMarkerProperties(0));
	    int markerHeight = int(getMarkerProperties(1));
	    float markerScale = getMarkerProperties(2);

	    int searchOffsetX = imod(searchOffsetIndex, ${searchSize}) * ${searchGap};
	    int searchOffsetY = searchOffsetIndex / ${searchSize} * ${searchGap};

	    int sCenterX = int(floor(getFeatures(featureIndex, 0) * markerScale + 0.5));
	    int sCenterY = int(floor(getFeatures(featureIndex, 1) * markerScale + 0.5));

	    int sx = sCenterX + searchOffsetX - ${searchOneSize};
	    int sy = sCenterY + searchOffsetY - ${searchOneSize};

	    if (sx < ${templateOneSize} || sx >= (${targetWidth} - ${templateOneSize}) || sy < ${templateOneSize} || sy >= (${targetHeight} - ${templateOneSize})) {
	      setOutput(-2.);
	    } 
	    else {
	      float sumPoint = 0.;
	      float sumPointSquare = 0.;
	      float sumTemplate = 0.;
	      float sumTemplateSquare = 0.;
	      float sumPointTemplate = 0.;

	      for (int templateOffsetY = 0; templateOffsetY < ${templateSize}; templateOffsetY++) {
		for (int templateOffsetX = 0; templateOffsetX < ${templateSize}; templateOffsetX++) {
		  int fx2 = sCenterX + templateOffsetX - ${templateOneSize};
		  int fy2 = sCenterY + templateOffsetY - ${templateOneSize};

		  int sx2 = sx + templateOffsetX - ${templateOneSize};
		  int sy2 = sy + templateOffsetY - ${templateOneSize};

		  int markerPixelIndex = fy2 * markerWidth + fx2;
		  float markerPixel = getMarkerPixels(markerPixelIndex);
		  float targetPixel = getTargetPixels(sy2, sx2);

		  sumTemplate += markerPixel;
		  sumTemplateSquare += markerPixel * markerPixel;
		  sumPoint += targetPixel;
		  sumPointSquare += targetPixel * targetPixel;
		  sumPointTemplate += targetPixel * markerPixel;
		}
	      }

	      // Normalized cross-correlation
	      // !important divide first avoid overflow (e.g. sumPoint / count * sumPoint)
	      float count = float(${templateSize} * ${templateSize});
	      float pointVariance = sqrt(sumPointSquare - sumPoint / count * sumPoint);
	      float templateVariance = sqrt(sumTemplateSquare - sumTemplate / count * sumTemplate);

	      if (pointVariance < 0.0000001) {
		setOutput(-3.);
	      } else if (templateVariance < 0.0000001) {
		//setOutput(sumTemplate);
		setOutput(-4.);
	      } else {
		sumPointTemplate -= sumPoint / count * sumTemplate;
		float sim = sumPointTemplate / pointVariance / templateVariance;  
		setOutput(sim);
	      }
	    }
	  }
	`
      };

      // The parabola through the peak and its two neighbours along one axis has
      // its vertex at (left - right) / (2 (left - 2 peak + right)).
      const kernel2 = {
	variableNames: ['featurePoints', 'markerProperties', 'maxIndex', 'sims'],
	outputShape: [featureCount, 3], // [x, y, similarity]
	userCode: `
	  float vertex(float left, float peak, float right) {
	    float curvature = left - 2. * peak + right;
	    if (left < -1. || right < -1. || curvature >= -0.0001) return 0.;
	    return clamp((left - right) / (2. * curvature), -0.5, 0.5);
	  }

	  void main() {
	    ivec2 coords = getOutputCoords();

	    float markerScale = getMarkerProperties(2);

	    int featureIndex = coords[0];

	    int maxIndex = int(getMaxIndex(featureIndex));
	    if (coords[1] == 2) {
	      setOutput(getSims(featureIndex, maxIndex));
	      return;
	    }
	    int searchOffsetIndex = imod(maxIndex, ${searchSize * searchSize});
	    int offsetX = imod(searchOffsetIndex, ${searchSize});
	    int offsetY = searchOffsetIndex / ${searchSize};

	    float feature = getFeaturePoints(featureIndex, coords[1]);
	    float centre = floor(feature * markerScale + 0.5);
	    float offset = float((coords[1] == 0 ? offsetX : offsetY) * ${searchGap} - ${searchOneSize});

	    ${this.subpixel ? `
	    int stride = coords[1] == 0 ? 1 : ${searchSize};
	    int position = coords[1] == 0 ? offsetX : offsetY;
	    if (position > 0 && position < ${searchSize - 1}) {
	      float peak = getSims(featureIndex, searchOffsetIndex);
	      offset += float(${searchGap}) * vertex(getSims(featureIndex, searchOffsetIndex - stride), peak, getSims(featureIndex, searchOffsetIndex + stride));
	    }
	    // Keyframe pixel centres, in target pixels.
	    setOutput((centre + offset + 0.5) / markerScale);
	    ` : `
	    setOutput(feature + offset / markerScale);
	    `}
	  }
	`
      }

      this.kernelCaches.computeMatching[kernelKey] = [kernel1, kernel2];
    }

    return tf.tidy(() => {
      const programs = this.kernelCaches.computeMatching[kernelKey];
      const allSims = this._compileAndRun(programs[0], [featurePointsT, imagePixelsT, imagePropertiesT, projectedImageT]);
      const maxIndex = allSims.argMax(1);
      return this._compileAndRun(programs[1], [featurePointsT, imagePropertiesT, maxIndex, allSims]);
    });
  }

  _computeProjection(modelViewProjectionTransformT, inputImageT, trackingFrame) {
    const markerWidth = trackingFrame.width;
    const markerHeight = trackingFrame.height;
    const markerScale = trackingFrame.scale;
    const kernelKey = markerWidth + "-" + markerHeight + "-" + markerScale;

    if (!this.kernelCaches.computeProjection) {
      this.kernelCaches.computeProjection = {};
    }

    if (!this.kernelCaches.computeProjection[kernelKey]) {
      const inputHeight = inputImageT.shape[0];
      const inputWidth = inputImageT.shape[1];
      const kernel = {
	variableNames: ['M', 'pixel'],
	outputShape: [markerHeight, markerWidth],
	userCode: `
	  float m00, m01, m03, m10, m11, m13, m20, m21, m23;

	  // Input pixel centres are at whole coordinates.
	  float bilinear(vec2 u) {
	    u = clamp(u, vec2(0.), vec2(${inputWidth - 1}., ${inputHeight - 1}.));
	    vec2 f = fract(u);
	    int x0 = int(u.x);
	    int y0 = int(u.y);
	    int x1 = min(x0 + 1, ${inputWidth - 1});
	    int y1 = min(y0 + 1, ${inputHeight - 1});
	    return mix(mix(getPixel(y0, x0), getPixel(y0, x1), f.x), mix(getPixel(y1, x0), getPixel(y1, x1), f.x), f.y);
	  }

	  vec2 project(float x, float y) {
	    float uz = (x * m20) + (y * m21) + m23;
	    return vec2((x * m00) + (y * m01) + m03, (x * m10) + (y * m11) + m13) / uz;
	  }

	  // Where in the input a point of keyframe pixel (x, y) lands.
	  vec2 sampleAt(float x, float y) {
	    ${this.subpixel ? `
	    // Screen and target pixel j cover [j, j + 1], so pixel centres are at j + 0.5.
	    return project((x + 0.5) / float(${markerScale}), (y + 0.5) / float(${markerScale})) - 0.5;
	    ` : `
	    return project(x / float(${markerScale}), y / float(${markerScale}));
	    `}
	  }

	  void main() {
	      ivec2 coords = getOutputCoords();

	      m00 = getM(0, 0) * ${PRECISION_ADJUST}.;
	      m01 = getM(0, 1) * ${PRECISION_ADJUST}.;
	      m03 = getM(0, 3) * ${PRECISION_ADJUST}.;
	      m10 = getM(1, 0) * ${PRECISION_ADJUST}.;
	      m11 = getM(1, 1) * ${PRECISION_ADJUST}.;
	      m13 = getM(1, 3) * ${PRECISION_ADJUST}.;
	      m20 = getM(2, 0) * ${PRECISION_ADJUST}.;
	      m21 = getM(2, 1) * ${PRECISION_ADJUST}.;
	      m23 = getM(2, 3) * ${PRECISION_ADJUST}.;

	      ${this.bilinear ? `
	      // Average four samples across the keyframe pixel, which covers
	      // 1 / markerScale target pixels.
	      float value = 0.;
	      for (int k = 0; k < 4; k++) {
		float dx = (k == 0 || k == 2) ? -0.25 : 0.25;
		float dy = k < 2 ? -0.25 : 0.25;
		value += bilinear(sampleAt(float(coords[1]) + dx, float(coords[0]) + dy));
	      }
	      setOutput(value * 0.25);
	      ` : `
	      vec2 u = floor(sampleAt(float(coords[1]), float(coords[0])) + 0.5);
	      setOutput(getPixel(int(u.y), int(u.x)));
	      `}
	    }
	`
      };

      this.kernelCaches.computeProjection[kernelKey] = kernel;
    }

    return tf.tidy(() => {
      const program = this.kernelCaches.computeProjection[kernelKey];
      const result = this._compileAndRun(program, [modelViewProjectionTransformT, inputImageT]);
      return result;
    });
  }
  
  _buildAdjustedModelViewTransform(modelViewProjectionTransform) {
    return tf.tidy(() => {
      let modelViewProjectionTransformAdjusted = [];
      for (let i = 0; i < modelViewProjectionTransform.length; i++) {
	modelViewProjectionTransformAdjusted.push([]);
	for (let j = 0; j < modelViewProjectionTransform[i].length; j++) {
	  modelViewProjectionTransformAdjusted[i].push(modelViewProjectionTransform[i][j] / PRECISION_ADJUST);
	}
      }
      const t = tf.tensor(modelViewProjectionTransformAdjusted, [3, 4]);
      return t;
    });
  }

  _prebuild(trackingFrame, maxCount) {
    return tf.tidy(() => {
      const scale = trackingFrame.scale;

      const p = [];
      for (let k = 0; k < maxCount; k++) {
	if (k < trackingFrame.points.length) {
	  p.push([trackingFrame.points[k].x / scale, trackingFrame.points[k].y / scale]);
	} else {
	  p.push([-1, -1]);
	}
      }
      const imagePixels = tf.tensor(trackingFrame.data, [trackingFrame.width * trackingFrame.height]);
      const imageProperties = tf.tensor([trackingFrame.width, trackingFrame.height, trackingFrame.scale], [3]);
      const featurePoints = tf.tensor(p, [p.length, 2], 'float32');

      return {
	featurePoints,
	imagePixels,
	imageProperties
      }
    });
  }

  _compileAndRun(program, inputs) {
    const outInfo = tf.backend().compileAndRun(program, inputs);
    return tf.engine().makeTensorFromDataId(outInfo.dataId, outInfo.shape, outInfo.dtype);
  }
}

export {
  Tracker
};
