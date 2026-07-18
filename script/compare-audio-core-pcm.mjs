#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [probe, embeddedLibrary, sdkLibrary, fixtureFile, reportFile] = process.argv.slice(2);
if (!reportFile) {
    console.error('usage: compare-audio-core-pcm.mjs PROBE EMBEDDED_LIB_DIR SDK_LIB_DIR FIXTURES REPORT');
    process.exit(2);
}
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const fixtures = JSON.parse(fs.readFileSync(path.resolve(root, fixtureFile), 'utf8'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'orz-pcm-compare-'));
const maxFrames = Number(process.env.ORZ_PCM_COMPARE_FRAMES || 220500);
const tolerance = Number(process.env.ORZ_PCM_COMPARE_TOLERANCE || 1e-6);
const rows = [];

function runProbe(library, fixture, prefix) {
    const input = path.resolve(root, fixture.path);
    if (!fs.existsSync(input)) throw new Error(`missing fixture: ${fixture.path}`);
    const result = spawnSync(path.resolve(probe), [input, fixture.format, String(maxFrames), prefix], {
        encoding: 'utf8',
        env: {...process.env, LD_LIBRARY_PATH: library}
    });
    if (result.status !== 0) throw new Error(`${fixture.format} probe failed: ${result.stderr || result.stdout}`);
    return {
        info: JSON.parse(fs.readFileSync(`${prefix}.json`, 'utf8')),
        pcm: fs.readFileSync(`${prefix}.f32`)
    };
}

try {
    for (const fixture of fixtures) {
        const embedded = runProbe(path.resolve(embeddedLibrary), fixture, path.join(work, `${fixture.format}-embedded`));
        const sdk = runProbe(path.resolve(sdkLibrary), fixture, path.join(work, `${fixture.format}-sdk`));
        for (const key of ['sampleRate', 'channels', 'frames']) {
            if (embedded.info[key] !== sdk.info[key]) {
                throw new Error(`${fixture.format} ${key}: embedded=${embedded.info[key]} sdk=${sdk.info[key]}`);
            }
        }
        const durationError = Math.abs(embedded.info.duration - sdk.info.duration);
        if (!Number.isFinite(durationError) || durationError > 1e-6) {
            throw new Error(`${fixture.format} duration differs by ${durationError}s`);
        }
        if (embedded.info.peak <= 1e-7 || sdk.info.peak <= 1e-7) {
            throw new Error(`${fixture.format} representative fixture rendered silence`);
        }
        if (embedded.pcm.length !== sdk.pcm.length) throw new Error(`${fixture.format} PCM byte length differs`);
        let maximumError = 0;
        let differentSamples = 0;
        for (let offset = 0; offset < embedded.pcm.length; offset += 4) {
            const a = embedded.pcm.readFloatLE(offset);
            const b = sdk.pcm.readFloatLE(offset);
            const error = Math.abs(a - b);
            if (!Number.isFinite(error)) throw new Error(`${fixture.format} contains non-finite PCM`);
            if (error > maximumError) maximumError = error;
            if (error > tolerance) differentSamples++;
        }
        let energyError = 0;
        if (fixture.comparison === 'energy') {
            const scale = Math.max(embedded.info.meanSquare, sdk.info.meanSquare, 1e-12);
            energyError = Math.abs(embedded.info.meanSquare - sdk.info.meanSquare) / scale;
            if (energyError > 0.15) throw new Error(`${fixture.format} relative mean-square error ${energyError} exceeds 0.15`);
        } else if (differentSamples) {
            throw new Error(`${fixture.format} maximum PCM error ${maximumError} exceeds ${tolerance}`);
        }
        rows.push({format: fixture.format, path: fixture.path, comparison: fixture.comparison || 'samples',
            ...sdk.info, durationError, maximumError, energyError});
        console.log(`${fixture.format}: ${sdk.info.frames} frames, max error ${maximumError}`);
    }
    const report = {
        schemaVersion: 1,
        embeddedLibrary: path.resolve(embeddedLibrary),
        sdkLibrary: path.resolve(sdkLibrary),
        framesPerFixture: maxFrames,
        tolerance,
        passed: rows.length,
        fixtures: rows
    };
    fs.mkdirSync(path.dirname(path.resolve(reportFile)), {recursive: true});
    fs.writeFileSync(path.resolve(reportFile), `${JSON.stringify(report, null, 2)}\n`);
} finally {
    fs.rmSync(work, {recursive: true, force: true});
}
