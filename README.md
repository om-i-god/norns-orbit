# orbit

four-track euclidean drum machine for norns — concentric rings, trigger-based delays, pitch drift

---

orbit is a generative drum machine for [norns](https://monome.org/norns/) built around euclidean rhythms displayed as concentric rings. four tracks — kick, clap, closed hat, open hat — each travel independently around their own ring, with active steps shown as dots and the playhead flashing on trigger. the whole thing runs off a single 1/16th note clock, keeping everything locked and readable.

the delay system works differently from a standard send bus: each track fires its own ghost retriggers directly, with independent timing division and decay. adding pitch drift to the echoes introduces the kind of tape-echo instability that makes repeats sound like they're falling apart in a good way.

---

## tracks

| abbr | voice | sample |
|---|---|---|
| **KK** | kick | 808-BD |
| **CP** | clap | 808-CP |
| **CH** | closed hat | 909-CH |
| **OH** | open hat | 909-OH |

---

## controls

orbit uses a **modifier key pattern** — hold a key while turning an encoder to access parameters directly from the main screen.

| input | action |
|---|---|
| **E1** | track select |
| **E2** | euclidean beats (density) |
| **E3** | euclidean rotation |
| **K2** (release, alone) | mute / unmute selected track |
| **K2 + K3** | play / stop |
| **K2 + E1** | volume for selected track |
| **K2 + E2** | low pass filter cutoff |
| **K2 + E3** | high pass filter cutoff |
| **K3 + E1** | pitch for selected track |
| **K3 + E2** | delay decay (0 = off, 95% = slow fade) |
| **K3 + E3** | delay division (tempo-synced) |
| **K1 + E1** | delay pitch drift |

the right panel always shows the current values for the selected track: **PCH** (pitch offset in semitones), **DCY** (delay decay %), **DLY** (delay division), and **DFT** (drift in semitones). holding K2 switches the panel to show **LP** and **HP** filter cutoffs instead.

the footer shows BPM (or `lnk` when Ableton Link is active), the selected track's volume, and play state.

---

## euclidean rhythms

each track generates its pattern using the Bjorklund algorithm. beats sets the number of active steps distributed as evenly as possible across the track length (fixed at 16 steps). rotation shifts the pattern clockwise around the ring.

defaults:

| track | beats | rotation |
|---|---|---|
| kick | 4 | 0 — four-on-the-floor |
| clap | 2 | 4 — beats 2 and 4 |
| closed hat | 8 | 0 — 8th notes |
| open hat | 2 | 2 — offbeats |

---

## trigger-based delay

orbit's delay does not use a send bus. instead, when a step fires, a coroutine schedules up to 8 ghost retriggers spaced at the track's delay division. each echo is quieter than the last by a fixed dB amount determined by the decay value. the sequence stops early when volume drops below −60dB.

this means each track can have a completely independent delay time — a kick echoing every bar while the clap stutters in triplets.

| param | range | description |
|---|---|---|
| decay | 0 – 95% | volume retained per echo (0 = delay off) |
| division | 1/64 – 4 bars | time between echoes, tempo-synced |
| drift | 0 – 2.0st | max pitch drift per echo (random walk in semitones) |

**pitch drift** applies a random walk to the playback speed of each successive echo. at low values this is subtle tape warble. at higher values the repeats pitch-shift unpredictably across the drift range. pitch is restored to its original value after the last echo.

a master Ack delay bus remains active (fixed at 1/4 note) and can be used as a background wash via the per-channel delay send params.

---

## filter

each track has an independent filter controllable from the main screen. K2+E2 applies a low pass and K2+E3 applies a high pass. both cutoff values are stored separately per track — switching between them does not lose the previous setting. the last one adjusted is the active filter mode.

cutoff range is 20Hz – 20kHz on a logarithmic scale (~1 semitone per encoder step).

---

## ableton link

orbit supports Ableton Link for tempo sync and transport. when clock source is set to link (via PARAMETERS > CLOCK), the tempo follows the Link session automatically. start/stop sync is enabled — pressing play in a linked DAW will start orbit at the next 4-bar boundary, and stopping the DAW will stop orbit.

the footer displays `120lnk` (bright) instead of `120bpm` when Link is active.

---

## params

### ORBIT (per track)
sample, start/end position, loop, speed, volume, volume envelope (attack/release), pan, filter (mode/cutoff/resonance/envelope), bit depth, distortion, mute group, delay send

### DELAY (global)
| param | description |
|---|---|
| delay feedback | feedback amount for the master Ack delay bus |
| delay level | output level of the master delay bus |
| main level | overall output level |

### SEQUENCER (per track)
backs all live UI state so presets save and restore everything: beats, rotation, mute, delay division, delay decay, delay drift, LP cutoff, HP cutoff.

---

## engine

orbit uses the **Ack** engine for sample playback.

```
engine.name = "Ack"
```

Ack must be installed at `~/dust/code/ack/`. it is available from [github.com/antonhornquist/ack](https://github.com/antonhornquist/ack).

default samples are loaded from `~/dust/audio/x0x/` (808 and 909 sample packs included with norns).

---

## requirements

- [norns](https://monome.org/norns/) (any version)
- [Ack engine](https://github.com/antonhornquist/ack) installed at `~/dust/code/ack/`
- 808/909 samples (included with norns at `~/dust/audio/x0x/`)

---

## installation

copy `orbit.lua` to `~/dust/code/orbit/orbit.lua` on norns, then select it from the norns script menu.

via maiden REPL:
```
os.execute("mkdir -p ~/dust/code/orbit")
```
then transfer the file over SSH or via the maiden file browser.

---

## license

MIT
