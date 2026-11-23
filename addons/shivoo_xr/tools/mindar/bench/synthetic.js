// Renders a planar target the way a phone camera would see it: on a cluttered
// wall that moves with it, with motion blur, sensor noise and exposure changes.
// The camera has MindAR's assumed 45 degree vertical field of view and the target
// is 1 unit wide, centred on the origin of its model matrix.

export const FOVY = 45 * Math.PI / 180;

export class SyntheticCamera {
  constructor(width, height, image) {
    this.width = width;
    this.height = height;
    this.aspect = image.height / image.width;
    this.canvas = document.createElement('canvas');
    this.canvas.width = width;
    this.canvas.height = height;
    const gl = this.canvas.getContext('webgl2', {preserveDrawingBuffer: true, antialias: false});
    this.gl = gl;
    this.projection = perspective(FOVY, width / height, 0.05, 100);

    this.sceneProgram = linkProgram(gl, `#version 300 es
      in vec2 position;
      uniform mat4 mvp;
      uniform vec2 halfSize;
      uniform vec2 uvScale;
      out vec2 uv;
      void main() {
        uv = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5) * uvScale;
        gl_Position = mvp * vec4(position * halfSize, 0.0, 1.0);
      }`, `#version 300 es
      precision highp float;
      in vec2 uv;
      uniform sampler2D image;
      out vec4 color;
      void main() { color = texture(image, uv); }`);

    this.copyProgram = linkProgram(gl, `#version 300 es
      in vec2 position;
      out vec2 uv;
      void main() {
        uv = position * 0.5 + 0.5;
        gl_Position = vec4(position, 0.0, 1.0);
      }`, `#version 300 es
      precision highp float;
      in vec2 uv;
      uniform sampler2D image;
      uniform float gain;
      uniform float noise;
      uniform float seed;
      // Pixels, y down: a hand-coloured box over the image, and a bright spot.
      uniform vec4 occluder;
      uniform vec4 glare;
      uniform vec2 size;
      out vec4 color;
      float hash(vec2 p) {
        p = fract(p * vec2(443.897, 441.423) + seed);
        p += dot(p, p.yx + 19.19);
        return fract((p.x + p.y) * p.x);
      }
      void main() {
        vec3 c = texture(image, uv).rgb;
        vec2 p = gl_FragCoord.xy;
        vec2 pixel = vec2(p.x, size.y - p.y);
        vec2 inside = step(occluder.xy, pixel) * step(pixel, occluder.xy + occluder.zw);
        c = mix(c, vec3(0.62, 0.45, 0.38) * (0.8 + 0.2 * uv.y), inside.x * inside.y);
        c += glare.w * exp(-dot(pixel - glare.xy, pixel - glare.xy) / (glare.z * glare.z));
        c *= gain;
        // Approximately normal noise from the sum of three uniforms.
        float n = (hash(p) + hash(p + 17.0) + hash(p + 39.0) - 1.5) * 2.0;
        color = vec4(clamp(c + n * noise, 0.0, 1.0), 1.0);
      }`);

    this.quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

    this.targetTexture = createTexture(gl, image, false);
    this.wallTexture = createTexture(gl, makeWall(1024, 7), true);

    this.subFrame = createTarget(gl, width, height);
    this.accumulated = createTarget(gl, width, height);
  }

  // models: the target's model matrices across the exposure (one per sub-frame).
  render(models, {gain = 1, noise = 0, seed = 0, occluder = [0, 0, 0, 0], glare = [0, 0, 1, 0]} = {}) {
    this.post = {gain, noise, seed, occluder, glare};
    const gl = this.gl;
    gl.disable(gl.DEPTH_TEST);

    gl.bindFramebuffer(gl.FRAMEBUFFER, this.accumulated.framebuffer);
    gl.viewport(0, 0, this.width, this.height);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);

    for (const model of models) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, this.subFrame.framebuffer);
      gl.disable(gl.BLEND);
      gl.clearColor(0.18, 0.17, 0.16, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      const mvp = multiply(this.projection, model);
      // The wall sits just behind the target and moves with it.
      const wall = multiply(mvp, translation(0, 0, -0.002));
      this._drawQuad(wall, this.wallTexture, 4, 4, 4, 4);
      this._drawQuad(mvp, this.targetTexture, 0.5, 0.5 * this.aspect, 1, 1);

      gl.bindFramebuffer(gl.FRAMEBUFFER, this.accumulated.framebuffer);
      gl.enable(gl.BLEND);
      gl.blendColor(0, 0, 0, 1 / models.length);
      gl.blendFunc(gl.CONSTANT_ALPHA, gl.ONE);
      this._drawFullScreen(this.subFrame.texture, {gain: 1, noise: 0, seed: 0, occluder: [0, 0, 0, 0], glare: [0, 0, 1, 0]});
    }

    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.disable(gl.BLEND);
    this._drawFullScreen(this.accumulated.texture, this.post);
  }

  // Where the target's corners land in the image, in pixels with y down.
  // Order: top-left, top-right, bottom-right, bottom-left of the target image,
  // then the point apex target widths above its centre.
  corners(model, apex = 0) {
    const hx = 0.5;
    const hy = 0.5 * this.aspect;
    return [[-hx, hy, 0], [hx, hy, 0], [hx, -hy, 0], [-hx, -hy, 0], [0, 0, apex]].map(([x, y, z]) => {
      const cx = model[0] * x + model[4] * y + model[8] * z + model[12];
      const cy = model[1] * x + model[5] * y + model[9] * z + model[13];
      const cz = model[2] * x + model[6] * y + model[10] * z + model[14];
      return project(cx, cy, cz, this.width, this.height);
    });
  }

  _drawQuad(mvp, texture, halfX, halfY, uvX, uvY) {
    const gl = this.gl;
    const program = this.sceneProgram;
    gl.useProgram(program);
    gl.uniformMatrix4fv(gl.getUniformLocation(program, 'mvp'), false, mvp);
    gl.uniform2f(gl.getUniformLocation(program, 'halfSize'), halfX, halfY);
    gl.uniform2f(gl.getUniformLocation(program, 'uvScale'), uvX, uvY);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    this._drawStrip(program);
  }

  _drawFullScreen(texture, {gain, noise, seed, occluder, glare}) {
    const gl = this.gl;
    const program = this.copyProgram;
    gl.useProgram(program);
    gl.uniform1f(gl.getUniformLocation(program, 'gain'), gain);
    gl.uniform1f(gl.getUniformLocation(program, 'noise'), noise);
    gl.uniform1f(gl.getUniformLocation(program, 'seed'), seed);
    gl.uniform4fv(gl.getUniformLocation(program, 'occluder'), occluder);
    gl.uniform4fv(gl.getUniformLocation(program, 'glare'), glare);
    gl.uniform2f(gl.getUniformLocation(program, 'size'), this.width, this.height);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    this._drawStrip(program);
  }

  _drawStrip(program) {
    const gl = this.gl;
    gl.bindBuffer(gl.ARRAY_BUFFER, this.quad);
    const position = gl.getAttribLocation(program, 'position');
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }
}

// Camera-space point (GL axes, looking down -z) to pixels with y down.
export function project(x, y, z, width, height) {
  const f = (height / 2) / Math.tan(FOVY / 2);
  return [width / 2 + f * x / -z, height / 2 - f * y / -z];
}

// Random shapes and text, so the background has features that are not the target.
function makeWall(size, seed) {
  const random = mulberry32(seed);
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const context = canvas.getContext('2d');
  context.fillStyle = '#8a8274';
  context.fillRect(0, 0, size, size);
  for (let i = 0; i < 260; i++) {
    const grey = Math.floor(40 + random() * 180);
    context.fillStyle = `rgb(${grey},${Math.floor(grey * (0.8 + random() * 0.4))},${Math.floor(grey * (0.7 + random() * 0.4))})`;
    const x = random() * size;
    const y = random() * size;
    const r = 4 + random() * 40;
    if (random() < 0.4) {
      context.beginPath();
      context.arc(x, y, r, 0, Math.PI * 2);
      context.fill();
    } else if (random() < 0.7) {
      context.fillRect(x, y, r * 2, r * (0.3 + random()));
    } else {
      context.font = `${Math.floor(10 + random() * 30)}px sans-serif`;
      context.fillText(Math.floor(random() * 1e9).toString(36), x, y);
    }
  }
  return canvas;
}

function mulberry32(seed) {
  return () => {
    seed |= 0;
    seed = seed + 0x6d2b79f5 | 0;
    let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

function createTexture(gl, source, repeat) {
  const texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
  gl.generateMipmap(gl.TEXTURE_2D);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
  const wrap = repeat ? gl.REPEAT : gl.CLAMP_TO_EDGE;
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap);
  const anisotropy = gl.getExtension('EXT_texture_filter_anisotropic');
  if (anisotropy) {
    gl.texParameterf(gl.TEXTURE_2D, anisotropy.TEXTURE_MAX_ANISOTROPY_EXT, 8);
  }
  return texture;
}

function createTarget(gl, width, height) {
  const texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  const framebuffer = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
  return {texture, framebuffer};
}

function linkProgram(gl, vertexSource, fragmentSource) {
  const program = gl.createProgram();
  for (const [type, text] of [[gl.VERTEX_SHADER, vertexSource], [gl.FRAGMENT_SHADER, fragmentSource]]) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, text);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      throw new Error(gl.getShaderInfoLog(shader));
    }
    gl.attachShader(program, shader);
  }
  gl.linkProgram(program);
  return program;
}

// Column-major 4x4 matrices, as WebGL expects.
export function multiply(a, b) {
  const out = new Float32Array(16);
  for (let column = 0; column < 4; column++) {
    for (let row = 0; row < 4; row++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) {
        sum += a[k * 4 + row] * b[column * 4 + k];
      }
      out[column * 4 + row] = sum;
    }
  }
  return out;
}

export function perspective(fovy, aspect, near, far) {
  const f = 1 / Math.tan(fovy / 2);
  return new Float32Array([
    f / aspect, 0, 0, 0,
    0, f, 0, 0,
    0, 0, (far + near) / (near - far), -1,
    0, 0, 2 * far * near / (near - far), 0,
  ]);
}

export function translation(x, y, z) {
  return new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]);
}

export function rotationX(a) {
  const c = Math.cos(a);
  const s = Math.sin(a);
  return new Float32Array([1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]);
}

export function rotationY(a) {
  const c = Math.cos(a);
  const s = Math.sin(a);
  return new Float32Array([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]);
}

export function rotationZ(a) {
  const c = Math.cos(a);
  const s = Math.sin(a);
  return new Float32Array([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
}
