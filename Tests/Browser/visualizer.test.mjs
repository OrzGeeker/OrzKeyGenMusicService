import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// ── 注入 visualizer 到沙箱 ──

const source = readFileSync(new URL('../../Resources/Public/audio/visualizer.js', import.meta.url), 'utf8');

function createSandbox() {
  const sandbox = {
    console,
    window: { innerWidth: 1200, devicePixelRatio: 1, addEventListener() {}, removeEventListener() {}, matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) },
    document: { hidden: false, addEventListener() {}, removeEventListener() {}, visibilityState: 'visible' },
    requestAnimationFrame: (fn) => setTimeout(fn, 0),
    cancelAnimationFrame: (id) => clearTimeout(id),
    setTimeout,
    clearTimeout,
    AudioContext: class { constructor() {} },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(source, ctx);
  return ctx;
}

function createControlledVisualizer({ reducedMotion = false } = {}) {
  let nextRafId = 1;
  const rafCallbacks = new Map();
  const windowListeners = new Map();
  const documentListeners = new Map();
  const mediaListeners = new Map();
  const sandbox = {
    console,
    window: {
      innerWidth: 1200,
      devicePixelRatio: 1,
      addEventListener(type, listener) { windowListeners.set(type, listener); },
      removeEventListener(type) { windowListeners.delete(type); },
      matchMedia: () => ({
        matches: reducedMotion,
        addEventListener(type, listener) { mediaListeners.set(type, listener); },
        removeEventListener(type) { mediaListeners.delete(type); },
      }),
    },
    document: {
      hidden: false,
      visibilityState: 'visible',
      addEventListener(type, listener) { documentListeners.set(type, listener); },
      removeEventListener(type) { documentListeners.delete(type); },
    },
    requestAnimationFrame(fn) {
      const id = nextRafId++;
      rafCallbacks.set(id, fn);
      return id;
    },
    cancelAnimationFrame(id) { rafCallbacks.delete(id); },
    setTimeout,
    clearTimeout,
  };
  const context = vm.createContext(sandbox);
  vm.runInContext(source, context);

  const drawCalls = { clear: 0, fill: 0 };
  const canvasContext = {
    globalAlpha: 1,
    setTransform() {},
    clearRect() { drawCalls.clear++; },
    fillRect() { drawCalls.fill++; },
    beginPath() {},
    arc() {},
    fill() {},
    moveTo() {},
    lineTo() {},
    stroke() {},
  };
  const canvas = {
    width: 600,
    height: 120,
    parentElement: { getBoundingClientRect: () => ({ width: 600, height: 120 }) },
    getContext: () => canvasContext,
  };
  let frequencyReads = 0;
  let timeReads = 0;
  const analyser = {
    frequencyBinCount: 128,
    fftSize: 256,
    getByteFrequencyData(buffer) {
      frequencyReads++;
      buffer.fill(180);
    },
    getByteTimeDomainData(buffer) {
      timeReads++;
      buffer.fill(128);
    },
  };
  const runNextFrame = () => {
    const entry = rafCallbacks.entries().next().value;
    if (!entry) return false;
    const [id, callback] = entry;
    rafCallbacks.delete(id);
    callback();
    return true;
  };
  return {
    context,
    canvas,
    analyser,
    drawCalls,
    rafCallbacks,
    windowListeners,
    documentListeners,
    mediaListeners,
    runNextFrame,
    get frequencyReads() { return frequencyReads; },
    get timeReads() { return timeReads; },
  };
}

// ── 纯函数测试 ──

test('normalizeBins clamps values to 0-1', () => {
  const ctx = createSandbox();
  const { normalizeBins } = ctx;

  const input = new Uint8Array([0, 128, 255]);
  const result = normalizeBins(input, 256);

  assert.equal(result.length, 3);
  assert.equal(result[0], 0);
  assert.ok(result[1] > 0.49 && result[1] < 0.51);
  assert.equal(result[2], 1);
});

test('normalizeBins returns all zeros for empty data', () => {
  const ctx = createSandbox();
  const { normalizeBins } = ctx;

  const result = normalizeBins(new Uint8Array(0), 0);
  assert.equal(result.length, 0);
});

test('buildMirroredBars returns expected count', () => {
  const ctx = createSandbox();
  const { buildMirroredBars } = ctx;

  const bins = new Float32Array(128).fill(0.5);
  const { bars, smoothed } = buildMirroredBars(bins, 16);

  assert.equal(bars.length, 16);
  assert.equal(smoothed, true);
  for (const val of bars) {
    assert.ok(val >= 0 && val <= 1);
  }
});

test('buildMirroredBars handles empty input', () => {
  const ctx = createSandbox();
  const { buildMirroredBars } = ctx;

  const { bars, smoothed } = buildMirroredBars(new Float32Array(0), 10);
  assert.equal(bars.length, 10);
  for (const val of bars) {
    assert.equal(val, 0);
  }
});

test('buildMirroredBars produces symmetric mirrored output pattern', () => {
  const ctx = createSandbox();
  const { buildMirroredBars } = ctx;

  // Single peak input should produce highest bar at corresponding position
  const bins = new Float32Array(64);
  bins[32] = 1;
  const { bars } = buildMirroredBars(bins, 16);

  // The peak bar should be > 0
  assert.ok(bars.some(v => v > 0), 'Expected at least one non-zero bar');
  // All values should be 0-1
  for (const v of bars) assert.ok(v >= 0 && v <= 1, `Expected 0-1 got ${v}`);
});

test('buildWavePoints returns patterned coordinates', () => {
  const ctx = createSandbox();
  const { buildWavePoints } = ctx;

  const data = new Uint8Array(256).fill(128);
  const points = buildWavePoints(data, 600, 120);

  assert.ok(points.length >= 4);
  // All x coordinates should increase
  for (let i = 2; i < points.length; i += 2) {
    assert.ok(points[i] >= points[i - 2], `x coords should increase: ${points[i]} >= ${points[i-2]}`);
  }
  // y at mid-level (128) should be near half height
  assert.ok(Math.abs(points[1] - 60) < 1, `y should be near 60, got ${points[1]}`);
});

test('buildWavePoints handles zero data', () => {
  const ctx = createSandbox();
  const { buildWavePoints } = ctx;

  const points = buildWavePoints(new Uint8Array(0), 100, 50);
  assert.equal(points.length, 0);
});

test('buildWavePoints clamps extreme values', () => {
  const ctx = createSandbox();
  const { buildWavePoints } = ctx;

  const allMin = new Uint8Array(128).fill(0);
  const points = buildWavePoints(allMin, 100, 50);
  assert.ok(points.length > 0);
  // All y values should be within canvas
  for (let i = 1; i < points.length; i += 2) {
    assert.ok(points[i] >= 0 && points[i] <= 50);
  }
});

// ── OrzAudioVisualizer 类测试 ──

test('OrzAudioVisualizer throws without canvas', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;
  assert.throws(() => new OrzAudioVisualizer({}), /canvas/);
});

test('OrzAudioVisualizer starts and stops', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;

  class FakeCanvas {
    constructor() {
      this.width = 600;
      this.height = 120;
      this.parentElement = { getBoundingClientRect: () => ({ width: 600, height: 120 }) };
    }
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, arc() {}, fill() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
  }

  const canvas = new FakeCanvas();
  const viz = new OrzAudioVisualizer({ canvas });

  assert.doesNotThrow(() => viz.start());
  assert.doesNotThrow(() => viz.start()); // repeated start is idempotent
  assert.doesNotThrow(() => viz.stop());
  assert.doesNotThrow(() => viz.stop()); // repeated stop is idempotent
});

test('OrzAudioVisualizer completes start-stop cycle safely', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;

  class FakeCanvas {
    constructor() {
      this.width = 600;
      this.height = 120;
      this.parentElement = { getBoundingClientRect: () => ({ width: 600, height: 120 }) };
    }
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, arc() {}, fill() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
  }

  const canvas = new FakeCanvas();
  const viz = new OrzAudioVisualizer({ canvas });
  viz.start();
  viz.stop();
  // RAF should not fire after stop
  viz._rafId = null;
});

test('OrzAudioVisualizer resize updates dimensions', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;

  let width = 600;
  class FakeCanvas {
    constructor() {
      this.width = 600;
      this.height = 120;
      this.parentElement = { getBoundingClientRect: () => ({ width, height: 120 }) };
    }
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, arc() {}, fill() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
  }

  const canvas = new FakeCanvas();
  const viz = new OrzAudioVisualizer({ canvas });

  assert.equal(viz._width, 600);

  width = 800;
  viz.resize();
  assert.equal(viz._width, 800);
});

test('OrzAudioVisualizer setMode handles unknown mode gracefully', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;

  class FakeCanvas {
    constructor() {
      this.width = 600;
      this.height = 120;
      this.parentElement = { getBoundingClientRect: () => ({ width: 600, height: 120 }) };
    }
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, arc() {}, fill() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
  }

  const canvas = new FakeCanvas();
  const viz = new OrzAudioVisualizer({ canvas });

  assert.equal(viz._mode, 'holographic');
  viz.setMode('unknown');
  assert.equal(viz._mode, 'holographic'); // falls back to default
  viz.setMode('spectrum');
  assert.equal(viz._mode, 'spectrum');
});

test('OrzAudioVisualizer destroy clears state', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;

  class FakeCanvas {
    constructor() {
      this.width = 600;
      this.height = 120;
      this.parentElement = { getBoundingClientRect: () => ({ width: 600, height: 120 }) };
    }
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, arc() {}, fill() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
  }

  const canvas = new FakeCanvas();
  const viz = new OrzAudioVisualizer({ canvas });
  viz.start();
  viz.destroy();

  assert.equal(viz._disabled, true);
  assert.equal(viz.analyser, null);
  assert.equal(viz.canvas, null);
  assert.equal(viz.ctx, null);
  assert.equal(viz._running, false);
});

test('OrzAudioVisualizer handles missing analyser without error', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;

  class FakeCanvas {
    constructor() {
      this.width = 600;
      this.height = 120;
      this.parentElement = { getBoundingClientRect: () => ({ width: 600, height: 120 }) };
    }
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, arc() {}, fill() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
  }

  const canvas = new FakeCanvas();
  const viz = new OrzAudioVisualizer({ canvas });
  viz.setAnalyser(null);

  assert.doesNotThrow(() => viz.start());
  assert.doesNotThrow(() => viz.stop());
});

test('OrzAudioVisualizer mode switching cleans up incompatible state', () => {
  const ctx = createSandbox();
  const { OrzAudioVisualizer } = ctx;

  class FakeCanvas {
    constructor() {
      this.width = 600;
      this.height = 120;
      this.parentElement = { getBoundingClientRect: () => ({ width: 600, height: 120 }) };
    }
    getContext() { return { setTransform() {}, clearRect() {}, fillRect() {}, beginPath() {}, arc() {}, fill() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
  }

  const canvas = new FakeCanvas();
  const viz = new OrzAudioVisualizer({ canvas });

  viz._particles.push({ x: 10, y: 10, life: 5, maxLife: 50, energy: 0.8 });
  assert.equal(viz._particles.length, 1);

  viz.setMode('spectrum');
  // Particles should be cleaned up
  assert.equal(viz._particles.length, 0);

  viz.setMode('holographic');
  assert.equal(viz._mode, 'holographic');
});

test('animation frames reuse frequency, time-domain, normalized, and bar buffers', () => {
  const env = createControlledVisualizer();
  const viz = new env.context.OrzAudioVisualizer({ canvas: env.canvas, analyser: env.analyser });
  viz.setMode('spectrum');
  viz.start();

  const buffers = [
    viz._frequencyData,
    viz._timeDomainData,
    viz._normalizedBins,
    viz._smoothBins,
    viz._bars,
    viz._peaks,
  ];
  assert.equal(env.runNextFrame(), true);
  assert.equal(viz._frequencyData, buffers[0]);
  assert.equal(viz._timeDomainData, buffers[1]);
  assert.equal(viz._normalizedBins, buffers[2]);
  assert.equal(viz._smoothBins, buffers[3]);
  assert.equal(viz._bars, buffers[4]);
  assert.equal(viz._peaks, buffers[5]);
  assert.equal(env.frequencyReads, 2);
  assert.equal(env.timeReads, 2);
  viz.stop();
});

test('pause decays cached energy without sampling and automatically stops frames', () => {
  const env = createControlledVisualizer();
  const viz = new env.context.OrzAudioVisualizer({ canvas: env.canvas, analyser: env.analyser });
  viz.setMode('spectrum');
  viz.start();
  const readsBeforePause = env.frequencyReads;

  viz.pause();
  let frames = 0;
  while (env.runNextFrame() && frames < 100) frames++;

  assert.ok(frames > 1, 'decay should span multiple frames');
  assert.equal(env.frequencyReads, readsBeforePause, 'paused decay must not resample audio');
  assert.equal(viz._decaying, false);
  assert.equal(viz._rafId, null);
  assert.equal(env.rafCallbacks.size, 0);
  assert.ok(env.drawCalls.clear > 0);
});

test('hidden pages cancel RAF and repeated visibility restores only one frame', () => {
  const env = createControlledVisualizer();
  const viz = new env.context.OrzAudioVisualizer({ canvas: env.canvas, analyser: env.analyser });
  viz.start();
  assert.equal(env.rafCallbacks.size, 1);

  env.context.document.hidden = true;
  env.documentListeners.get('visibilitychange')();
  assert.equal(env.rafCallbacks.size, 0);
  assert.equal(viz._rafId, null);

  env.context.document.hidden = false;
  env.documentListeners.get('visibilitychange')();
  env.documentListeners.get('visibilitychange')();
  assert.equal(env.rafCallbacks.size, 1);
  viz.stop();
});

test('reduced-motion mode renders once without maintaining an RAF loop', () => {
  const env = createControlledVisualizer({ reducedMotion: true });
  const viz = new env.context.OrzAudioVisualizer({
    canvas: env.canvas,
    analyser: env.analyser,
    reducedMotion: true,
  });

  viz.start();

  assert.equal(env.frequencyReads, 1);
  assert.equal(env.rafCallbacks.size, 0);
  assert.equal(viz._rafId, null);
  viz.stop();
});

test('start pause and resume keep lifecycle listeners idempotent', () => {
  const env = createControlledVisualizer();
  const viz = new env.context.OrzAudioVisualizer({ canvas: env.canvas, analyser: env.analyser });
  viz.start();
  viz.pause();
  viz.start();

  assert.equal(env.windowListeners.size, 1);
  assert.equal(env.documentListeners.size, 1);
  assert.equal(env.mediaListeners.size, 1);

  viz.destroy();
  assert.equal(env.windowListeners.size, 0);
  assert.equal(env.documentListeners.size, 0);
  assert.equal(env.mediaListeners.size, 0);
});
