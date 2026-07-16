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
        this._streamActive = false;
        this._streamGen = 0;

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
                    script.src = '/audio/orz_audio.js?v=' + Date.now();
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
        // 标记流式中止——让后台的 _renderAndPlayStreaming 循环尽快退出
        this._streamActive = false;
        this._streamGen++;

        // 停止 WASM 渲染
        if (this._washProgressRAF) {
            cancelAnimationFrame(this._washProgressRAF);
            this._washProgressRAF = null;
        }
        // 停止流式播放的所有 AudioBufferSourceNode
        if (this._streamSources) {
            for (const src of this._streamSources) {
                try { src.stop(); } catch(e) {}
                try { src.disconnect(); } catch(e) {}
            }
            this._streamSources = null;
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
                // 前置检查格式是否被 WASM 支持
                const supported = this.wasmKit._orz_audio_can_decode
                    ? this.wasmKit.ccall('orz_audio_can_decode', 'number', ['string'], [format])
                    : 0;
                if (!supported) {
                    throw new Error(`WASM: format "${format}" not supported by WASM module`);
                }

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
     * 使用 WASM 模块解码并播放（统一 API）
     */
    async _playWithWasm(url, format) {
        let step = 'fetch';
        try {
            step = 'fetch';
            const resp = await fetch(url);
            if (!resp.ok) throw new Error(`HTTP ${resp.status} ${resp.statusText}`);
            step = 'arrayBuffer';
            const buf = await resp.arrayBuffer();
            step = 'Uint8Array';
            const data = new Uint8Array(buf);
            console.log(`WASM: fetched ${data.length} bytes for ${format}`);

            step = 'malloc_fmt';
            const fmtLen = this.wasmKit.lengthBytesUTF8(format) + 1;
            const fmtPtr = this.wasmKit._malloc(fmtLen);
            if (!fmtPtr) throw new Error('malloc fmt failed');
            step = 'stringToUTF8';
            this.wasmKit.stringToUTF8(format, fmtPtr, fmtLen);

            step = 'malloc_data';
            const dataPtr = this.wasmKit._malloc(data.length);
            if (!dataPtr) throw new Error('malloc data failed');
            step = 'copy_data';
            this.wasmKit.HEAPU8.set(data, dataPtr);

            step = 'orz_load';
            const loaded = this.wasmKit._orz_load(fmtPtr, dataPtr, data.length);
            this.wasmKit._free(fmtPtr);
            this.wasmKit._free(dataPtr);
            console.log('WASM: orz_load =', loaded);

            if (!loaded) {
                this.wasmKit._orz_destroy();
                throw new Error('WASM: failed to load module');
            }

            step = 'get_duration';
            const duration = this.wasmKit._orz_get_duration();
            console.log('WASM: duration =', duration);
            if (duration > 0) this.duration = duration;

            step = 'get_format_info';
            const sampleRate = this.wasmKit._orz_get_sample_rate() || 44100;
            const channels = this.wasmKit._orz_get_channels() || 2;
            console.log('WASM: sr=', sampleRate, 'ch=', channels);

            const totalFrames = Math.ceil(duration * sampleRate);
            if (totalFrames <= 0 || totalFrames > 3600 * sampleRate) {
                this.wasmKit._orz_destroy();
                throw new Error(`WASM: invalid duration ${duration}s (frames ${totalFrames})`);
            }

            // 流式渲染 + 播放：小块渲染 → 立即通过 AudioContext 调度播放
            step = 'streaming';
            await this._renderAndPlayStreaming(sampleRate, channels);
        } catch (e) {
            console.error(`WASM decode failed at step "${step}":`, e.message, e);
            try { this.wasmKit._orz_destroy(); } catch(_) {}
            throw e;
        }
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

    /**
     * 流式渲染 + 播放：逐小块渲染并通过 AudioContext 调度播放
     *
     * 每次 orz_render 处理小块帧（~2048 帧），创建 AudioBuffer，
     * 使用 BufferSourceNode.start(playTime) 调度到准确时间播放。
     * 块之间 await 让出主线程，浏览器保持响应。
     */
    async _renderAndPlayStreaming(sampleRate, channels) {
        const CHUNK_FRAMES = Math.min(2048, Math.max(512, Math.round(sampleRate / 20)));
        this._streamSources = [];  // 清空并保持引用，stop() 能直接操作
        const myGen = ++this._streamGen;
        this._streamActive = true;

        let firstPlayTime = this.audioCtx.currentTime;
        let playTime = firstPlayTime;
        let totalRendered = 0;

        while (this._streamActive && this._streamGen === myGen) {
            const chunkPtr = this.wasmKit._malloc(CHUNK_FRAMES * channels * 4);
            if (!chunkPtr) break;

            const frames = this.wasmKit._orz_render(chunkPtr, CHUNK_FRAMES);
            if (frames <= 0) {
                this.wasmKit._free(chunkPtr);
                break;
            }

            // 从 WASM heap 拷贝（free 前必须拷贝）
            const view = new Float32Array(
                this.wasmKit.HEAPU8.buffer, chunkPtr, frames * channels
            );
            const copy = new Float32Array(view);
            this.wasmKit._free(chunkPtr);

            // 创建 AudioBuffer
            const audioBuffer = this.audioCtx.createBuffer(channels, frames, sampleRate);
            if (channels === 2) {
                const left = audioBuffer.getChannelData(0);
                const right = audioBuffer.getChannelData(1);
                for (let i = 0; i < frames; i++) {
                    left[i] = copy[i * 2];
                    right[i] = copy[i * 2 + 1];
                }
            } else {
                audioBuffer.getChannelData(0).set(copy);
            }

            // 调度播放 — 直接注册到 this._streamSources 以便 stop() 能立即停止
            const source = this.audioCtx.createBufferSource();
            source.buffer = audioBuffer;
            source.connect(this.audioCtx.destination);
            source.start(playTime);
            this._streamSources.push(source);

            playTime += frames / sampleRate;
            totalRendered += frames;

            // 让出主线程，保持 UI 响应
            await new Promise(r => setTimeout(r, 0));
        }

        // 如果被 stop() 中断（新歌已开始），直接退出
        if (!this._streamActive || this._streamGen !== myGen) {
            this.wasmKit._orz_destroy();
            return;
        }

        if (totalRendered <= 0) {
            this.wasmKit._orz_destroy();
            throw new Error('WASM: no audio rendered');
        }

        // 用实际渲染帧数更新时长
        this.duration = totalRendered / sampleRate;

        // 清理 WASM 解码器
        this.wasmKit._orz_destroy();

        this.currentSource = (this._streamSources && this._streamSources[this._streamSources.length - 1]) || null;
        this.isPlaying = true;

        // 时间进度跟踪
        const tick = () => {
            if (!this.isPlaying) return;
            this.currentTime = Math.min(
                this.audioCtx.currentTime - firstPlayTime,
                this.duration
            );
            if (this.onTimeUpdate) {
                this.onTimeUpdate(this.currentTime, this.duration);
            }
            if (this.currentTime >= this.duration) {
                this.isPlaying = false;
                this._onEnded();
                return;
            }
            this._washProgressRAF = requestAnimationFrame(tick);
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
        // WASM 路径播放时，audio element 的 error 来自之前播放的 fallback 尝试，无害
        if (this._usingWasm) return;
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
