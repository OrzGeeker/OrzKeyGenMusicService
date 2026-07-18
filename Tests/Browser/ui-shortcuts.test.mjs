import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../Resources/Public/audio/app.js', import.meta.url), 'utf8');
const manifestSource = readFileSync(new URL('../../Resources/Public/audio/decoder-manifest.generated.js', import.meta.url), 'utf8');
const document = { body: {}, activeElement: null };
const context = { globalThis: {}, module: { exports: {} }, document, setTimeout() {}, URLSearchParams };
vm.runInNewContext(manifestSource, context);
vm.runInNewContext(source, context);
const { clamp, formatDuration, releaseShortcutFocus, shortcutAction, formats } = context.module.exports;

const event = (key, extra = {}) => ({ key, target: { closest: () => false }, ...extra });

test('keyboard shortcuts map playback and navigation actions', () => {
    assert.equal(shortcutAction(event(' ')), 'play');
    assert.equal(shortcutAction(event('ArrowLeft')), 'back5');
    assert.equal(shortcutAction(event('ArrowRight', { shiftKey: true })), 'forward15');
    assert.equal(shortcutAction(event('n')), 'next');
    assert.equal(shortcutAction(event('p')), 'prev');
    assert.equal(shortcutAction(event('?')), 'help');
    assert.equal(shortcutAction(event('h')), 'help');
    assert.equal(shortcutAction(event('k', { metaKey: true })), 'search');
});

test('editable controls suppress media shortcuts except escape', () => {
    const editable = { key: ' ', target: { closest: () => true } };
    assert.equal(shortcutAction(editable), null);
    assert.equal(shortcutAction({ ...editable, key: 'Escape' }), 'escape');
});

test('global shortcuts release stale button focus without touching text fields', () => {
    let blurred = false;
    const button = { matches: selector => selector === 'button,[tabindex]', blur: () => { blurred = true; } };
    context.document.activeElement = button;
    releaseShortcutFocus();
    assert.equal(blurred, true);

    blurred = false;
    context.document.activeElement = { matches: () => false, blur: () => { blurred = true; } };
    releaseShortcutFocus();
    assert.equal(blurred, false);
});

test('volume and seek values are clamped to a safe range', () => {
    assert.equal(clamp(-2), 0);
    assert.equal(clamp(0.4), 0.4);
    assert.equal(clamp(3), 1);
});

test('missing library duration is not presented as a zero-length song', () => {
    assert.equal(formatDuration(null), '—');
    assert.equal(formatDuration(0), '—');
    assert.equal(formatDuration(65.9), '1:05');
});

test('format metadata contains the core decoder families', () => {
    for (const format of ['ym', 'v2m', 'sc68', 'bp', 'mp3']) {
        assert.ok(formats.some(item => item.id === format));
    }
});
