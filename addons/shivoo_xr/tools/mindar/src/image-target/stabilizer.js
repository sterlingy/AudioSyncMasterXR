import {dot, slerp, quaternionFromMatrix, matrixFromQuaternion} from '../libs/pose-filter.js';
import {relativeMotion, moveWorldMatrix} from '../libs/camera-motion.js';
import {WorldAnchor} from './world-anchor.js';

// Turns a target's tracked poses into the ones to show. While it is tracked they
// are smoothed by filter, with the camera's own motion taken out first. Through a
// loss of up to holdTime milliseconds the last one is held where the target was,
// moved against the camera's motion, and when tracking resumes the shown pose
// eases over to the tracked one across blendTime rather than jumping. Without the
// camera's motion, a held pose would stay put on screen as the camera turned, so
// it is held for only blindHoldTime.
//
// With worldAnchoring, once the target has been placed in the room from the
// camera's whole transform (see Triangulator), a WorldAnchor keeps it still there
// instead.
//
// Poses are MindAR world matrices: column-major, in target pixels, in the camera's
// GL axes. Camera transforms are as in camera-motion.js, or null.
class Stabilizer {
  constructor({filter, width, height, pixelsPerMeter, holdTime, blindHoldTime, blendTime, worldAnchoring=false, anchorTolerance}) {
    this.filter = filter;
    this.worldAnchor = worldAnchoring ? new WorldAnchor({width, height, blendTime, tolerance: anchorTolerance}) : null;
    this.halfWidth = width / 2;
    this.halfHeight = height / 2;
    this.pixelsPerMeter = pixelsPerMeter;
    this.holdTime = holdTime;
    this.blindHoldTime = blindHoldTime;
    this.blendTime = blendTime;
    this.reset();
  }

  reset() {
    this.filter.reset();
    if (this.worldAnchor) this.worldAnchor.reset();
    this.inRoom = false;
    // The last pose shown, and the camera it was shown from.
    this.anchor = null;
    this.filterCamera = null;
    this.lostTime = null;
    this.blend = null;
  }

  // time in milliseconds; pose is null when the target was not tracked. Returns
  // the pose to show, or null to hide the target.
  update(time, pose, camera) {
    // Held in the room only once triangulated, as until then where tracking puts
    // it along the line of sight is only as right as the target's assumed size.
    if (this.worldAnchor && camera && this.pixelsPerMeter > 0 && (this.inRoom || this.worldAnchor.point)) {
      if (!this.inRoom) {
        this.inRoom = true;
        this.worldAnchor.reset();
        if (this.anchor && this.anchor.camera) {
          this.worldAnchor.easeFrom(time, this.anchor.pose, this.anchor.camera, this.pixelsPerMeter);
        }
      }
      return this._updateInRoom(time, pose, camera);
    }
    if (!pose) {
      if (!this.anchor) return null;
      if (this.lostTime === null) this.lostTime = time;
      if (time - this.lostTime > (this.anchor.camera && camera ? this.holdTime : this.blindHoldTime)) {
        this.reset();
        return null;
      }
      return this._carry(this.anchor, camera);
    }
    if (this.lostTime !== null) {
      this.blend = {anchor: {pose: this._carry(this.anchor, camera), camera}, start: time};
      this.filter.reset();
      this.lostTime = null;
    } else if (this.filterCamera && camera && this.filter.move) {
      this.filter.move(relativeMotion(this.filterCamera, camera), this.pixelsPerMeter);
    }
    this.filterCamera = camera;
    let shown = this.filter.filter(time, pose);
    if (this.blend) {
      const s = (time - this.blend.start) / this.blendTime;
      if (s >= 1) {
        this.blend = null;
      } else {
        shown = this._interpolate(this._carry(this.blend.anchor, camera), shown, s * s * (3 - 2 * s));
      }
    }
    this.anchor = {pose: shown, camera};
    return shown;
  }

  // Where the target is in the room, as triangulated, or null if not known.
  setAnchorPoint(point) {
    if (this.worldAnchor) this.worldAnchor.point = point;
  }

  _updateInRoom(time, pose, camera) {
    if (!pose) {
      if (!this.worldAnchor.held) return null;
      if (this.lostTime === null) this.lostTime = time;
      if (time - this.lostTime > this.holdTime) {
        this.reset();
        return null;
      }
      return this.worldAnchor.show(time, camera);
    }
    this.lostTime = null;
    if (this.filterCamera && this.filter.move) {
      this.filter.move(relativeMotion(this.filterCamera, camera), this.pixelsPerMeter);
    }
    this.filterCamera = camera;
    const followed = this.filter.filter(time, pose);
    return this.worldAnchor.update(time, pose, followed, camera, this.pixelsPerMeter);
  }

  _carry({pose, camera: from}, to) {
    return from && to ? moveWorldMatrix(pose, relativeMotion(from, to), this.pixelsPerMeter) : pose;
  }

  // Slerps the orientation and moves the target's centre in a straight line.
  _interpolate(a, b, t) {
    const qa = quaternionFromMatrix(a);
    const qb = quaternionFromMatrix(b);
    if (dot(qa, qb) < 0) for (let i = 0; i < 4; i++) qb[i] = -qb[i];
    const R = matrixFromQuaternion(slerp(qa, qb, t));
    const centre = (m) => [0, 1, 2].map((i) => m[i] * this.halfWidth + m[4 + i] * this.halfHeight + m[12 + i]);
    const ca = centre(a);
    const cb = centre(b);
    const out = new Array(16).fill(0);
    for (let column = 0; column < 3; column++) {
      for (let row = 0; row < 3; row++) out[column * 4 + row] = R[row][column];
    }
    for (let i = 0; i < 3; i++) {
      out[12 + i] = ca[i] + t * (cb[i] - ca[i]) - (R[i][0] * this.halfWidth + R[i][1] * this.halfHeight);
    }
    out[15] = 1;
    return out;
  }
}

export {
  Stabilizer,
};
