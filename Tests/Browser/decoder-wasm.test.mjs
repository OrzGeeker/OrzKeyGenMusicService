import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(import.meta.url);

test('full WASM V2M decoder reports seconds and renders audible PCM', async () => {
    const createModule = require(path.join(root, 'Resources/Public/audio/orz_audio.js'));
    const wasmPath = path.join(root, 'Resources/Public/audio/orz_audio.wasm');
    const wasmBinary = fs.readFileSync(wasmPath);
    const wasm = await createModule({ wasmBinary });
    const tune = fs.readFileSync(path.join(
        root,
        'Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/iOTA/iOTA - ACDSee Pro 5.3 build 168 crk.v2m'
    ));

    const format = wasm._malloc(4);
    const data = wasm._malloc(tune.length);
    wasm.stringToUTF8('v2m', format, 4);
    wasm.HEAPU8.set(tune, data);
    const decoder = wasm._orz_decoder_create(format, data, tune.length);
    wasm._free(format);
    wasm._free(data);
    assert.notEqual(decoder, 0);

    try {
        assert.equal(wasm._orz_decoder_get_duration(decoder), 172);
        const frames = 44_100;
        const pcmPointer = wasm._malloc(frames * 2 * 4);
        assert.notEqual(pcmPointer, 0);
        try {
            assert.equal(wasm._orz_decoder_render(decoder, pcmPointer, frames), frames);
            const pcm = wasm.HEAPF32.subarray(pcmPointer >> 2, (pcmPointer >> 2) + frames * 2);
            assert.ok(pcm.some(sample => Math.abs(sample) > 0.01), 'V2M WASM output remained silent');
        } finally {
            wasm._free(pcmPointer);
        }
    } finally {
        wasm._orz_decoder_destroy(decoder);
    }
});
