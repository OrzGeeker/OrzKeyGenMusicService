let generation = 0;
let modulePromise;
let decoder = 0;
let seekRequested = null;
let wasmInstance = null;
let stopGeneration = null;

function wasmModule(moduleJs = '/audio/orz_audio.js') {
    if (!modulePromise) {
        importScripts(moduleJs);
        const version = moduleJs.includes('?') ? moduleJs.slice(moduleJs.indexOf('?')) : '';
        modulePromise = OrzAudioKit({ locateFile: path => `/audio/${path}${version}` });
    }
    return modulePromise;
}

function waitTurn() {
    return new Promise(resolve => setTimeout(resolve, 2));
}

function usedFrames(write, read, capacity) {
    return write >= read ? write - read : capacity - read + write;
}

self.onmessage = async event => {
    const message = event.data;
    if (message.type === 'stop') {
        generation = message.generation;
        stopGeneration = message.generation;
        return;
    }
    if (message.type === 'seek') {
        if (message.generation === generation) seekRequested = message.positionMs;
        return;
    }
    if (message.type !== 'decode') return;

    const myGeneration = message.generation;
    generation = myGeneration;
    const control = new Int32Array(message.control);
    const ring = new Float32Array(message.samples);
    const capacity = message.capacityFrames;
    const channels = message.channels;
    let rendered = 0;
    const started = performance.now();

    try {
        const wasm = wasmInstance = await wasmModule(message.moduleJs);
        const data = new Uint8Array(message.data);
        const createDecoder = () => {
            const formatLength = wasm.lengthBytesUTF8(message.format) + 1;
            const formatPointer = wasm._malloc(formatLength);
            const dataPointer = wasm._malloc(data.length);
            if (!formatPointer || !dataPointer) {
                if (formatPointer) wasm._free(formatPointer);
                if (dataPointer) wasm._free(dataPointer);
                throw new Error('cannot allocate decoder input');
            }
            wasm.stringToUTF8(message.format, formatPointer, formatLength);
            wasm.HEAPU8.set(data, dataPointer);
            const handle = wasm._orz_decoder_create(formatPointer, dataPointer, data.length);
            wasm._free(formatPointer);
            wasm._free(dataPointer);
            if (handle && message.subsong > 0 && wasm._orz_decoder_select_subsong(handle, message.subsong) !== 0) {
                wasm._orz_decoder_destroy(handle);
                throw new Error(`subsong ${message.subsong} is not supported`);
            }
            return handle;
        };
        decoder = createDecoder();
        if (!decoder) throw new Error(`cannot decode ${message.format}`);

        const sampleRate = wasm._orz_decoder_get_sample_rate(decoder) || 44100;
        const duration = wasm._orz_decoder_get_duration(decoder) || 0;
        self.postMessage({ type: 'ready', generation: myGeneration, sampleRate, duration });

        const chunkFrames = 2048;
        const pcmPointer = wasm._malloc(chunkFrames * channels * 4);
        if (!pcmPointer) throw new Error('cannot allocate PCM buffer');
        while (generation === myGeneration) {
            if (seekRequested !== null) {
                const position = seekRequested;
                seekRequested = null;
                Atomics.store(control, 0, 0);
                Atomics.store(control, 1, 0);
                Atomics.store(control, 2, 0);
                if (wasm._orz_decoder_seek_ms(decoder, position) !== 0) {
                    wasm._orz_decoder_destroy(decoder);
                    decoder = createDecoder();
                    if (!decoder) throw new Error(`cannot recreate ${message.format} for seek`);
                    let remaining = Math.floor(position * sampleRate / 1000);
                    let chunks = 0;
                    while (remaining > 0 && generation === myGeneration) {
                        const count = wasm._orz_decoder_render(decoder, pcmPointer, Math.min(chunkFrames, remaining));
                        if (count <= 0) throw new Error(`cannot seek ${message.format} to ${position}ms`);
                        remaining -= count;
                        if (++chunks % 64 === 0) await waitTurn();
                    }
                }
                rendered = Math.floor(position * sampleRate / 1000);
                self.postMessage({ type: 'seeked', generation: myGeneration, positionMs: position });
            }
            const write = Atomics.load(control, 0);
            const read = Atomics.load(control, 1);
            const free = capacity - usedFrames(write, read, capacity) - 1;
            if (free < chunkFrames) { await waitTurn(); continue; }

            const count = wasm._orz_decoder_render(decoder, pcmPointer, Math.min(chunkFrames, free));
            if (count <= 0) break;
            const pcm = wasm.HEAPF32.subarray(pcmPointer >> 2, (pcmPointer >> 2) + count * channels);
            for (let frame = 0; frame < count; frame++) {
                const target = ((write + frame) % capacity) * channels;
                for (let channel = 0; channel < channels; channel++) ring[target + channel] = pcm[frame * channels + channel];
            }
            Atomics.store(control, 0, (write + count) % capacity);
            rendered += count;
            if (Atomics.load(control, 2) === 0 && usedFrames(Atomics.load(control, 0), Atomics.load(control, 1), capacity) >= message.startFrames) {
                Atomics.store(control, 2, 1);
                self.postMessage({ type: 'started', generation: myGeneration });
            }
        }
        wasm._free(pcmPointer);
        if (generation === myGeneration) {
            Atomics.store(control, 2, 2);
            self.postMessage({ type: 'ended', generation: myGeneration, rendered,
                decodeRate: rendered / sampleRate / Math.max((performance.now() - started) / 1000, 0.001) });
        }
        wasm._orz_decoder_destroy(decoder);
        decoder = 0;
        if (stopGeneration !== null) {
            self.postMessage({ type: 'stopped', generation: stopGeneration });
            self.close();
        }
    } catch (error) {
        if (decoder && wasmInstance) wasmInstance._orz_decoder_destroy(decoder);
        decoder = 0;
        Atomics.store(control, 2, 3);
        self.postMessage({ type: 'error', generation: myGeneration, message: error.message });
        if (stopGeneration !== null) {
            self.postMessage({ type: 'stopped', generation: stopGeneration });
            self.close();
        }
    }
};
