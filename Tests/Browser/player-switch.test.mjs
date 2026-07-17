import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

class FakeAudio {
    constructor() {
        this.src = '';
        this.volume = 1;
        this.currentTime = 0;
        this.duration = Number.NaN;
        this.listeners = new Map();
    }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    dispatch(type) { this.listeners.get(type)?.(); }
    pause() { this.paused = true; }
    async play() { this.paused = false; }
}

const source = await readFile(new URL('../../Resources/Public/audio/player.js', import.meta.url), 'utf8');
const context = vm.createContext({
    Audio: FakeAudio,
    DOMException,
    console,
    cancelAnimationFrame() {},
    requestAnimationFrame() { return 1; },
    AbortController,
    clearTimeout,
    setTimeout,
});
vm.runInContext(`${source}\nglobalThis.TestPlayer = OrzAudioPlayer;`, context);
const Player = context.TestPlayer;

test('a newer song cancels an in-flight YM play without falling back', async () => {
    const player = new Player();
    let releaseFirst;
    const firstFetch = new Promise(resolve => { releaseFirst = resolve; });
    const direct = [];

    player._playWasm = async (_url, _format, _subsong, playGen) => {
        await firstFetch;
        player._assertCurrentPlayback(playGen);
    };
    player._playDirect = async (url, playGen) => {
        player._assertCurrentPlayback(playGen);
        direct.push(url);
        player.isPlaying = true;
    };

    const first = player.play({ playStrategy: 'wasmDecode', fileFormat: 'ym', rawUrl: '/first.ym' });
    const second = player.play({ playStrategy: 'directFile', rawUrl: '/second.ogg' });
    releaseFirst();
    await Promise.all([first, second]);

    assert.deepEqual(direct, ['/second.ogg']);
    assert.equal(player.currentSong.rawUrl, '/second.ogg');
    assert.equal(player.isPlaying, true);
});

test('stop rejects a pending worker-ready promise', async () => {
    const player = new Player();
    let rejected;
    let terminated = false;
    const worker = { postMessage() {}, terminate() { terminated = true; }, onmessage: null };
    player._decoderWorker = worker;
    player._workerReject = error => { rejected = error; };
    player._workerRejectOwner = worker;

    player.stop();

    assert.equal(rejected?.name, 'AbortError');
    assert.equal(player._decoderWorker, null);
    assert.equal(player._workerReject, null);
    worker.onmessage({ data: { type: 'stopped', generation: player._streamGen } });
    assert.equal(terminated, true);
});

test('stop aborts an in-flight audio download', () => {
    const player = new Player();
    const controller = new AbortController();
    player._fetchController = controller;

    player.stop();

    assert.equal(controller.signal.aborted, true);
    assert.equal(player._fetchController, null);
});

test('stop marks the old worklet ring as stopped', () => {
    const player = new Player();
    const shared = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 8);
    const control = new Int32Array(shared);
    Atomics.store(control, 3, player._streamGen);
    player._workerControl = control;

    player.stop();

    assert.equal(Atomics.load(control, 2), 4);
    assert.equal(Atomics.load(control, 3), player._streamGen);
    assert.equal(player._workerControl, null);
});

test('AudioWorklet module is registered only once across many songs', async () => {
    const player = new Player();
    let registrations = 0;
    player.audioCtx = { audioWorklet: { addModule: async () => { registrations++; } } };

    await Promise.all(Array.from({ length: 20 }, () => player._ensureWorkletModule()));

    assert.equal(registrations, 1);
});

test('direct playback state follows completed play, pause, and ended events', async () => {
    const player = new Player();
    const states = [];
    player.currentSong = { id: 'direct' };
    player.onPlaybackStateChange = state => states.push(state);

    assert.equal(await player.togglePlay(), true);
    assert.equal(player.audioEl.paused, false);
    assert.equal(await player.togglePlay(), false);
    assert.equal(player.audioEl.paused, true);
    await player.togglePlay();
    player.audioEl.dispatch('ended');

    assert.equal(player.isPlaying, false);
    assert.deepEqual(states, [true, false, true, false]);
});

test('direct seek waits for metadata and clamps the requested position', () => {
    const player = new Player();
    player.seek(2);
    assert.equal(player._pendingDirectSeek, 1);

    player.audioEl.duration = 120;
    player.audioEl.dispatch('loadedmetadata');
    assert.equal(player.audioEl.currentTime, 120);
    assert.equal(player._pendingDirectSeek, null);

    player.seek(-1);
    assert.equal(player.audioEl.currentTime, 0);
});

test('worker seek updates the clock only after decoder confirmation', () => {
    const player = new Player();
    const messages = [];
    player._usingWasm = true;
    player.duration = 100;
    player.currentTime = 10;
    player._streamGen = 7;
    player._decoderWorker = { postMessage: message => messages.push(message) };

    assert.equal(player.seek(0.75), true);
    assert.equal(player.currentTime, 10);
    assert.equal(messages.length, 1);
    assert.equal(messages[0].type, 'seek');
    assert.equal(messages[0].generation, 7);
    assert.equal(messages[0].positionMs, 75000);
});
