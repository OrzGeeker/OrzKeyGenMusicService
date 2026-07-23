import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../Resources/Public/audio/app.js', import.meta.url), 'utf8');
const manifestSource = readFileSync(new URL('../../Resources/Public/audio/decoder-manifest.generated.js', import.meta.url), 'utf8');

function createApp({ querySelector = () => null, fetch = async () => { throw new Error('unexpected fetch'); } } = {}) {
    const document = {
        body: {},
        activeElement: null,
        documentElement: { scrollHeight: 0 },
        querySelector,
    };
    const context = {
        globalThis: {},
        module: { exports: {} },
        document,
        window: { innerHeight: 800, addEventListener() {}, matchMedia: () => ({ matches: false }) },
        fetch,
        setTimeout() {},
        URLSearchParams,
        console,
    };
    vm.runInNewContext(manifestSource, context);
    vm.runInNewContext(source, context);
    const app = context.globalThis.playerApp();
    app.$nextTick = async () => {};
    return { app, document };
}

test('local current song is focused without requesting location', async () => {
    let fetchCount = 0;
    let scrolled = false;
    let focused = false;
    const row = {
        scrollIntoView(options) {
            scrolled = options.behavior === 'smooth' && options.block === 'center';
        },
        focus(options) {
            focused = options.preventScroll === true;
        },
    };
    const { app } = createApp({
        querySelector: selector => selector.includes('song-1') ? row : null,
        fetch: async () => { fetchCount++; throw new Error('unexpected fetch'); },
    });
    app.currentSong = { id: 'song-1' };

    assert.equal(await app.locateCurrentSong(), true);
    assert.equal(fetchCount, 0);
    assert.equal(scrolled, true);
    assert.equal(focused, true);
    assert.equal(app.locating, false);
});

test('remote location clears filters, loads returned page, and focuses the row', async () => {
    const requests = [];
    let rowAvailable = false;
    let focused = false;
    const row = {
        scrollIntoView() {},
        focus() { focused = true; },
    };
    const { app } = createApp({
        querySelector: selector => rowAvailable && selector.includes('song-9') ? row : null,
        fetch: async url => {
            requests.push(url);
            if (url.startsWith('/api/songs/song-9/location')) {
                return { ok: true, json: async () => ({ songId: 'song-9', page: 3, per: 50, index: 101 }) };
            }
            rowAvailable = true;
            return {
                ok: true,
                json: async () => ({
                    items: [{ id: 'song-9' }],
                    metadata: { page: 3, per: 50, total: 120 },
                }),
            };
        },
    });
    app.currentSong = { id: 'song-9' };
    app.searchQuery = 'chip';
    app.formatFilter = 'ym';

    assert.equal(await app.locateCurrentSong(), true);
    assert.deepEqual(requests, [
        '/api/songs/song-9/location?per=50',
        '/api/songs?page=3&per=50',
    ]);
    assert.equal(app.searchQuery, '');
    assert.equal(app.formatFilter, '');
    assert.equal(app.page, 3);
    assert.equal(focused, true);
});

test('failed remote location restores the complete library snapshot and reports an error', async () => {
    const originalSongs = [{ id: 'visible-1' }];
    const { app } = createApp({
        fetch: async () => ({ ok: false, status: 503 }),
    });
    app.currentSong = { id: 'missing' };
    app.searchQuery = 'old search';
    app.formatFilter = 'mod';
    app.page = 4;
    app.songs = originalSongs;
    app.totalResults = 175;
    app.hasMore = true;

    assert.equal(await app.locateCurrentSong(), false);
    assert.equal(app.searchQuery, 'old search');
    assert.equal(app.formatFilter, 'mod');
    assert.equal(app.page, 4);
    assert.equal(JSON.stringify(app.songs), JSON.stringify(originalSongs));
    assert.equal(app.totalResults, 175);
    assert.equal(app.hasMore, true);
    assert.equal(app.toasts.length, 1);
    assert.equal(app.toasts[0].type, 'error');
    assert.equal(app.locating, false);
});

test('missing current song and duplicate clicks do not mutate playback state', async () => {
    const { app } = createApp();
    app.queue = [{ id: 'queued' }];
    app.isPlaying = true;

    assert.equal(await app.locateCurrentSong(), false);
    app.currentSong = { id: 'playing' };
    app.locating = true;
    assert.equal(await app.locateCurrentSong(), false);
    assert.equal(app.isPlaying, true);
    assert.deepEqual(app.queue, [{ id: 'queued' }]);
});
