# orbit — devlog

A running design log. Written from the project's current state rather than as a
dated release history — the public git history is just two commits (initial commit
and a README, 2026-04-01 / 2026-04-02), so the repo was published as a finished
piece rather than developed in the open. Dates below are noted only where the git
log actually supports them; everything else is described from the code as it now
stands.

## The idea

A four-track euclidean drum machine where the whole instrument reads as a single
turning object. Four concentric rings share one clock; each ring is a track, each
filled slot fires a drum voice, and every hit can drag a trail of quieter echoes
behind it. The pitch is deliberately narrow: one 1/16 clock, four fixed voices,
two pattern knobs and a handful of per-track delay knobs. There is no manual step
editing anywhere in the code — whatever character the machine has comes out of
euclidean spacing and the echo trails, not from drawing notes into a grid.

The four tracks are fixed and ordered inner to outer: kick, clap, closed hat, open
hat (`KICK`/`CLAP`/`CHHT`/`OHHT` in the source, abbreviated `KK`/`CP`/`CH`/`OH`
on screen). You don't add or remove tracks; you shape the four you're given. They
play 808 and 909 samples by default (`808-BD`, `808-CP`, `909-CH`, `909-OH`).

## Rings on one clock

The spine is a single 1/16-note clock. `start_sequencer` runs one coroutine that
loops on `clock.sync(0.25)` and calls `step_all()` on every sixteenth; that
function walks all four tracks, fires any track whose current step is active, and
advances each track's position. There is deliberately no per-track tempo. Length
*can* differ per track in principle (each track carries its own `length`), but the
defaults fix all four at 16 and the only editable pattern controls are beats and
rotation — so in practice every ring turns in lockstep.

That uniformity is the point. If the tracks ran at independent speeds the rings
would drift into generic polymeter and the circular visual would stop meaning
anything. By locking them to one clock, the only things that distinguish a track
are its euclidean fill and its rotation — so the differences you hear are the
differences you can see in the ring geometry.

The visualization follows directly from the model. The four rings are concentric
circles centered at (74, 30) with radii `{9, 15, 21, 27}`, kick innermost. Each
track's steps are laid around its ring starting at the top (`-π/2`) and running
clockwise; active steps draw as 3×3 dots, and on the selected track the empty steps
show as faint single pixels so you can read the grid you're filling. A playhead dot
rides each ring at the current step and flashes bright on trigger — `track_flash`
is set to 15 on a hit and decays a few levels per frame, so every strike leaves a
brief glow that fades as the playhead moves on. The result reads as one rotating
machine with four hands sweeping it.

The screen is divided into three zones: a left strip of track labels with each
track's `beats/length` density readout, the ring cluster in the middle, and a
right panel of live readouts for the selected track.

## Euclidean, honestly

Fill (beats) and rotation are the only pattern controls. The README calls the
generator the Bjorklund algorithm; in the source it's actually a simpler running
accumulator (`euclidean()` adds `beats` to an error term each step and marks a hit
whenever it crosses `steps`). For most fills this lands on the same evenly-spread
distribution Bjorklund produces, and it's chosen for the same goal — spread the
hits out as evenly as the count allows. Rotation then shifts where that pattern
begins by rotating the table.

Two numbers per track, and that's the entire pattern surface. The defaults ship a
deliberately classic set so the machine sounds like something the moment you press
play: kick 4/16 at rotation 0 (four-on-the-floor), clap 2/16 rotated to land on 2
and 4, closed hat 8/16 (straight eighths), open hat 2/16 rotated onto the offbeats.

## The delay: ghost retriggers

This is the part the README names as the signature, and it's what makes the script
*orbit* rather than a generic euclidean box. The delay is not a send bus. Instead,
when a track fires and its decay is above zero, `trigger_track` spins up a coroutine
that emits a short series of quieter copies of that hit, each one re-triggering the
same sample voice directly.

Each track owns its own delay parameters:

- **decay** (`K3 + E2`, 0–95% in 5% steps) — how much level each successive ghost
  keeps. 0 means the delay is off and the track just hits once. The per-echo
  attenuation is computed in decibels (`20 * log10(decay)`) and applied
  cumulatively, so the trail fades geometrically.
- **division** (`K3 + E3`) — the spacing between ghosts, chosen from a tempo-synced
  table running 1/64 up to four bars (including triplet values). The gap is derived
  from the current tempo, so the trail stays locked to the clock rather than being
  a free-running millisecond delay.
- **drift** (`K1 + E1`, 0–2.0 semitones) — pitch instability on the echoes.

The retrigger loop is capped at 8 repeats and also bails out early once the
computed level drops below −60 dB, so a fast division with heavy decay doesn't run
forever. After the last ghost, the track's volume and playback speed are restored
to their base values, leaving the next real hit clean.

The detail that earns the name is **pitch drift**, and it's worth being precise
about it: it is a *random walk*, not a fixed interval. Each echo nudges a running
semitone offset by a random amount scaled by the drift setting, clamps it to a
window, and sets the voice's playback speed accordingly (`2^(st/12)`). At low
values that's a subtle tape-warble wobble on the repeats; turned up, the trail
smears unpredictably up and down. By default every track ships with decay at 0 and
drift at 0 — the delay is something you reach for, not a baked-in default.

Because every track schedules its own trail on its own division, decay and drift,
four simple euclidean patterns can produce a dense, asymmetric texture without any
of the patterns themselves getting more complex. The complexity lives in the
echoes, not the sequence.

## The hold-modifier control scheme

There are far more parameters than there are encoders, so the input model is a
hold-modifier layout: K1, K2 and K3 act as momentary modifiers, and what the
encoders do depends on which is held.

- **no modifier:** E1 selects the track, E2 sets beats, E3 sets rotation
- **hold K2:** E1 = track volume, E2 = low-pass cutoff, E3 = high-pass cutoff
- **hold K3:** E1 = pitch (sample speed), E2 = delay decay, E3 = delay division
- **hold K1:** E1 = delay pitch drift
- **K2 alone (on release):** mute / unmute the selected track
- **K2 + K3:** play / stop

The mute-on-release behavior is the fiddly bit, handled with `k2_combo` flags:
pressing K2 arms a mute, but if you then turn an encoder or press K3 while it's
held, a combo flag is set that suppresses the mute when K2 comes back up. So the
same key serves as both "mute this track" (tap) and "modifier" (hold-and-do-
something) without the two firing at once.

The right panel is modifier-aware to match what you can currently change. Normally
it shows the selected track's pitch (`PCH`), delay decay (`DCY`), division (`DLY`)
and drift (`DFT`); hold K2 and it swaps to the low-pass and high-pass cutoffs
(`LP`/`HP`) instead, and the readout for whichever modifier you're holding
brightens. The footer carries the global state: tempo (or `lnk` when Ableton Link
is the clock source), the selected track's volume in dB, and `PLAY`/`STOP`.

Unlike some sibling norns scripts, orbit keeps plain upright on-screen text — the
rings sit in the normal screen frame and the labels read normally, no rotation or
no-text constraint involved.

## Architecture

The script is a single Lua file driving the **Ack** engine (`engine.name = "Ack"`,
`require 'ack/lib/ack'`) for sample playback — Ack handles the per-channel samples,
filters, envelopes and the master delay bus, and orbit drives it through
`engine.trig`, `engine.volume` and `engine.speed`. Per-track state lives in a
`tracks[]` table (beats, length, rotation, mute, the resolved step pattern, and the
delay/filter values), with separate `track_pos` and `track_flash` arrays for the
running playhead and its glow.

The data flow is small and one-directional. Changing beats or rotation calls
`apply_euclid`, which recomputes that track's pattern once into `t.steps`; the clock
loop then just reads `t.steps[step]` each tick and never recomputes during playback.
Every live control is also mirrored into a real norns param. `init_params` builds
the full Ack per-channel param set under an `ORBIT` group, a global `DELAY` group,
and a `SEQUENCER` group whose entries (beats, rotation, mute, delay div/decay/drift,
LP/HP cutoffs) write straight back into the same `tracks` table — so PARAMS and the
on-screen controls manipulate one shared source of truth, and presets save and
restore the whole live state.

A couple of supporting pieces round it out: a master Ack delay bus held at 1/4 note
as an optional background wash (driven by `sync_delay`, separate from the per-track
ghost retriggers), per-track low/high-pass filters whose two cutoffs are stored
independently so switching between them doesn't lose a setting, and Ableton Link
support with start/stop sync — a linked DAW starts orbit on the next 4-bar boundary
and stops it on transport stop.

## Design intent

The guardrail is the constraint itself. The temptation with a drum machine is to
keep adding pattern surface — per-track step counts and tempos, swing, manual step
editing, more voices. orbit deliberately refuses most of that. The identity is that
the *spacing* (euclidean fill + rotation) and the *trails* (per-track ghost echoes
with tempo-synced timing, decibel decay, and a pitch-drift random walk) carry the
whole thing, displayed as four rings turning as one system. Any move toward manual
sequencing or per-track tempo would dissolve that central image and should be a
deliberate, confirmed choice rather than a quiet default.
