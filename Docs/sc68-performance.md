# SC68 performance decision

Benchmark fixture: `LEGEND - Dynamite Dick intro_1.sc68`, Apple Silicon host,
Emscripten 6.0.2, release `-O3`, Node WebAssembly runtime.

| Metric | Result |
|---|---:|
| Declared/policy audio duration | 180 s |
| Load + complete core materialization | 75.76 ms |
| Core throughput | 2375.8× realtime |
| Subsequent PCM render | memory-copy bound |
| Full WASM bundle | 3,103,903 bytes |

The earlier three-second limit was not a measured CPU constraint. It was an
old defensive policy and caused truncated playback. It is removed: valid
metadata is honored up to the explicit 180-second unknown-duration policy.

This libsc68 version has process-global `api68`, `reg68`, emu68 and I/O state,
so two live cores cannot coexist safely. Creation therefore holds a short core
lock and materializes packed stereo int16 PCM; handles then render independently
and concurrently. At the measured throughput, replacing emu68 with
Musashi/Cyclone would add a second core and compatibility risk without solving
a current performance problem. Re-evaluate only if a representative target
browser falls below 1.5× realtime. The aggregate profile leaves no persistent
instruction-execution hotspot: after creation, render is a linear PCM convert.
