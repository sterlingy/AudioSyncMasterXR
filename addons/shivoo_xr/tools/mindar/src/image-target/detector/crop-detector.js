import * as tf from '@tensorflow/tfjs';
import {Detector} from './detector.js';

// The detector runs on a fixed square. Each frame it looks at one view of the
// input, resampled to that square, cycling through (see _buildViews):
//   - crops at the input's resolution;
//   - larger crops shrunk, up to the whole short side, so targets bigger than the
//     compiled image can match;
//   - smaller crops enlarged 2x, so targets smaller than its smallest compiled
//     scale can.
// A view around where a target was last seen can be requested instead.
class CropDetector {
  constructor(width, height, debugMode=false) {
    this.debugMode = debugMode;
    this.width = width;
    this.height = height;

    // nearest power of 2, min dimensions 
    let minDimension = Math.min(width, height) / 2;
    let cropSize = Math.pow( 2, Math.round( Math.log( minDimension ) / Math.log( 2 ) ) ); 
    this.cropSize = cropSize;

    this.detector = new Detector(cropSize, cropSize, debugMode);

    this.kernelCaches = {};
    this.views = this._buildViews();
    this.viewIndex = 0;

    // detectAround snaps to these sizes, steps of sqrt(2) from half the crop up to
    // the whole frame: each size compiles its own GPU programs, which on phones
    // takes long enough to drop frames.
    const largest = Math.min(width, height);
    this.aroundSizes = [];
    for (let size = cropSize / 2; size < largest; size *= Math.SQRT2) this.aroundSizes.push(Math.round(size));
    this.aroundSizes.push(largest);
  }

  // Compiles the programs for every view size up front.
  warmUp(inputImageT) {
    const sizes = new Set([...this.views.map((v) => v.size), ...this.aroundSizes]);
    for (const size of sizes) this._crop(inputImageT, {x: 0, y: 0, size}).dispose();
  }

  detect(inputImageT) { // crop center
    const startY = Math.floor(this.height / 2 - this.cropSize / 2);
    const startX = Math.floor(this.width / 2 - this.cropSize / 2);
    const view = {x: startX, y: startY, size: this.cropSize};
    const cropT = this._crop(inputImageT, view);
    const result = this._finish(this.detector.detect(cropT), cropT, view);

    if (this.debugMode) {
      result.debugExtra.crop = {startX, startY, cropSize: this.cropSize}; 
    }
    return result;
  }

  // timing: as for readAsync.
  detectMoving(inputImageT, timing=null) {
    const view = this.views[this.viewIndex];
    this.viewIndex = (this.viewIndex + 1) % this.views.length;
    return this._detectAsync(inputImageT, view, timing);
  }

  // A square view of the input around the box {x, y, width, height}.
  detectAround(inputImageT, box, timing=null) {
    const wanted = Math.max(box.width, box.height) * 1.25;
    const size = this.aroundSizes.find((s) => s >= wanted) ?? this.aroundSizes[this.aroundSizes.length - 1];
    return this._detectAsync(inputImageT, this._clampView(box.x + box.width / 2 - size / 2, box.y + box.height / 2 - size / 2, size), timing);
  }

  // A target is held up to the camera, so it is most likely near the middle of
  // the view, at any size. Every other view is centred, cycling through sizes that
  // between them fit targets from an eighth of the short side to all of it; the
  // views between those cover the rest of the input.
  _buildViews() {
    const crop = this.cropSize;
    const half = crop / 2;
    const between = Math.round(crop * Math.SQRT2);
    const full = Math.min(this.width, this.height);
    const at = (size, dx, dy, step) =>
      this._clampView(this.width / 2 - size / 2 + dx * step, this.height / 2 - size / 2 + dy * step, size);

    const centred = [crop, full, between, half].filter((size) => size <= full).map((size) => at(size, 0, 0, 0));

    const ring = [[-1, -1], [0, -1], [1, -1], [-1, 0], [1, 0], [-1, 1], [0, 1], [1, 1]];
    const corners = [[-1, -1], [1, -1], [-1, 1], [1, 1]];
    const native = ring.map(([dx, dy]) => at(crop, dx, dy, crop / 2));
    const larger = between < full ? corners.map(([dx, dy]) => at(between, dx, dy, between / 2)) : [];
    const enlarged = corners.map(([dx, dy]) => at(half, dx, dy, half / 2));
    // Squares as big as the input's short side, along its long side and
    // overlapping by at least half, so a target filling most of the short side is
    // wholly in one of them however tall the input.
    const spare = Math.max(this.width, this.height) - full;
    const count = Math.max(2, Math.ceil(spare / (full / 2)) + 1);
    const shrunk = [];
    for (let k = 0; k < count; k++) {
      const offset = spare * k / (count - 1);
      shrunk.push(this.width > this.height ? this._clampView(offset, 0, full) : this._clampView(0, offset, full));
    }

    const others = [];
    const groups = [native, larger, shrunk, enlarged];
    for (let i = 0; others.length < groups.reduce((n, g) => n + g.length, 0); i++) {
      for (const group of groups) {
        if (i < group.length) others.push(group[i]);
      }
    }
    const views = [];
    for (let i = 0; i < others.length; i++) {
      views.push(centred[i % centred.length], others[i]);
    }
    return views;
  }

  _clampView(x, y, size) {
    size = Math.min(size, this.width, this.height);
    x = Math.round(Math.max(0, Math.min(this.width - size, x)));
    y = Math.round(Math.max(0, Math.min(this.height - size, y)));
    return {x, y, size: Math.round(size)};
  }

  async _detectAsync(inputImageT, view, timing) {
    const start = performance.now();
    const cropT = this._crop(inputImageT, view);
    if (timing) timing.cpu += performance.now() - start;
    return this._finish(await this.detector.detectAsync(cropT, timing), cropT, view);
  }

  _crop(inputImageT, {x: startX, y: startY, size}) {
    return tf.tidy(() => {
      const cropT = inputImageT.slice([startY, startX], [size, size]);
      if (size === this.cropSize) return cropT;
      return tf.image.resizeBilinear(cropT.expandDims(2), [this.cropSize, this.cropSize], false, true).squeeze([2]);
    });
  }

  // Maps the points back to the input and frees the crop.
  _finish({featurePoints, debugExtra}, cropInputImageT, {x: startX, y: startY, size}) {
    const factor = size / this.cropSize;
    featurePoints.forEach((p) => {
      p.x = startX + (p.x + 0.5) * factor - 0.5;
      p.y = startY + (p.y + 0.5) * factor - 0.5;
      p.scale *= factor;
    });
    if (this.debugMode) {
      debugExtra.projectedImage = cropInputImageT.arraySync();
    }
    cropInputImageT.dispose();
    return {featurePoints: featurePoints, debugExtra};
  }
}

export {
  CropDetector
};
