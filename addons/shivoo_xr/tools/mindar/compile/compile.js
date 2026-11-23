// Compiles an image into a MindAR target. The ImageTarget node runs this from the
// Godot editor:
//
//   node compile/compile.js <pixels> <width> <height> <output.mind>
//
// pixels is a file of the image's RGBA bytes, already flattened onto the colour it
// is printed on. Prints "progress <percent>" lines as it goes, then one
// "result <json>" line with how many features each scale got, or an "error
// <message>" line.
import {readFile, writeFile} from 'node:fs/promises';
import * as tf from '@tensorflow/tfjs';
import {CompilerBase} from '../src/image-target/compiler-base.js';
import {buildTrackingImageList} from '../src/image-target/image-list.js';
import {extractTrackingFeatures} from '../src/image-target/tracker/extract-utils.js';
import '../src/image-target/detector/kernels/cpu/index.js';

class NodeCompiler extends CompilerBase {
  // compileImageTargets draws each image on one of these and reads its pixels back.
  createProcessCanvas(image) {
    const context = {drawImage() {}, getImageData: () => ({data: image.data})};
    return {getContext: () => context};
  }

  async compileTrack({progressCallback, targetImages, basePercent}) {
    const list = [];
    for (const [i, targetImage] of targetImages.entries()) {
      const imageList = buildTrackingImageList(targetImage);
      list.push(extractTrackingFeatures(imageList, (index) => {
        const done = (i + (index + 1) / imageList.length) / targetImages.length;
        progressCallback(basePercent + done * (100 - basePercent));
      }));
    }
    return list;
  }
}

const fail = (error) => {
  console.log('error ' + (error && error.message ? error.message : String(error)));
  process.exit(1);
};
process.on('uncaughtException', fail);
process.on('unhandledRejection', fail);

const [pixelsPath, width, height, outputPath] = process.argv.slice(2);
if (!outputPath) fail('usage: node compile/compile.js <pixels> <width> <height> <output.mind>');
await tf.setBackend('cpu');
const image = {width: Number(width), height: Number(height), data: new Uint8Array(await readFile(pixelsPath))};
if (image.data.length !== image.width * image.height * 4) {
  fail(`expected ${image.width}x${image.height} RGBA pixels, got ${image.data.length} bytes`);
}
const compiler = new NodeCompiler();
let reported = -1;
const [target] = await compiler.compileImageTargets([image], (percent) => {
  if (Math.floor(percent) > reported) {
    reported = Math.floor(percent);
    console.log('progress ' + reported);
  }
});
await writeFile(outputPath, compiler.exportData());
console.log('result ' + JSON.stringify({
  detection: target.matchingData.map((k) => k.maximaPoints.length + k.minimaPoints.length),
  tracking: target.trackingData.map((k) => k.points.length),
}));
