import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../../Resources/Public/audio/app.js', import.meta.url), 'utf8');
const manifestSource = await readFile(new URL('../../Resources/Public/audio/decoder-manifest.generated.js', import.meta.url), 'utf8');
const playerView = await readFile(new URL('../../Resources/Views/player.leaf', import.meta.url), 'utf8');

class FakeFormData {
    constructor() { this.fields = []; }
    append(name, value, filename) { this.fields.push({ name, value, filename }); }
}

function response(body, status = 200) {
    return { ok: status >= 200 && status < 300, status, json: async () => body };
}

function createApp(fetchImpl) {
    const session = new Map();
    const context = {
        console,
        fetch: fetchImpl,
        FormData: FakeFormData,
        sessionStorage: { getItem: key => session.get(key) || null, setItem: (key, value) => session.set(key, value), removeItem: key => session.delete(key) },
        globalThis: { ORZ_DECODER_FORMATS: [] },
        module: { exports: {} },
        setTimeout: () => 0,
        URLSearchParams,
        document: { body: {}, activeElement: null, documentElement: { scrollHeight: 0 }, querySelector: () => null },
        window: { innerHeight: 800, addEventListener() {}, matchMedia: () => ({ matches: false }) },
    };
    context.globalThis.globalThis = context.globalThis;
    vm.runInNewContext(manifestSource, context);
    vm.runInNewContext(source, context);
    const app = context.globalThis.playerApp();
    app.notify = (message, type = 'success') => app.toasts.push({ message, type });
    return { app, session };
}

const file = (name, size = 128, relativePath = '') => ({ name, size, webkitRelativePath: relativePath });

test('directory import UI provides directory and file pickers and never uses localStorage for the token', () => {
    assert.match(playerView, /webkitdirectory multiple/);
    assert.match(playerView, /x-ref="filePicker"[^>]*type="file" multiple/);
    assert.match(playerView, /管理员“?工具|管理员工具/);
    assert.match(source, /sessionStorage\.getItem\('orz-admin-api-token'\)/);
    assert.doesNotMatch(source, /localStorage/);
});

test('directory preflight accepts server-supported formats and rejects unsupported or oversized files', async () => {
    const { app } = createApp(async url => {
        if (url === '/api/upload') return response({ status: 'created' }, 201);
        if (url === '/api/songs/formats') return response({ total: 0, formats: [] });
        return response({ items: [], metadata: { page: 1, per: 50, total: 0 } });
    });

    assert.equal(app.isImportFileSupported(file('demo.mod')), true);
    assert.equal(app.isImportFileSupported(file('song.MP3')), true);
    assert.equal(app.isImportFileSupported(file('legacy.thx')), false);
    assert.equal(app.isImportFileSupported(file('notes.txt')), false);

    app.adminToken = 'token';
    await app.selectImportFiles([file('demo.mod'), file('notes.txt'), file('large.xm', 32 * 1024 * 1024 + 1)]);
    assert.equal(app.importItems.length, 3);
    assert.equal(app.importItems.filter(item => item.status === 'failed').length, 2);
    assert.equal(app.importItems[0].path, 'demo.mod');
});

test('directory upload has two workers, counts created and duplicates, and sends session token with relative path', async () => {
    let active = 0;
    let maxActive = 0;
    const uploads = [];
    const { app, session } = createApp(async (url, options = {}) => {
        if (url === '/api/upload') {
            active += 1;
            maxActive = Math.max(maxActive, active);
            uploads.push(options);
            await new Promise(resolve => setTimeout(resolve, 5));
            active -= 1;
            return response({ status: uploads.length === 2 ? 'duplicate' : 'created' }, uploads.length === 2 ? 200 : 201);
        }
        if (url === '/api/songs/formats') return response({ total: 0, formats: [] });
        return response({ items: [], metadata: { page: 1, per: 50, total: 0 } });
    });
    app.adminToken = 'session-only-token';
    app.saveAdminToken();
    assert.equal(session.get('orz-admin-api-token'), 'session-only-token');

    app.importItems = [
        { file: file('a.mod', 1, 'Folder/a.mod'), path: 'Folder/a.mod', status: 'queued' },
        { file: file('b.xm', 1, 'Folder/b.xm'), path: 'Folder/b.xm', status: 'queued' },
        { file: file('c.mp3', 1, 'Folder/c.mp3'), path: 'Folder/c.mp3', status: 'queued' },
    ];
    await app.startImport();

    assert.equal(maxActive, 2);
    assert.equal(app.importCreated, 2);
    assert.equal(app.importDuplicates, 1);
    assert.equal(app.importFailed, 0);
    assert.equal(app.importProgress, 100);
    assert.equal(uploads[0].headers.Authorization, 'Bearer session-only-token');
    assert.deepEqual(uploads[0].body.fields.find(field => field.name === 'relativePath'), { name: 'relativePath', value: 'Folder/a.mod', filename: undefined });
});

test('failed files do not stop the batch and retry only retryable failures', async () => {
    let failedOnce = true;
    const uploads = [];
    const { app } = createApp(async (url, options = {}) => {
        if (url === '/api/upload') {
            const path = options.body.fields.find(field => field.name === 'relativePath').value;
            uploads.push(path);
            if (path === 'retry.mod' && failedOnce) { failedOnce = false; throw new Error('offline'); }
            return response({ status: 'created' }, 201);
        }
        if (url === '/api/songs/formats') return response({ total: 0, formats: [] });
        return response({ items: [], metadata: { page: 1, per: 50, total: 0 } });
    });
    app.adminToken = 'token';
    app.importItems = [
        { file: file('retry.mod'), path: 'retry.mod', status: 'queued' },
        { file: file('continues.xm'), path: 'continues.xm', status: 'queued' },
        { file: file('not-retryable.txt'), path: 'not-retryable.txt', status: 'failed', error: '不支持的音频格式', retryable: false },
    ];

    await app.startImport();
    assert.equal(app.importCreated, 1);
    assert.equal(app.importFailed, 2);
    assert.equal(app.importItems[0].retryable, true);
    await app.retryImportFailures();

    assert.deepEqual(uploads, ['retry.mod', 'continues.xm', 'retry.mod']);
    assert.equal(app.importCreated, 2);
    assert.equal(app.importFailed, 1);
    assert.equal(app.importItems[2].status, 'failed');
});
