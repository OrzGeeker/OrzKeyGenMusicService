# SoundMon BP/BP3 format notes

The repository BP fixtures are Brian Postma SoundMon modules, not AdPlug
files. These notes are derived from the bundled UADE SoundMon 2.0/2.2 Eagle
players and verified against the real fixtures under `Resources/Public`.

All multi-byte integers are big-endian.

## Header

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 26 | Song title |
| 26 | 3 | `V.2` for BP/SoundMon 2.0; `V.3` for BP3/SoundMon 2.2 |
| 29 | 1 | Number of 64-byte waveform/control tables |
| 30 | 2 | Song length in sequence steps |
| 32 | 480 | Fifteen 32-byte instrument records |

A normal sampled instrument starts with its 24-byte name. Its final eight
bytes are sample length in words, repeat offset in bytes, repeat length in
words, and default volume. A synthetic instrument starts with `0xff`; the
remaining fields select waveform, ADSR, LFO, EG, modulation, filter tables and
delays.

## Sequence and patterns

The sequence starts at offset 512. Each step contains four four-byte channel
entries:

- big-endian pattern number (one-based);
- sound/instrument transpose;
- note transpose.

Pattern data immediately follows `songSteps * 16` sequence bytes. Patterns
are one-based, 48 bytes each, and contain sixteen three-byte rows. A row stores
note, instrument/effect, and effect parameter.

The table/sample area begins at:

```text
512 + songSteps * 16 + highestPattern * 48
```

First come `tableCount * 64` bytes of synthesis tables, followed by normal
sample payloads in instrument order. Synthetic instruments consume no sample
payload.

## Playback

The original player advances at 50 Hz with default speed 6. Four channels use
the Amiga Paula period table. Effects 0–15 include arpeggio, volume, speed,
filter, portamento, vibrato, pattern jump/repeat, autoslide, auto-arpeggio and
synthetic ADSR/LFO/EG/modulation/filter controls.

Implementations must validate every derived offset and table/sample reference
before allocating or rendering. BP remains unregistered until sampled and
synthetic fixtures both pass native/WASM PCM regression tests.
