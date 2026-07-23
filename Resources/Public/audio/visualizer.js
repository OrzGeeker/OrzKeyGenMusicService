/**
 * OrzAudioVisualizer — 全息声场可视化引擎
 *
 * 职责：频域与时域采样转换、Canvas 2D 绘制、动画生命周期。
 * 不依赖 Alpine、播放器或后端 API。
 *
 * 导出：
 *   OrzAudioVisualizer class
 *   normalizeBins()
 *   buildMirroredBars()
 *   buildWavePoints()
 */
(function () {
  'use strict';

  // ── 颜色常量 ──

  const COLOR_GREEN = [57, 229, 140];   // #39e58c
  const COLOR_CYAN = [34, 211, 238];    // #22d3ee
  const COLOR_PURPLE = [167, 139, 250]; // #a78bfa
  const COLOR_AMBER = [251, 191, 36];   // #fbbf24
  const COLOR_DIM = [20, 40, 30];

  // ── 辅助函数 ──

  /**
   * 在颜色 A 和 B 之间线性插值
   * @returns {number[]} [r, g, b]
   */
  function lerpColor(a, b, t) {
    return [
      a[0] + (b[0] - a[0]) * t,
      a[1] + (b[1] - a[1]) * t,
      a[2] + (b[2] - a[2]) * t,
    ];
  }

  /**
   * 根据 0-1 位置返回频段颜色
   */
  function spectrumColor(t) {
    t = Math.max(0, Math.min(1, t));
    if (t < 0.33) return lerpColor(COLOR_GREEN, COLOR_CYAN, t / 0.33);
    if (t < 0.66) return lerpColor(COLOR_CYAN, COLOR_PURPLE, (t - 0.33) / 0.33);
    return lerpColor(COLOR_PURPLE, COLOR_AMBER, (t - 0.66) / 0.34);
  }

  /**
   * 格式化颜色数组为 CSS rgba 字符串
   */
  function rgba(color, alpha) {
    return `rgba(${color[0]},${color[1]},${color[2]},${alpha})`;
  }

  // ── 导出纯函数（可单测） ──

  /**
   * 归一化频域数据到 0-1 范围
   * @param {Uint8Array} data - 原始频域数据
   * @param {number} fftSize - FFT 大小
   * @returns {Float32Array} 归一化后的数据
   */
  function normalizeBins(data, fftSize) {
    const len = data.length;
    const result = new Float32Array(len);
    const maxVal = 255;
    for (let i = 0; i < len; i++) {
      result[i] = Math.max(0, Math.min(1, data[i] / maxVal));
    }
    return result;
  }

  /**
   * 构建上下镜像的频谱柱数据
   * @param {Float32Array|number[]} bins - 归一化的频段值（0-1）
   * @param {number} count - 目标柱数
   * @returns {{ bars: Float32Array, smoothed: boolean }}
   */
  function buildMirroredBars(bins, count) {
    const bars = new Float32Array(count);
    const binLen = bins.length;
    if (binLen === 0 || count === 0) return { bars, smoothed: false };

    for (let i = 0; i < count; i++) {
      // 对数分组：低频更多柱
      const ratio = i / count;
      const lowIdx = Math.floor(ratio * ratio * binLen);
      const highIdx = Math.min(binLen - 1, lowIdx + Math.max(1, Math.floor(binLen / count)));
      let sum = 0;
      let n = 0;
      for (let j = lowIdx; j <= highIdx && j < binLen; j++) {
        sum += bins[j];
        n++;
      }
      bars[i] = n > 0 ? Math.min(1, sum / n * 1.5) : 0;
    }
    return { bars, smoothed: true };
  }

  /**
   * 构建时域波形点
   * @param {Uint8Array} data - 原始时域数据
   * @param {number} width - Canvas 宽度
   * @param {number} height - Canvas 高度
   * @returns {Float32Array} 波形点 x, y 交替（数量 = count * 2）
   */
  function buildWavePoints(data, width, height) {
    const len = data.length;
    if (len === 0) return new Float32Array(0);
    const step = Math.max(1, Math.floor(len / Math.min(len, Math.max(20, Math.floor(width / 3)))));
    const count = Math.floor(len / step);
    const points = new Float32Array(count * 2);
    const half = height / 2;
    const scale = height * 0.4;

    for (let i = 0; i < count; i++) {
      const idx = i * step;
      const x = (i / count) * width;
      const y = half + ((data[idx] / 255) * 2 - 1) * scale;
      points[i * 2] = x;
      points[i * 2 + 1] = y;
    }
    return points;
  }

  // ── OrzAudioVisualizer 类 ──

  class OrzAudioVisualizer {
    /**
     * @param {Object} options
     * @param {HTMLCanvasElement} options.canvas - Canvas 元素
     * @param {AnalyserNode} [options.analyser] - Web Audio 分析器
     * @param {boolean} [options.reducedMotion=false] - 减少动画
     */
    constructor({ canvas, analyser, reducedMotion = false }) {
      if (!canvas) throw new Error('canvas is required');

      this.canvas = canvas;
      this.ctx = canvas.getContext('2d');
      this.analyser = analyser || null;
      this.reducedMotion = reducedMotion;

      // 状态
      this._running = false;
      this._decaying = false;
      this._rafId = null;
      this._eventsBound = false;
      this._mode = 'holographic'; // 'holographic' | 'spectrum'
      this._width = 0;
      this._height = 0;

      // 粒子池
      this._particles = [];
      this._maxParticles = this._isMobile() ? 20 : 60;
      this._maxSpawnPerFrame = this._isMobile() ? 2 : 4;
      this._particleId = 0;

      // 频谱缓存（平滑衰减用）
      this._smoothBins = null;
      this._frequencyData = null;
      this._timeDomainData = null;
      this._normalizedBins = null;
      this._bars = null;
      this._peaks = null;
      this._barCount = 0;
      this._phase = 0;
      this._energy = 0;

      // Canvas 设备像素比
      this._dpr = Math.min(window.devicePixelRatio || 1, 2);

      // 降级标志：如果 Canvas 2D 不可用，标记为不可用
      this._disabled = !this.ctx;

      // 绑定事件
      this._boundResize = this._onResize.bind(this);
      this._boundVisibility = this._onVisibility.bind(this);
      this._boundReducedMotionQuery = this._onReducedMotionChange.bind(this);

      // 首次尺寸初始化
      this._updateSize();
    }

    // ── 尺寸 ──

    _isMobile() {
      return window.innerWidth < 720;
    }

    _updateSize() {
      const rect = this.canvas.parentElement
        ? this.canvas.parentElement.getBoundingClientRect()
        : { width: this.canvas.width, height: this.canvas.height };
      this._width = rect.width || 600;
      this._height = rect.height || 120;
      this.canvas.width = this._width * this._dpr;
      this.canvas.height = this._height * this._dpr;
      this.ctx.setTransform(this._dpr, 0, 0, this._dpr, 0, 0);
    }

    // ── 公共 API ──

    /**
     * 开始动画循环
     */
    start() {
      if (this._disabled || this._running) return;
      this._running = true;
      this._decaying = false;
      this._bindEvents();
      if (!document.hidden && !this._rafId) this._tick();
    }

    /**
     * 暂停采样并让现有能量平滑衰减；衰减完成后自动停帧。
     */
    pause() {
      if (this._disabled || (!this._running && !this._decaying)) return;
      this._running = false;
      this._decaying = true;
      this._bindEvents();
      if (!document.hidden && !this._rafId) this._tick();
    }

    /**
     * 停止动画循环
     */
    stop() {
      this._running = false;
      this._decaying = false;
      if (this._rafId) {
        cancelAnimationFrame(this._rafId);
        this._rafId = null;
      }
      this._unbindEvents();
      // 淡出到静态画面
      this._fadeOut();
    }

    /**
     * 调整尺寸
     */
    resize() {
      this._updateSize();
    }

    /**
     * 切换模式
     * @param {string} mode
     */
    setMode(mode) {
      if (mode !== 'holographic' && mode !== 'spectrum') {
        mode = 'holographic';
      }
      this._mode = mode;
      // 清理粒子（全息模式专用）
      if (mode === 'spectrum') {
        this._particles = [];
      }
    }

    /**
     * 释放资源
     */
    destroy() {
      this.stop();
      this._disabled = true;
      this.analyser = null;
      this.canvas = null;
      this.ctx = null;
      this._smoothBins = null;
      this._frequencyData = null;
      this._timeDomainData = null;
      this._normalizedBins = null;
      this._bars = null;
      this._peaks = null;
      this._particles = [];
    }

    /**
     * 更新分析器引用
     * @param {AnalyserNode|null} analyser
     */
    setAnalyser(analyser) {
      this.analyser = analyser;
      this._ensureSampleBuffers();
      if ((this._running || this._decaying) && !document.hidden && !this._rafId) {
        this._tick();
      }
    }

    // ── 事件绑定 ──

    _bindEvents() {
      if (this._eventsBound) return;
      window.addEventListener('resize', this._boundResize);
      document.addEventListener('visibilitychange', this._boundVisibility);
      this._matchMedia = window.matchMedia('(prefers-reduced-motion: reduce)');
      this._matchMedia.addEventListener('change', this._boundReducedMotionQuery);
      this._eventsBound = true;
    }

    _unbindEvents() {
      if (!this._eventsBound) return;
      window.removeEventListener('resize', this._boundResize);
      document.removeEventListener('visibilitychange', this._boundVisibility);
      if (this._matchMedia) {
        this._matchMedia.removeEventListener('change', this._boundReducedMotionQuery);
      }
      this._eventsBound = false;
    }

    _onResize() {
      this._updateSize();
      const mobile = this._isMobile();
      this._maxParticles = mobile ? 20 : 60;
      this._maxSpawnPerFrame = mobile ? 2 : 4;
    }

    _onVisibility() {
      if (document.hidden) {
        // 不可见时停止 RAF
        if (this._rafId) {
          cancelAnimationFrame(this._rafId);
          this._rafId = null;
        }
      } else {
        // 恢复时重启
        if ((this._running || this._decaying) && !this._rafId) {
          this._tick();
        }
      }
    }

    _onReducedMotionChange(e) {
      this.reducedMotion = e.matches;
      if (!this.reducedMotion && this._running && !document.hidden && !this._rafId) {
        this._tick();
      }
    }

    // ── 淡出 ──

    _fadeOut() {
      if (this._disabled || !this.ctx) return;
      this.ctx.clearRect(0, 0, this._width, this._height);
    }

    // ── 粒子系统 ──

    _spawnParticle(x, y, energy) {
      if (this._particles.length >= this._maxParticles) return;
      if (this._particles.length >= this._maxSpawnPerFrame * 2) {
        // 检查当前帧已生成数量
        // 由调用者控制每帧生成数
      }
      this._particles.push({
        id: this._particleId++,
        x,
        y,
        vx: (Math.random() - 0.5) * 1.2,
        vy: -Math.random() * 1.5 - 0.3,
        life: 0,
        maxLife: 40 + Math.random() * 30,
        size: 1.5 + Math.random() * 2.5,
        energy,
      });
    }

    _updateParticles() {
      for (let i = this._particles.length - 1; i >= 0; i--) {
        const p = this._particles[i];
        p.life++;
        if (p.life >= p.maxLife) {
          this._particles.splice(i, 1);
          continue;
        }
        p.x += p.vx;
        p.y += p.vy;
        p.vy += 0.02; // 重力
        p.vx *= 0.98; // 摩擦
      }
    }

    _drawParticles(ctx, width, height) {
      if (this._mode !== 'holographic') return;
      for (const p of this._particles) {
        const progress = p.life / p.maxLife;
        const alpha = (1 - progress) * 0.7;
        const color = spectrumColor(p.energy);
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.size * (1 - progress * 0.5), 0, Math.PI * 2);
        ctx.fillStyle = rgba(color, alpha);
        ctx.fill();
      }
    }

    // ── 可复用采样缓冲区 ──

    _ensureSampleBuffers() {
      const frequencyLength = this.analyser?.frequencyBinCount || 128;
      const timeLength = this.analyser?.fftSize || 2048;
      if (!this._frequencyData || this._frequencyData.length !== frequencyLength) {
        this._frequencyData = new Uint8Array(frequencyLength);
        this._normalizedBins = new Float32Array(frequencyLength);
        this._smoothBins = new Float32Array(frequencyLength);
      }
      if (!this._timeDomainData || this._timeDomainData.length !== timeLength) {
        this._timeDomainData = new Uint8Array(timeLength);
        this._timeDomainData.fill(128);
      }
    }

    _normalizeFrequencyData() {
      for (let i = 0; i < this._frequencyData.length; i++) {
        this._normalizedBins[i] = this._frequencyData[i] / 255;
      }
    }

    _buildReusableBars(count) {
      if (!this._bars || this._barCount !== count) {
        this._bars = new Float32Array(count);
        this._peaks = new Float32Array(count);
        this._barCount = count;
      }
      const binLen = this._smoothBins?.length || 0;
      this._bars.fill(0);
      if (!binLen) return this._bars;
      for (let i = 0; i < count; i++) {
        const ratio = i / count;
        const lowIdx = Math.floor(ratio * ratio * binLen);
        const highIdx = Math.min(binLen - 1, lowIdx + Math.max(1, Math.floor(binLen / count)));
        let sum = 0;
        let samples = 0;
        for (let j = lowIdx; j <= highIdx; j++) {
          sum += this._smoothBins[j];
          samples++;
        }
        this._bars[i] = samples ? Math.min(1, sum / samples * 1.5) : 0;
      }
      return this._bars;
    }

    // ── 频谱外观（霓虹频谱 / 全息声场） ──

    _drawSpectrum(ctx, width, height, decayOnly = false) {
      const smoothFactor = decayOnly ? 0.18 : (this.reducedMotion ? 1 : 0.3);
      let peak = 0;
      let energy = 0;
      for (let i = 0; i < this._smoothBins.length; i++) {
        const target = decayOnly ? 0 : this._normalizedBins[i];
        this._smoothBins[i] += (target - this._smoothBins[i]) * smoothFactor;
        if (this._smoothBins[i] > peak) peak = this._smoothBins[i];
        energy += this._smoothBins[i];
      }

      this._energy += ((energy / Math.max(1, this._smoothBins.length)) - this._energy) * 0.12;
      this._phase += decayOnly ? 0.006 : 0.018;
      const bars = this._buildReusableBars(this.reducedMotion ? 18 : (this._isMobile() ? 42 : 72));
      if (this._mode === 'holographic') this._drawHolographic(ctx, width, height, bars, decayOnly);
      else this._drawNeonSpectrum(ctx, width, height, bars, decayOnly);
      return peak;
    }

    _drawHolographic(ctx, width, height, bars, decayOnly) {
      const horizon = height * 0.54;
      ctx.fillStyle = 'rgba(5,10,8,0.34)';
      ctx.fillRect(0, 0, width, height);

      // 透视扫描网格：提供深度，但保持低亮度避免抢夺波形焦点。
      ctx.lineWidth = 1;
      ctx.strokeStyle = 'rgba(57,229,140,0.075)';
      for (let i = -6; i <= 6; i++) {
        ctx.beginPath();
        ctx.moveTo(width * 0.5, horizon);
        ctx.lineTo(width * 0.5 + i * width * 0.12, height);
        ctx.stroke();
      }
      for (let i = 0; i < 5; i++) {
        const depth = i / 4;
        const y = horizon + depth * depth * (height - horizon);
        ctx.beginPath();
        ctx.moveTo(0, y);
        ctx.lineTo(width, y);
        ctx.stroke();
      }

      // 中央能量柱从中心向两侧扩散，形成舞台式声场。
      const half = Math.floor(bars.length / 2);
      const laneW = width / bars.length;
      ctx.shadowColor = 'rgba(34,211,238,.7)';
      ctx.shadowBlur = this.reducedMotion ? 0 : 10;
      for (let i = 0; i < bars.length; i++) {
        const source = Math.abs(i - half);
        const value = bars[Math.min(bars.length - 1, source * 2)];
        const pulse = 0.82 + Math.sin(this._phase * 2 + i * 0.24) * 0.18;
        const barH = Math.max(1, value * height * 0.34 * pulse);
        const color = spectrumColor(Math.min(1, value * 0.72 + Math.abs(i - half) / bars.length));
        ctx.fillStyle = rgba(color, 0.22 + value * 0.62);
        ctx.fillRect(i * laneW + laneW * 0.22, horizon - barH, Math.max(1, laneW * 0.56), barH * 2);
      }
      ctx.shadowBlur = 0;

      // 三层相位错开的光丝带，亮度由实时音频能量驱动。
      this._drawWaveRibbon(ctx, width, height, 0, 0.98, decayOnly);
      this._drawWaveRibbon(ctx, width, height, 11, 0.56, decayOnly);
      this._drawWaveRibbon(ctx, width, height, -11, 0.34, decayOnly);

      // 中央脉冲核心与水平激光线。
      const core = 3 + this._energy * 18;
      ctx.shadowColor = 'rgba(57,229,140,.9)';
      ctx.shadowBlur = this.reducedMotion ? 0 : 18 + this._energy * 20;
      ctx.fillStyle = rgba(COLOR_GREEN, 0.5 + Math.min(0.4, this._energy));
      ctx.beginPath();
      ctx.arc(width * 0.5, horizon, core, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = 'rgba(113,255,190,.42)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, horizon);
      ctx.lineTo(width, horizon);
      ctx.stroke();
      ctx.shadowBlur = 0;
    }

    _drawWaveRibbon(ctx, width, height, offset, strength, decayOnly) {
      const data = this._timeDomainData;
      if (!data?.length) return;
      const pointCount = Math.min(data.length, Math.max(20, Math.floor(width / 3)));
      const step = Math.max(1, Math.floor(data.length / pointCount));
      const half = height * 0.54 + offset;
      const scale = height * 0.34 * strength * (decayOnly ? Math.max(0.08, this._energy * 3) : 1);
      ctx.shadowColor = strength > 0.8 ? 'rgba(57,229,140,.95)' : 'rgba(34,211,238,.65)';
      ctx.shadowBlur = this.reducedMotion ? 0 : 8 * strength;
      ctx.beginPath();
      for (let i = 0, point = 0; i < data.length && point < pointCount; i += step, point++) {
        const x = point / Math.max(1, pointCount - 1) * width;
        const carrier = Math.sin(point * 0.075 + this._phase * (2.2 + strength)) * this._energy * 7;
        const y = half + ((data[i] / 255) * 2 - 1) * scale + carrier;
        if (point === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.strokeStyle = strength > 0.8 ? rgba(COLOR_GREEN, 0.86) : rgba(COLOR_CYAN, 0.34 * strength);
      ctx.lineWidth = 0.8 + strength * 2.2;
      ctx.stroke();
      ctx.shadowBlur = 0;
    }

    _drawNeonSpectrum(ctx, width, height, bars, decayOnly) {
      ctx.clearRect(0, 0, width, height);
      const baseline = height * 0.78;
      const barW = width / bars.length;
      const maxH = height * 0.68;

      // 淡入的频段轨道让低能量段仍有仪表质感。
      ctx.fillStyle = 'rgba(57,229,140,.035)';
      for (let i = 0; i < bars.length; i++) {
        ctx.fillRect(i * barW + barW * 0.18, height * 0.1, Math.max(1, barW * 0.64), baseline - height * 0.1);
      }

      ctx.shadowColor = 'rgba(34,211,238,.72)';
      ctx.shadowBlur = this.reducedMotion ? 0 : 9;
      for (let i = 0; i < bars.length; i++) {
        const value = bars[i];
        const h = Math.max(1, value * maxH);
        const x = i * barW + barW * 0.18;
        const w = Math.max(1, barW * 0.64);
        const color = spectrumColor(i / Math.max(1, bars.length - 1));
        this._peaks[i] = Math.max(value, this._peaks[i] - (decayOnly ? 0.025 : 0.009));
        ctx.fillStyle = rgba(color, 0.34 + value * 0.66);
        ctx.fillRect(x, baseline - h, w, h);
        ctx.fillStyle = rgba(color, 0.12 + value * 0.14);
        ctx.fillRect(x, baseline + 3, w, h * 0.22);
        ctx.fillStyle = rgba(color, 0.78);
        ctx.fillRect(x, baseline - this._peaks[i] * maxH - 3, w, 2);
      }
      ctx.shadowBlur = 0;
      ctx.strokeStyle = 'rgba(150,255,207,.22)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, baseline + 1);
      ctx.lineTo(width, baseline + 1);
      ctx.stroke();
    }

    // ── 帧循环 ──

    _tick() {
      this._rafId = null;
      if ((!this._running && !this._decaying) || this._disabled || !this.ctx) return;

      // 页面隐藏时完全停帧，由 visibilitychange 恢复。
      if (document.hidden) return;

      const ctx = this.ctx;
      const width = this._width;
      const height = this._height;

      if (width <= 0 || height <= 0) return;

      this._ensureSampleBuffers();
      const hasData = Boolean(
        this.analyser &&
        typeof this.analyser.getByteFrequencyData === 'function'
      );

      if (this._decaying) {
        const peak = this._drawSpectrum(ctx, width, height, true);
        this._updateParticles();
        this._drawParticles(ctx, width, height);
        if (peak < 0.01 && this._particles.length === 0) {
          this._decaying = false;
          this._fadeOut();
          this._unbindEvents();
          return;
        }
      } else if (!hasData || this.reducedMotion) {
        // 无数据或减少运动：低亮度占位
        ctx.clearRect(0, 0, width, height);
        if (hasData) {
          this.analyser.getByteFrequencyData(this._frequencyData);
          // 静态低亮度频谱
          this._drawStaticPlaceholder(ctx, width, height, this._frequencyData);
        }
      } else {
        this.analyser.getByteFrequencyData(this._frequencyData);
        this._normalizeFrequencyData();
        if (typeof this.analyser.getByteTimeDomainData === 'function') {
          this.analyser.getByteTimeDomainData(this._timeDomainData);
        } else {
          this._timeDomainData.fill(128);
        }
        // 绘制频谱
        this._drawSpectrum(ctx, width, height);

        // 生成粒子（全息模式 + 有能量）
        if (this._mode === 'holographic') {
          let spawned = 0;
          const bars = this._bars;
          for (let i = 0; i < bars.length && spawned < this._maxSpawnPerFrame; i++) {
            if (bars[i] > 0.6) {
              const x = (i / bars.length) * width;
              const y = height / 2 + (Math.random() - 0.5) * height * 0.3;
              this._spawnParticle(x, y, bars[i]);
              spawned++;
            }
          }
          this._updateParticles();
          this._drawParticles(ctx, width, height);
        }
      }

      if (!document.hidden && (this._decaying || (this._running && !this.reducedMotion))) {
        this._rafId = requestAnimationFrame(() => this._tick());
      }
    }

    _drawStaticPlaceholder(ctx, width, height, freqData) {
      // 低亮度静态频谱
      const halfH = height / 2;
      const binLen = freqData.length;
      const barCount = Math.min(binLen, 32);
      const barW = width / barCount;

      ctx.globalAlpha = 0.12;
      for (let i = 0; i < barCount; i++) {
        const idx = Math.floor((i / barCount) * binLen);
        const val = freqData[idx] / 255;
        const barH = val * halfH * 0.5;
        ctx.fillStyle = rgba(COLOR_GREEN, 0.5);
        ctx.fillRect(i * barW + 1, halfH - barH, Math.max(1, barW - 2), barH * 2);
      }
      ctx.globalAlpha = 1;
    }
  }

  // ── 导出 ──

  const exports = {
    OrzAudioVisualizer,
    normalizeBins,
    buildMirroredBars,
    buildWavePoints,
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = exports;
  } else {
    globalThis.OrzAudioVisualizer = OrzAudioVisualizer;
    globalThis.normalizeBins = normalizeBins;
    globalThis.buildMirroredBars = buildMirroredBars;
    globalThis.buildWavePoints = buildWavePoints;
  }
})();
