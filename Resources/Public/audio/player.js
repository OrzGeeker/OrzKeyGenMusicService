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
        this.decoderHandle = 0;     // 当前播放独占的 C decoder handle
        this.wasmReady = false;     // WASM 是否已初始化
        this.currentSource = null;  // AudioBufferSourceNode (WASM 渲染路径)
        this.analyser = null;
        this.masterGain = null;     // shared volume control for every Web Audio path

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
        this._playGen = 0;
        this._decoderWorker = null;
        this._workerReject = null;
        this._workerRejectOwner = null;
        this._fetchController = null;
        this._workletNode = null;
        this._workerControl = null;
        this._workletModulePromise = null;
        this.diagnostics = { firstFrameMs: 0, decodeRate: 0, underruns: 0,
            peakBufferMs: 0, memoryPeakBytes: 0 };

        // 配置
        this.sampleRate = 48000;
        this.onEnded = null;
        this.onTimeUpdate = null;
        this.onError = null;
        this.onPlaybackStateChange = null;
        this._pendingDirectSeek = null;
        this._audioBuffer = null;
        this._audioBufferClockStart = 0;

        // 初始化 audio 元素
        this.audioEl.volume = this.volume;
        this.audioEl.addEventListener('timeupdate', () => this._onAudioTimeUpdate());
        this.audioEl.addEventListener('loadedmetadata', () => {
            if (this._pendingDirectSeek !== null && Number.isFinite(this.audioEl.duration)) {
                this.audioEl.currentTime = this._pendingDirectSeek * this.audioEl.duration;
                this._pendingDirectSeek = null;
            }
        });
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
                if (crossOriginIsolated && typeof SharedArrayBuffer !== 'undefined' &&
                    typeof AudioWorkletNode !== 'undefined') {
                    // Worker imports the format-specific bundle on demand.
                    this.wasmReady = true;
                    return true;
                }
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
        const playGen = this._playGen;

        this.currentSong = song;
        this.isPlaying = false;
        this.currentTime = 0;
        this.duration = 0;

        const strategy = song.playStrategy || 'directFile';

        try {
            switch (strategy) {
                case 'directFile':
                case 'serverDecode':
                    await this._playDirect(song.streamUrl || song.rawUrl, playGen);
                    break;

                case 'wasmDecode':
                    await this._playWasm(song.streamUrl || song.rawUrl, song.fileFormat, song.subsong || 0, playGen);
                    break;

                default:
                    await this._playDirect(song.streamUrl || song.rawUrl, playGen);
            }
        } catch (e) {
            if (playGen !== this._playGen || e?.name === 'AbortError') return;
            console.error('Playback error:', e);
            // 最后尝试: server decode 降级
            if (strategy !== 'serverDecode') {
                try {
                    await this._playDirect(song.streamUrl || song.rawUrl, playGen);
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
    async togglePlay() {
        if (!this.currentSong) return false;

        if (this._usingWasm) {
            if (this.isPlaying) {
                await this.audioCtx?.suspend();
                this._setPlaying(false);
            } else {
                await this.audioCtx?.resume();
                this._setPlaying(this.audioCtx?.state === 'running');
            }
        } else {
            if (this.isPlaying) {
                this.audioEl.pause();
                this._setPlaying(false);
            } else {
                try {
                    await this.audioEl.play();
                    this._setPlaying(true);
                } catch (error) {
                    this._setPlaying(false);
                    if (this.onError) this.onError(error);
                }
            }
        }
        return this.isPlaying;
    }

    /**
     * 停止播放
     */
    stop() {
        this._playGen++;
        this._fetchController?.abort();
        this._fetchController = null;
        // 标记流式中止——让后台的 _renderAndPlayStreaming 循环尽快退出
        this._streamActive = false;
        this._streamGen++;
        if (this._workerControl) {
            Atomics.store(this._workerControl, 2, 4);
            Atomics.store(this._workerControl, 3, this._streamGen);
            this._workerControl = null;
        }
        if (this._decoderWorker) {
            if (this._workerReject && this._workerRejectOwner === this._decoderWorker) {
                this._workerReject(this._cancelledPlayback());
            }
            this._workerReject = null;
            this._workerRejectOwner = null;
            this._shutdownWorker(this._decoderWorker, this._streamGen);
            this._decoderWorker = null;
        }
        if (this._workletNode) {
            this._workletNode.disconnect();
            this._workletNode = null;
        }

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
        this._destroyWasmDecoder();

        // 停止 audio 元素
        this.audioEl.pause();
        this.audioEl.src = '';

        this._setPlaying(false);
        this._usingWasm = false;
        this._audioBuffer = null;
    }

    /**
     * 跳转到指定位置 (0-1)
     */
    seek(position) {
        position = Math.max(0, Math.min(1, Number(position) || 0));
        const target = position * this.duration;
        if (this._usingWasm) {
            if (this._decoderWorker) {
                this._decoderWorker.postMessage({ type: 'seek', generation: this._streamGen,
                    positionMs: Math.round(target * 1000) });
                return true;
            }
            if (this._audioBuffer) {
                this._restartAudioBufferAt(target);
                return true;
            }
            return false;
        } else if (Number.isFinite(this.audioEl.duration) && this.audioEl.duration > 0) {
            this.audioEl.currentTime = position * this.audioEl.duration;
            return true;
        }
        this._pendingDirectSeek = position;
        return true;
    }

    /**
     * 设置音量
     */
    setVolume(vol) {
        const value = Number(vol);
        this.volume = Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : this.volume;
        this.audioEl.volume = this.volume;
        const gain = this._ensureMasterGain();
        if (gain) {
            gain.gain.cancelScheduledValues?.(this.audioCtx.currentTime);
            gain.gain.setValueAtTime?.(this.volume, this.audioCtx.currentTime);
            // Minimal test/browser implementations may only expose `.value`.
            gain.gain.value = this.volume;
        }
    }

    _ensureMasterGain() {
        if (!this.audioCtx || typeof this.audioCtx.createGain !== 'function') return null;
        if (!this.masterGain) {
            this.masterGain = this.audioCtx.createGain();
            this.masterGain.gain.value = this.volume;
            this.masterGain.connect(this.audioCtx.destination);
        }
        return this.masterGain;
    }

    _outputNode() {
        return this._ensureMasterGain() || this.audioCtx.destination;
    }

    // ── 内部方法 ──

    /**
     * 直接文件播放 (directFile / serverDecode)
     */
    async _playDirect(url, playGen = this._playGen) {
        this._assertCurrentPlayback(playGen);
        this._usingWasm = false;
        this.audioEl.src = url;
        await this.audioEl.play();
        this._assertCurrentPlayback(playGen);
        this._setPlaying(true);
        this.duration = this.audioEl.duration || 0;
    }

    /**
     * WASM 解码播放 (wasmDecode)
     */
    async _playWasm(url, format, subsong = 0, playGen = this._playGen) {
        this._assertCurrentPlayback(playGen);
        this._usingWasm = true;

        // 初始化 AudioContext（需用户交互后创建）
        if (!this.audioCtx) {
            this.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        }
        this._ensureMasterGain();
        if (this.audioCtx.state === 'suspended') {
            // Do not block decoder priming on an AudioContext resume promise:
            // some browsers keep it pending until the output device is ready.
            // Calling resume synchronously preserves user activation while the
            // Worker fills its initial ring in parallel.
            this.audioCtx.resume().catch(() => {});
        }

        if (crossOriginIsolated && typeof SharedArrayBuffer !== 'undefined' && this.audioCtx.audioWorklet) {
            await this._playWithWorker(url, format, subsong, playGen);
            return;
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

                await this._playWithWasm(url, format, subsong);
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
    async _playWithWasm(url, format, subsong = 0) {
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

            step = 'orz_decoder_create';
            const decoderHandle = this.wasmKit._orz_decoder_create(fmtPtr, dataPtr, data.length);
            this.wasmKit._free(fmtPtr);
            this.wasmKit._free(dataPtr);
            console.log('WASM: decoder handle =', decoderHandle);

            if (!decoderHandle) {
                throw new Error('WASM: failed to load module');
            }
            this.decoderHandle = decoderHandle;
            if (subsong > 0 && this.wasmKit._orz_decoder_select_subsong(decoderHandle, subsong) !== 0) {
                throw new Error(`WASM: subsong ${subsong} is not supported`);
            }

            step = 'get_duration';
            const duration = this.wasmKit._orz_decoder_get_duration(decoderHandle);
            console.log('WASM: duration =', duration);
            if (duration > 0) this.duration = duration;

            step = 'get_format_info';
            const sampleRate = this.wasmKit._orz_decoder_get_sample_rate(decoderHandle) || 44100;
            const channels = this.wasmKit._orz_decoder_get_channels(decoderHandle) || 2;
            console.log('WASM: sr=', sampleRate, 'ch=', channels);

            const totalFrames = Math.ceil(duration * sampleRate);
            if (totalFrames <= 0 || totalFrames > 3600 * sampleRate) {
                this._destroyWasmDecoder();
                throw new Error(`WASM: invalid duration ${duration}s (frames ${totalFrames})`);
            }

            // 流式渲染 + 播放：小块渲染 → 立即通过 AudioContext 调度播放
            step = 'streaming';
            await this._renderAndPlayStreaming(sampleRate, channels);
        } catch (e) {
            console.error(`WASM decode failed at step "${step}":`, e.message, e);
            this._destroyWasmDecoder();
            throw e;
        }
    }

    async _playWithWorker(url, format, subsong = 0, playGen = this._playGen) {
        const startedAt = performance.now();
        const fetchController = new AbortController();
        this._fetchController = fetchController;
        let data;
        try {
            const response = await fetch(url, { signal: fetchController.signal });
            if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
            data = await response.arrayBuffer();
        } finally {
            if (this._fetchController === fetchController) this._fetchController = null;
        }
        this._assertCurrentPlayback(playGen);
        const generation = ++this._streamGen;
        const channels = 2;
        const capacityFrames = Math.ceil(44100 * 0.5) + 1;
        const startFrames = Math.ceil(44100 * 0.15);
        const controlBuffer = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 8);
        const sampleBuffer = new SharedArrayBuffer(Float32Array.BYTES_PER_ELEMENT * capacityFrames * channels);
        this.diagnostics.peakBufferMs = capacityFrames / 44.1;
        this.diagnostics.memoryPeakBytes = controlBuffer.byteLength + sampleBuffer.byteLength;
        const control = new Int32Array(controlBuffer);
        Atomics.store(control, 3, generation);
        this._workerControl = control;
        const worker = new Worker('/audio/orz-decoder-worker.js?v=20260717-controls-seek-v1');
        this._decoderWorker = worker;
        let workletNode = null;

        const ready = new Promise((resolve, reject) => {
            this._workerReject = reject;
            this._workerRejectOwner = worker;
            worker.onmessage = async event => {
                const message = event.data;
                if (message.generation !== generation) return;
                if (message.type === 'ready') {
                    if (playGen !== this._playGen) return reject(this._cancelledPlayback());
                    this.duration = message.duration;
                    await this._ensureWorkletModule();
                    if (playGen !== this._playGen) return reject(this._cancelledPlayback());
                    workletNode = new AudioWorkletNode(this.audioCtx, 'orz-ring-buffer', {
                        numberOfOutputs: 1,
                        outputChannelCount: [channels],
                        processorOptions: { control: controlBuffer, samples: sampleBuffer, capacityFrames,
                            channels, generation, sourceSampleRate: message.sampleRate }
                    });
                    this._workletNode = workletNode;
                    workletNode.connect(this._outputNode());
                    resolve();
                } else if (message.type === 'started') {
                    this.diagnostics.firstFrameMs = performance.now() - startedAt;
                    this._setPlaying(this.audioCtx.state === 'running');
                } else if (message.type === 'seeked') {
                    this.currentTime = message.positionMs / 1000;
                    this._workerTimeOffset = this.currentTime;
                    this._workerClockStart = this.audioCtx.currentTime;
                    if (this.onTimeUpdate) this.onTimeUpdate(this.currentTime, this.duration);
                } else if (message.type === 'ended') {
                    this.diagnostics.decodeRate = message.decodeRate;
                } else if (message.type === 'error') reject(new Error(message.message));
            };
            worker.onerror = event => reject(new Error(event.message));
        });
        const moduleJs = ['bp', 'mid', 'ym'].includes(format)
            ? '/audio/orz_audio_builtin.js?v=20260717-controls-seek-v1'
            : '/audio/orz_audio.js?v=20260717-controls-seek-v1';
        worker.postMessage({ type: 'decode', generation, format, subsong, moduleJs, data, control: controlBuffer,
            samples: sampleBuffer, capacityFrames, channels, startFrames }, [data]);
        try {
            await ready;
            if (this._workerRejectOwner === worker) {
                this._workerReject = null;
                this._workerRejectOwner = null;
            }
        } catch (error) {
            if (this._workerRejectOwner === worker) {
                this._workerReject = null;
                this._workerRejectOwner = null;
            }
            worker.terminate();
            if (this._decoderWorker === worker) this._decoderWorker = null;
            if (this._workerControl === control) this._workerControl = null;
            workletNode?.disconnect();
            if (this._workletNode === workletNode) this._workletNode = null;
            throw error;
        }

        this._workerClockStart = this.audioCtx.currentTime;
        this._workerTimeOffset = 0;
        const tick = () => {
            if (this._streamGen !== generation) return;
            this.currentTime = Math.min(this._workerTimeOffset + this.audioCtx.currentTime - this._workerClockStart,
                this.duration || Infinity);
            this.diagnostics.underruns = Atomics.load(control, 4);
            if (this.onTimeUpdate) this.onTimeUpdate(this.currentTime, this.duration);
            if (Atomics.load(control, 2) === 2 && this.currentTime >= this.duration) return this._onEnded();
            if (Atomics.load(control, 2) === 3) return;
            this._washProgressRAF = requestAnimationFrame(tick);
        };
        this._washProgressRAF = requestAnimationFrame(tick);
    }

    _shutdownWorker(worker, stopGeneration) {
        let terminated = false;
        const terminate = () => {
            if (terminated) return;
            terminated = true;
            clearTimeout(timeout);
            worker.terminate();
        };
        const timeout = setTimeout(terminate, 250);
        worker.onmessage = event => {
            if (event.data?.type === 'stopped' && event.data.generation === stopGeneration) terminate();
        };
        try { worker.postMessage({ type: 'stop', generation: stopGeneration }); }
        catch (_) { terminate(); }
    }

    async _ensureWorkletModule() {
        if (!this._workletModulePromise) {
            this._workletModulePromise = this.audioCtx.audioWorklet
                .addModule('/audio/orz-audio-worklet.js?v=20260717-ym-zero-period')
                .catch(error => {
                    this._workletModulePromise = null;
                    throw error;
                });
        }
        return this._workletModulePromise;
    }

    _cancelledPlayback() {
        return new DOMException('Playback superseded by a newer request', 'AbortError');
    }

    _assertCurrentPlayback(playGen) {
        if (playGen !== this._playGen) throw this._cancelledPlayback();
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
    _playAudioBuffer(buffer, offset = 0) {
        if (this.currentSource) {
            try { this.currentSource.stop(); } catch(e) {}
            this.currentSource.disconnect();
        }

        this._audioBuffer = buffer;
        this.currentSource = this.audioCtx.createBufferSource();
        this.currentSource.buffer = buffer;
        this.currentSource.connect(this._outputNode());
        this.currentSource.start(0, offset);
        this._setPlaying(true);
        this.duration = buffer.duration;

        this._audioBufferClockStart = this.audioCtx.currentTime - offset;
        const tick = () => {
            if (!this.isPlaying) return;
            this.currentTime = this.audioCtx.currentTime - this._audioBufferClockStart;
            if (this.onTimeUpdate) this.onTimeUpdate(this.currentTime, this.duration);
            if (this.currentTime < this.duration) {
                this._washProgressRAF = requestAnimationFrame(tick);
            } else {
                this._onEnded();
            }
        };
        this._washProgressRAF = requestAnimationFrame(tick);
    }

    _restartAudioBufferAt(offset) {
        if (!this._audioBuffer) return false;
        const wasPlaying = this.isPlaying;
        if (this.currentSource) {
            try { this.currentSource.stop(); } catch (_) {}
            this.currentSource.disconnect();
        }
        this.currentSource = this.audioCtx.createBufferSource();
        this.currentSource.buffer = this._audioBuffer;
        this.currentSource.connect(this._outputNode());
        this.currentSource.start(0, offset);
        this.currentTime = offset;
        this._audioBufferClockStart = this.audioCtx.currentTime - offset;
        if (!wasPlaying) Promise.resolve(this.audioCtx.suspend()).catch(() => {});
        if (this.onTimeUpdate) this.onTimeUpdate(this.currentTime, this.duration);
        return true;
    }

    /**
     * 流式渲染 + 播放：逐小块渲染并通过 AudioContext 调度播放
     *
     * 每次 orz_render 处理小块帧（~2048 帧），创建 AudioBuffer，
     * 使用 BufferSourceNode.start(playTime) 调度到准确时间播放。
     * 块之间 await 让出主线程，浏览器保持响应。
     */
    async _renderAndPlayStreaming(sampleRate, channels) {
        const CHUNK_FRAMES = Math.min(22050, Math.max(1024, Math.round(sampleRate / 2)));
        this._streamSources = [];  // 清空并保持引用，stop() 能直接操作
        const myGen = ++this._streamGen;
        this._streamActive = true;

        let firstPlayTime = this.audioCtx.currentTime;
        let playTime = firstPlayTime;
        let totalRendered = 0;
        // 安全上限：最多渲染 duration 的 1.5 倍帧数，防止解码器不返回 0 时无限循环
        const maxFrames = Math.ceil(this.duration * sampleRate * 1.5);
        // 渲染起始时间，用于检测渲染耗时是否远超实时导致卡死
        const renderStart = Date.now();

        while (this._streamActive && this._streamGen === myGen) {
            if (totalRendered >= maxFrames) {
                console.log('WASM: render complete (cap)');
                break;
            }
            // 如果渲染耗时超过 60 秒（实时），主动中止以防页面卡死
            if (Date.now() - renderStart > 60000) {
                console.log('WASM: render timeout (60s)');
                break;
            }
            const chunkPtr = this.wasmKit._malloc(CHUNK_FRAMES * channels * 4);
            if (!chunkPtr) break;

            const frames = this.wasmKit._orz_decoder_render(this.decoderHandle, chunkPtr, CHUNK_FRAMES);
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
            source.connect(this._outputNode());
            source.start(playTime);
            this._streamSources.push(source);

            playTime += frames / sampleRate;
            totalRendered += frames;

            // 让出主线程，保持 UI 响应
            await new Promise(r => setTimeout(r, 0));
        }

        // 如果被 stop() 中断（新歌已开始），直接退出
        if (!this._streamActive || this._streamGen !== myGen) {
            this._destroyWasmDecoder();
            return;
        }

        if (totalRendered <= 0) {
            this._destroyWasmDecoder();
            throw new Error('WASM: no audio rendered');
        }

        // 用实际渲染帧数更新时长
        this.duration = totalRendered / sampleRate;

        // 清理 WASM 解码器
        this._destroyWasmDecoder();

        this.currentSource = (this._streamSources && this._streamSources[this._streamSources.length - 1]) || null;
        this._setPlaying(true);

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
                this._setPlaying(false);
                this._onEnded();
                return;
            }
            this._washProgressRAF = requestAnimationFrame(tick);
        };
        this._washProgressRAF = requestAnimationFrame(tick);
    }

    _destroyWasmDecoder() {
        if (!this.decoderHandle || !this.wasmKit) return;
        try { this.wasmKit._orz_decoder_destroy(this.decoderHandle); } catch (_) {}
        this.decoderHandle = 0;
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
        this._setPlaying(false);
        if (this.onEnded) this.onEnded();
    }

    _setPlaying(value) {
        const next = Boolean(value);
        if (this.isPlaying === next) return;
        this.isPlaying = next;
        if (this.onPlaybackStateChange) this.onPlaybackStateChange(next);
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
