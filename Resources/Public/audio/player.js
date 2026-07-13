/**
 * OrzAudioPlayer — 统一音频播放引擎
 *
 * 播放策略（自动选择）:
 *   directFile  → <audio> 元素
 *   wasmDecode  → OrzAudioKit WASM 解码 (fallback 到 AudioContext.decodeAudioData)
 *   serverDecode → <audio> 元素 (服务端已转码为 WAV)
 *
 * 依赖:
 *   - /audio/orz_audio.js (OrzAudioKit WASM) — 可选，不存在则自动降级
 */

class OrzAudioPlayer {
    constructor() {
        this.audioEl = new Audio();
        this.audioCtx = null;
        this.wasmKit = null;        // OrzAudioKit WASM 模块实例
        this.wasmReady = false;     // WASM 是否已初始化
        this.currentSource = null;  // AudioBufferSourceNode (WASM 渲染路径)
        this.analyser = null;

        // 状态
        this.isPlaying = false;
        this.currentTime = 0;
        this.duration = 0;
        this.volume = 0.7;
        this._wasmLoadAttempted = false;
        this._wasmLoadPromise = null;
        this._washProgressRAF = null;

        // 配置
        this.sampleRate = 48000;
        this.onEnded = null;
        this.onTimeUpdate = null;
        this.onError = null;

        // 初始化 audio 元素
        this.audioEl.volume = this.volume;
        this.audioEl.addEventListener('timeupdate', () => this._onAudioTimeUpdate());
        this.audioEl.addEventListener('ended', () => this._onEnded());
        this.audioEl.addEventListener('error', (e) => this._onAudioError(e));
    }

    // ── WASM 初始化 ──

    /**
     * 尝试加载 OrzAudioKit WASM 模块
     */
    async initWasm() {
        if (this._wasmLoadAttempted) return this._wasmLoadPromise;
        this._wasmLoadAttempted = true;

        this._wasmLoadPromise = (async () => {
            try {
                if (typeof OrzAudioKit === 'undefined') {
                    // 动态加载
                    const script = document.createElement('script');
                    script.src = '/audio/orz_audio.js';
                    await new Promise((resolve, reject) => {
                        script.onload = resolve;
                        script.onerror = reject;
                        document.head.appendChild(script);
                    });
                }

                // 实例化 WASM 模块
                this.wasmKit = await OrzAudioKit();
                this.wasmReady = true;
                console.log('OrzAudioKit WASM loaded');
                return true;
            } catch (e) {
                console.warn('OrzAudioKit WASM not available, using fallback:', e.message);
                this.wasmReady = false;
                return false;
            }
        })();

        return this._wasmLoadPromise;
    }

    /**
     * WASM 就绪状态
     */
    get canUseWasm() {
        return this.wasmReady && this.wasmKit !== null;
    }

    // ── 播放接口 ──

    /**
     * 播放歌曲
     * @param {Object} song - { id, streamUrl, rawUrl, playStrategy, fileFormat, ... }
     */
    async play(song) {
        this.stop();

        this.currentSong = song;
        this.isPlaying = false;
        this.currentTime = 0;
        this.duration = 0;

        const strategy = song.playStrategy || 'directFile';

        try {
            switch (strategy) {
                case 'directFile':
                case 'serverDecode':
                    await this._playDirect(song.streamUrl || song.rawUrl);
                    break;

                case 'wasmDecode':
                    await this._playWasm(song.streamUrl || song.rawUrl, song.fileFormat);
                    break;

                default:
                    await this._playDirect(song.streamUrl || song.rawUrl);
            }
        } catch (e) {
            console.error('Playback error:', e);
            // 最后尝试: server decode 降级
            if (strategy !== 'serverDecode') {
                try {
                    await this._playDirect(song.streamUrl || song.rawUrl);
                } catch (fallbackErr) {
                    if (this.onError) this.onError(fallbackErr);
                }
            } else {
                if (this.onError) this.onError(e);
            }
        }
    }

    /**
     * 暂停/继续
     */
    togglePlay() {
        if (!this.currentSong) return;

        if (this._usingWasm) {
            if (this.isPlaying) {
                this.audioCtx?.suspend();
                this.isPlaying = false;
            } else {
                this.audioCtx?.resume();
                this.isPlaying = true;
            }
        } else {
            if (this.isPlaying) {
                this.audioEl.pause();
                this.isPlaying = false;
            } else {
                this.audioEl.play().then(() => {
                    this.isPlaying = true;
                }).catch(e => console.error(e));
            }
        }
    }

    /**
     * 停止播放
     */
    stop() {
        // 停止 WASM 渲染
        if (this._washProgressRAF) {
            cancelAnimationFrame(this._washProgressRAF);
            this._washProgressRAF = null;
        }
        if (this.currentSource) {
            try { this.currentSource.stop(); } catch(e) {}
            this.currentSource.disconnect();
            this.currentSource = null;
        }

        // 停止 audio 元素
        this.audioEl.pause();
        this.audioEl.src = '';

        this.isPlaying = false;
        this._usingWasm = false;
    }

    /**
     * 跳转到指定位置 (0-1)
     */
    seek(position) {
        if (this._usingWasm) {
            // WASM 渲染路径不支持 seek（简化实现）
            this.currentTime = position * this.duration;
        } else if (this.audioEl.duration) {
            this.audioEl.currentTime = position * this.audioEl.duration;
        }
    }

    /**
     * 设置音量
     */
    setVolume(vol) {
        this.volume = Math.max(0, Math.min(1, vol));
        this.audioEl.volume = this.volume;
    }

    // ── 内部方法 ──

    /**
     * 直接文件播放 (directFile / serverDecode)
     */
    async _playDirect(url) {
        this._usingWasm = false;
        this.audioEl.src = url;
        await this.audioEl.play();
        this.isPlaying = true;
        this.duration = this.audioEl.duration || 0;
    }

    /**
     * WASM 解码播放 (wasmDecode)
     */
    async _playWasm(url, format) {
        this._usingWasm = true;

        // 初始化 AudioContext（需用户交互后创建）
        if (!this.audioCtx) {
            this.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        }
        if (this.audioCtx.state === 'suspended') {
            await this.audioCtx.resume();
        }

        // 尝试 WASM 解码
        if (this.canUseWasm) {
            try {
                await this._playWithWasm(url, format);
                return;
            } catch (e) {
                console.warn('WASM decode failed, falling back:', e.message);
            }
        }

        // Fallback: AudioContext.decodeAudioData
        await this._playWithAudioContext(url);
    }

    /**
     * 使用 WASM 模块解码并播放
     */
    async _playWithWasm(url, format) {
        const resp = await fetch(url);
        const buf = await resp.arrayBuffer();
        const data = new Uint8Array(buf);

        // 调用 WASM 加载模块
        // 注意：Emscripten 6.0+ 不将 HEAPU8/HEAPF32 暴露为 Module 属性，
        // 因此使用 Module.setValue/getValue（闭包函数，可访问内部堆视图）
        const ptr = this.wasmKit._malloc(data.length);
        for (let i = 0; i < data.length; i++) {
            this.wasmKit.setValue(ptr + i, data[i], 'i8');
        }

        const loaded = this.wasmKit._openmpt_load(ptr, data.length);
        this.wasmKit._free(ptr);

        if (!loaded) throw new Error('WASM: failed to load module');

        const duration = this.wasmKit._openmpt_get_duration();
        if (duration > 0) this.duration = duration;

        // 渲染 PCM
        const sampleRate = this.wasmKit._openmpt_get_sample_rate() || 48000;
        const channels = this.wasmKit._openmpt_get_channels() || 2;
        const totalFrames = Math.ceil(duration * sampleRate);

        const renderPtr = this.wasmKit._malloc(totalFrames * channels * 4); // float32 = 4 bytes
        const rendered = this.wasmKit._openmpt_render(renderPtr, totalFrames);

        if (rendered <= 0) {
            this.wasmKit._free(renderPtr);
            this.wasmKit._openmpt_destroy();
            throw new Error('WASM: no audio rendered');
        }

        // 使用 getValue 逐个读取渲染后的浮点样本
        const actualFrames = rendered;
        const audioSamples = new Float32Array(actualFrames * channels);
        for (let i = 0; i < audioSamples.length; i++) {
            audioSamples[i] = this.wasmKit.getValue(renderPtr + i * 4, 'float');
        }

        this.wasmKit._free(renderPtr);
        this.wasmKit._openmpt_destroy();

        // 创建 AudioBuffer 并播放
        const audioBuffer = this.audioCtx.createBuffer(
            channels, actualFrames, sampleRate
        );

        if (channels === 2) {
            const left = audioBuffer.getChannelData(0);
            const right = audioBuffer.getChannelData(1);
            for (let i = 0; i < actualFrames; i++) {
                left[i] = audioSamples[i * 2];
                right[i] = audioSamples[i * 2 + 1];
            }
        } else {
            audioBuffer.getChannelData(0).set(audioSamples);
        }

        this._playAudioBuffer(audioBuffer);
    }

    /**
     * 使用 AudioContext.decodeAudioData 播放
     */
    async _playWithAudioContext(url) {
        const resp = await fetch(url);
        const buf = await resp.arrayBuffer();
        const audioBuffer = await this.audioCtx.decodeAudioData(buf);
        this._playAudioBuffer(audioBuffer);
    }

    /**
     * 播放 AudioBuffer
     */
    _playAudioBuffer(buffer) {
        if (this.currentSource) {
            try { this.currentSource.stop(); } catch(e) {}
            this.currentSource.disconnect();
        }

        this.currentSource = this.audioCtx.createBufferSource();
        this.currentSource.buffer = buffer;
        this.currentSource.connect(this.audioCtx.destination);
        this.currentSource.start();
        this.isPlaying = true;
        this.duration = buffer.duration;

        const startTime = this.audioCtx.currentTime;
        const tick = () => {
            if (!this.isPlaying) return;
            this.currentTime = this.audioCtx.currentTime - startTime;
            if (this.onTimeUpdate) this.onTimeUpdate(this.currentTime, this.duration);
            if (this.currentTime < this.duration) {
                this._washProgressRAF = requestAnimationFrame(tick);
            } else {
                this._onEnded();
            }
        };
        this._washProgressRAF = requestAnimationFrame(tick);
    }

    // ── 事件处理 ──

    _onAudioTimeUpdate() {
        if (this.audioEl.duration) {
            this.currentTime = this.audioEl.currentTime;
            this.duration = this.audioEl.duration;
            if (this.onTimeUpdate) {
                this.onTimeUpdate(this.currentTime, this.duration);
            }
        }
    }

    _onEnded() {
        if (this.onEnded) this.onEnded();
    }

    _onAudioError(e) {
        console.error('Audio element error:', e);
        if (this.onError) this.onError(e);
    }

    /**
     * 释放资源
     */
    dispose() {
        this.stop();
        if (this.audioCtx) {
            this.audioCtx.close();
            this.audioCtx = null;
        }
    }
}
