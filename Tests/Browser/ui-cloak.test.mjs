import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const view = await readFile(new URL('../../Resources/Views/player.leaf', import.meta.url), 'utf8');
const css = await readFile(new URL('../../Resources/Public/audio/app.css', import.meta.url), 'utf8');
const app = await readFile(new URL('../../Resources/Public/audio/app.js', import.meta.url), 'utf8');

test('shortcut modal stays cloaked until Alpine initializes', () => {
    assert.match(css, /\[x-cloak\]\s*\{\s*display:none!important\s*\}/);
    assert.match(view, /class="modal"\s+x-cloak\s+x-show="shortcutOpen"/);
});

test('shortcut help entry appears before the format navigation', () => {
    const shortcut = view.indexOf('class="shortcut-hint"');
    const navigation = view.indexOf('class="format-nav"');
    assert.ok(shortcut >= 0);
    assert.ok(shortcut < navigation);
});

test('sidebar brand presents the OrzMusic title beside the logo', () => {
    assert.match(view, /class="brand-home"/);
    assert.match(view, /Orz<span>Music<\/span>/);
    assert.match(view, /aria-label="OrzMusic 首页"/);
});

test('expanded visualizer reserves library space and uses a smaller mobile height', () => {
    assert.match(view, /'visualizer-visible':currentSong && visualizerOpen/);
    assert.match(css, /--viz-height:156px/);
    assert.match(css, /\.visualizer-visible \.main-content\{padding-bottom:calc\(var\(--dock\) \+ var\(--viz-height\) \+ 34px\)\}/);
    assert.match(css, /\.viz-panel\{[^}]*inset:auto 0 calc\(var\(--dock\) - 1px\) var\(--sidebar\)/);
    assert.match(css, /@media\(max-width:720px\)\{:root\{--viz-height:112px\}/);
});

test('visualizer canvas stays decorative and controls have accessible names', () => {
    assert.match(view, /class="viz-canvas" role="presentation" aria-hidden="true"/);
    assert.match(view, /aria-label="折叠可视化面板"/);
    assert.match(view, /aria-label="展开可视化面板"/);
    assert.match(view, /aria-label="折叠可视化面板" aria-keyshortcuts="V"/);
    assert.match(view, /aria-label="展开可视化面板" aria-keyshortcuts="V"/);
    assert.match(view, /aria-keyshortcuts="Shift\+V" title="切换声场类型 \(Shift \+ V\)"/);
    assert.match(app, /toggleVisualizer\(\)\{if\(!this\.currentSong\)return;this\.visualizerOpen=!this\.visualizerOpen;this\._syncVisualizer\(\)\}/);
});

test('now playing metadata keeps two lines and artwork owns the locate action', () => {
    assert.match(view, /class="now-playing-body"/);
    assert.match(view, /class="now-playing-copy"[\s\S]*?<strong[\s\S]*?<span/);
    assert.match(view, /button class="track-art" @click="locateCurrentSong"/);
    assert.match(view, /title="定位当前曲目 \(L\)"[\s\S]*aria-keyshortcuts="L"/);
    assert.doesNotMatch(view, /class="locate-btn"/);
    assert.match(css, /\.now-playing>div\.now-playing-body:last-child\{[^}]*display:block/);
    assert.match(css, /\.now-playing-copy\{[^}]*flex-direction:column/);
    assert.match(css, /\.track-art:disabled\{opacity:1;cursor:default\}/);
});

test('visualizer defaults open, initializes before playback, and keeps controls on the right', () => {
    assert.match(app, /visualizerOpen:true/);
    assert.match(app, /this\.currentSong&&this\.visualizerOpen&&!this\._visualizerInited/);
    assert.match(app, /await this\.\$nextTick\(\);this\._syncVisualizer\(\);await player\.play\(song\)/);
    assert.match(app, /this\.isPlaying=player\.isPlaying;this\._syncVisualizer\(\)/);
    assert.match(css, /\.viz-expand-btn\{left:auto;right:8px\}/);
});
