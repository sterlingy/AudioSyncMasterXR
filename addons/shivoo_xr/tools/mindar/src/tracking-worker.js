import {backend, engine, env, memory, time} from '@tensorflow/tfjs';
import {Controller} from './image-target/controller.js';
import {blockReads} from './libs/readback.js';

// Runs a Controller in a worker, so its GPU reads and shader compiles block this
// thread rather than the page's. web/image_tracking.js is the other side.
//
// Page to worker:
//   {type: 'start', targets: ArrayBuffer (.mind), width, height, options}, where
//     options are the Controller's plus blockingReads (default true)
//   {type: 'frame', id, bitmap: ImageBitmap, timestamp, camera}, camera as for
//     Controller.processFrame
//   {type: 'inspect', id, code}, only when options.profile is set
// Worker to page:
//   {type: 'ready', dimensions, focal}
//   {type: 'result', id, poses: [16 floats or null per target], pixelsPerMeter:
//     [per target, 0 if unknown], profile: [[stage, ms]]}
//   {type: 'inspected', id, value}
//   {type: 'error', message}
const serveTracking = () => {
  let controller = null;
  let options = {};
  let poses = [];
  let profile = [];

  self.onmessage = async ({data}) => {
    try {
      if (data.type === 'start') {
        options = data.options;
        blockReads(options.blockingReads !== false);
        controller = new Controller({
          inputWidth: data.width,
          inputHeight: data.height,
          ...options,
          onUpdate: (update) => {
            if (update.type === 'updateMatrix') {
              poses[update.targetIndex] = update.worldMatrix ? Array.from(update.worldMatrix) : null;
            }
          },
          onProfile: options.profile ? (name, ms) => profile.push([name, ms]) : null,
        });
        const {dimensions} = controller.addImageTargetsFromBuffer(data.targets);
        poses = dimensions.map(() => null);
        // Compiles the GPU programs, which takes a few seconds the first time.
        controller.dummyRun(new OffscreenCanvas(data.width, data.height));
        controller.resetTracking();
        self.postMessage({type: 'ready', dimensions, focal: controller.projectionTransform[1][1]});
      } else if (data.type === 'frame') {
        await controller.processFrame(data.bitmap, data.timestamp, data.camera || null);
        data.bitmap.close();
        self.postMessage({type: 'result', id: data.id, poses, pixelsPerMeter: controller.pixelsPerMeter, profile});
        profile = [];
      } else if (data.type === 'inspect' && options.profile) {
        let value;
        try {
          const body = new Function('controller', 'tf', `return (async () => {${data.code}})();`);
          value = await body(controller, {backend, engine, env, memory, time});
        } catch (error) {
          value = {error: String(error && error.stack || error)};
        }
        self.postMessage({type: 'inspected', id: data.id, value});
      }
    } catch (error) {
      self.postMessage({type: 'error', message: error && error.message ? error.message : String(error)});
    }
  };
};

export {
  serveTracking,
};
