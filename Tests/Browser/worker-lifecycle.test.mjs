import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const worker = await readFile(
    new URL('../../Resources/Public/audio/orz-decoder-worker.js', import.meta.url),
    'utf8',
);

test('worker supports explicit bundle warmup without decoding a song', () => {
    assert.match(worker, /message\.type === 'warmup'/);
    assert.match(worker, /type: 'warmed'/);
    assert.match(worker, /type: 'warmup-error'/);
});

test('stop destroys the decoder and acknowledges reuse without closing the worker', () => {
    assert.match(worker, /_orz_decoder_cancel\(decoder\)/);
    assert.match(worker, /_orz_decoder_destroy_v1\(decoder\)/);
    assert.match(worker, /type: 'stopped'/);
    assert.doesNotMatch(worker, /self\.close\(\)/);
});
