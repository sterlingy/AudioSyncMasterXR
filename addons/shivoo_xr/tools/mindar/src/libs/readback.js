import {cast, concat, reshape, tidy, util} from '@tensorflow/tfjs';

// Drivers for GPU pipelines written as generators that yield the tensors they need
// read back and are resumed with their values. readAsync waits on WebGL fences, so
// the page keeps rendering while the GPU works; readSync stalls until it is done.

let blocking = false;

// Makes reads stall, and join the tensors of each step into one read. Where
// stalling holds nothing else up, as in a worker, that is quicker: on Android a
// fence can take a few frames to signal while the page renders, and each read
// is a round trip to the GPU process.
const blockReads = (value=true) => {
  blocking = value;
};

const readTogether = (tensors) => {
  if (tensors.length === 1) return [tensors[0].arraySync()];
  const joined = tidy(() => concat(tensors.map((t) => cast(reshape(t, [-1]), 'float32'))));
  const data = joined.dataSync();
  joined.dispose();
  let offset = 0;
  return tensors.map((t) => {
    const values = data.subarray(offset, offset + t.size);
    offset += t.size;
    return t.rank === 0 ? values[0] : util.toNestedArray(t.shape, values);
  });
};

const readNow = (tensors) => blocking ? readTogether(tensors) : tensors.map((t) => t.arraySync());

const readSync = (pipeline) => {
  let step = pipeline.next();
  while (!step.done) step = pipeline.next(readNow(step.value));
  return step.value;
};

// timing, if given, gains the milliseconds spent on the main thread (issuing GPU
// work and the JavaScript between reads) in cpu, and waiting for the GPU in wait.
const readAsync = async (pipeline, timing=null) => {
  let start = performance.now();
  let step = pipeline.next();
  while (!step.done) {
    const issued = performance.now();
    const values = blocking ? readNow(step.value) : await Promise.all(step.value.map((t) => t.array()));
    const read = performance.now();
    if (timing) {
      timing.cpu += issued - start;
      timing.wait += read - issued;
    }
    start = read;
    step = pipeline.next(values);
  }
  if (timing) timing.cpu += performance.now() - start;
  return step.value;
};

export {
  blockReads,
  readSync,
  readAsync,
};
