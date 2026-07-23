import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const view = await readFile(new URL('../../Resources/Views/player.leaf', import.meta.url), 'utf8');
const css = await readFile(new URL('../../Resources/Public/audio/app.css', import.meta.url), 'utf8');

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
    assert.match(css, /--viz-height:140px/);
    assert.match(css, /\.visualizer-visible \.main-content\{padding-bottom:calc\(var\(--dock\) \+ var\(--viz-height\) \+ 34px\)\}/);
    assert.match(css, /@media\(max-width:720px\)\{:root\{--viz-height:100px\}/);
});

test('visualizer canvas stays decorative and controls have accessible names', () => {
    assert.match(view, /class="viz-canvas" role="presentation" aria-hidden="true"/);
    assert.match(view, /aria-label="折叠可视化面板"/);
    assert.match(view, /aria-label="展开可视化面板"/);
});
