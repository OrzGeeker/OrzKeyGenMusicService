import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../../Resources/Public/audio/app.js', import.meta.url), 'utf8');

function createApp(fetchImpl) {
    const context = {
        console,
        fetch: fetchImpl,
        globalThis: { ORZ_DECODER_FORMATS: [] },
        module: { exports: {} },
        setTimeout: () => 0,
    };
    context.globalThis.globalThis = context.globalThis;
    vm.runInNewContext(source, context);
    const app = context.globalThis.playerApp();
    app.notify = (message, type = 'success') => app.toasts.push({ message, type });
    return app;
}

const response = (body, ok = true) => ({ ok, status: ok ? 200 : 503, json: async () => body });

test('opening the playlist panel lazily loads once and coalesces concurrent opens', async () => {
    let requests = 0;
    let resolveFetch;
    const app = createApp(() => {
        requests += 1;
        return new Promise(resolve => { resolveFetch = resolve; });
    });

    app.openPlaylistPanel();
    app.openPlaylistPanel();
    assert.equal(requests, 1);
    assert.equal(app.playlistOpen, true);

    resolveFetch(response([{ id: 'one', name: 'One' }]));
    await app._playlistsRequest;
    app.openPlaylistPanel();
    assert.equal(requests, 1);
    assert.equal(app.playlists[0].name, 'One');
});

test('failed lazy load can retry and reports the existing error toast', async () => {
    let requests = 0;
    const app = createApp(async () => {
        requests += 1;
        return requests === 1 ? response({}, false) : response([{ id: 'retry' }]);
    });

    assert.equal(await app.loadPlaylists(), false);
    assert.equal(app.toasts.at(-1).message, '播放列表加载失败');
    assert.equal(await app.loadPlaylists(), true);
    assert.equal(requests, 2);
    assert.equal(app.playlists[0].id, 'retry');
});

test('save and delete refresh the playlist collection', async () => {
    const calls = [];
    const app = createApp(async (url, options = {}) => {
        calls.push([url, options.method || 'GET']);
        if (options.method === 'POST') return response({ id: 'new', songCount: 1 });
        if (options.method === 'DELETE') return response({});
        return response([{ id: calls.length > 2 ? 'after-delete' : 'after-save' }]);
    });
    app.queue = [{ id: 'song' }];
    app.newPlaylistName = 'Saved';

    await app.saveAsPlaylist();
    await app.deletePlaylist('new');

    assert.deepEqual(calls.map(([url, method]) => `${method} ${url}`), [
        'POST /api/playlists',
        'GET /api/playlists',
        'DELETE /api/playlists/new',
        'GET /api/playlists',
    ]);
    assert.equal(app.playlists[0].id, 'after-delete');
});
