import {Controller} from './image-target/controller.js';
import {Compiler} from './image-target/compiler.js';
import {serveTracking} from './tracking-worker.js';

globalThis.MINDAR = globalThis.MINDAR || {};
globalThis.MINDAR.IMAGE = {Controller, Compiler};

// Loaded as a worker, it tracks the frames the page posts to it.
if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {
  serveTracking();
}
