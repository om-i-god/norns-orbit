-- orbit.lua
-- four-track generative drum machine
-- euclidean rhythms + concentric ring visuals
--
-- CONTROLS:
--   E1          : track select
--   E2          : euclidean beats (density)
--   E3          : euclidean rotation
--   K2          : mute / unmute selected track  [on release, alone]
--   K2 + K3     : play / stop
--   K2 + E1     : volume for selected track
--   K2 + E2     : low pass filter cutoff for selected track
--   K2 + E3     : high pass filter cutoff for selected track
--   K3          : (modifier only)
--   K3 + E1     : pitch for selected track
--   K3 + E2     : per-track delay decay (0=off → 95%)
--   K3 + E3     : per-track delay division (tempo-synced)
--   K1 + E1     : per-track delay pitch drift (semitones)


engine.name = "Ack"

local Ack = require 'ack/lib/ack'

-- ============================================================
-- CONSTANTS
-- ============================================================

local NUM_TRACKS = 4
local MAX_STEPS  = 16
local FPS        = 30

local TRACK_NAMES = {"KICK", "CLAP", "CHHT", "OHHT"}
local TRACK_ABBR  = {"KK",   "CP",   "CH",   "OH"}

local AUDIO = "/home/we/dust/audio/"
local DEFAULT_SAMPLES = {
  AUDIO .. "x0x/808/808-BD.wav",
  AUDIO .. "x0x/808/808-CP.wav",
  AUDIO .. "x0x/909/909-CH.wav",
  AUDIO .. "x0x/909/909-OH.wav",
}

-- Euclidean defaults: {beats, length, rotation}
local DEFAULT_EUCLID = {
  {4, 16, 0},   -- kick:  4-on-floor
  {2, 16, 4},   -- clap:  beats 2+4
  {8, 16, 0},   -- chht:  8th notes
  {2, 16, 2},   -- ohht:  offbeats
}

-- Tempo-synced delay divisions (beats, where 1.0 = quarter note)
-- Triplet values: 1/48=triplet-32nd, 1/24=triplet-16th, 1/12=triplet-8th,
--                 1/6=triplet-quarter, 1/3=triplet-half
local DELAY_DIVS = {
  0.0625,  -- 1/64
  0.0833,  -- 1/48
  0.125,   -- 1/32
  0.1667,  -- 1/24
  0.25,    -- 1/16
  0.3333,  -- 1/12
  0.5,     -- 1/8
  0.6667,  -- 1/6
  0.75,    -- 3/16
  1.0,     -- 1/4
  1.3333,  -- 1/3
  1.5,     -- 3/8
  2.0,     -- 1/2
  3.0,     -- 3/4
  4.0,     -- 1bar
  8.0,     -- 2bar
  12.0,    -- 3bar
  16.0,    -- 4bar
}
local DELAY_NAMES = {
  "1/64","1/48","1/32","1/24","1/16","1/12",
  "1/8","1/6","3/16","1/4","1/3","3/8",
  "1/2","3/4","1bar","2bar","3bar","4bar",
}
local DEFAULT_DELAY_DIV = 10   -- 1/4 note

-- Visual: 4 concentric rings, kick innermost → ohht outermost
-- Left strip (0-24px): track labels
-- Circle centered at (74, 30): rings
-- Right panel (109-127px): per-track delay div + decay bar
local CX     = 74
local CY     = 30
local RADII  = {9, 15, 21, 27}   -- px, one per track
local RX     = 109                -- right panel x start
local TWO_PI = math.pi * 2

-- ============================================================
-- STATE
-- ============================================================

local playing       = false
local cur_track     = 1
local k1_held    = false
local k2_held    = false
local k2_combo   = false
local k3_held    = false
local k3_combo   = false

local seq_clock  = nil
local draw_clock = nil

local track_pos   = {}   -- current step index (1-based)
local track_flash = {}   -- brightness 0-15, decays after trigger

for i = 1, NUM_TRACKS do
  track_pos[i]   = 1
  track_flash[i] = 0
end

local tracks = {}

-- ============================================================
-- EUCLIDEAN
-- ============================================================

local function euclidean(beats, steps, rotation)
  if steps <= 0 then return {} end
  beats = math.max(0, math.min(beats, steps))
  local pattern, err = {}, 0
  for i = 1, steps do
    err = err + beats
    if err >= steps then pattern[i] = 1; err = err - steps
    else pattern[i] = 0 end
  end
  if beats > 0 and rotation > 0 then
    rotation = rotation % steps
    for _ = 1, rotation do
      table.insert(pattern, table.remove(pattern, 1))
    end
  end
  return pattern
end

local function apply_euclid(t)
  local pat = euclidean(t.beats, t.length, t.rotation)
  for i = 1, MAX_STEPS do t.steps[i] = pat[i] or 0 end
end

local function make_track(i)
  local de = DEFAULT_EUCLID[i]
  local t  = {
    beats       = de[1],
    length      = de[2],
    rotation    = de[3],
    mute        = false,
    steps       = {},
    delay_div   = DEFAULT_DELAY_DIV,  -- index into DELAY_DIVS
    delay_decay = 0.0,                -- 0=off, 0.95=slow fade
    delay_drift = 0.0,                -- max semitones of pitch drift per echo
    lp_cutoff   = 20000,              -- Hz, fully open
    hp_cutoff   = 20,                 -- Hz, fully open
  }
  for j = 1, MAX_STEPS do t.steps[j] = 0 end
  apply_euclid(t)
  return t
end

for i = 1, NUM_TRACKS do tracks[i] = make_track(i) end

-- ============================================================
-- TRIGGER + CLOCK
-- ============================================================

local function trigger_track(tidx)
  if tracks[tidx].mute then return end
  local t = tracks[tidx]
  local base_vol = params:get(tidx .. "_vol")
  engine.volume(tidx - 1, base_vol)
  engine.trig(tidx - 1)
  track_flash[tidx] = 15

  if t.delay_decay > 0 then
    clock.run(function()
      local base_speed = params:get(tidx .. "_speed")
      local div_secs   = DELAY_DIVS[t.delay_div] * 60 / clock.get_tempo()
      local db_step    = 20 * math.log10(t.delay_decay)
      local drift_st   = 0
      for rep = 1, 8 do
        clock.sleep(div_secs)
        local vol = base_vol + db_step * rep
        if vol < -60 then break end
        if t.delay_drift > 0 then
          drift_st = drift_st + (math.random() - 0.5) * t.delay_drift
          drift_st = util.clamp(drift_st, -t.delay_drift * 2, t.delay_drift * 2)
          engine.speed(tidx - 1, base_speed * (2 ^ (drift_st / 12)))
        end
        engine.volume(tidx - 1, vol)
        engine.trig(tidx - 1)
      end
      engine.volume(tidx - 1, base_vol)
      engine.speed(tidx - 1, base_speed)
    end)
  end
end

local function step_all()
  for i = 1, NUM_TRACKS do
    local t    = tracks[i]
    local step = track_pos[i]
    if t.steps[step] == 1 then trigger_track(i) end
    track_pos[i] = (track_pos[i] % t.length) + 1
  end
end

local function reset_positions()
  for i = 1, NUM_TRACKS do track_pos[i] = 1 end
end

local function start_sequencer()
  if seq_clock then clock.cancel(seq_clock) end
  reset_positions()
  seq_clock = clock.run(function()
    while true do
      clock.sync(0.25)   -- 1/16th note
      step_all()
    end
  end)
  playing = true
end

local function stop_sequencer()
  if seq_clock then clock.cancel(seq_clock); seq_clock = nil end
  for i = 1, NUM_TRACKS do track_flash[i] = 0 end
  playing = false
end

-- ============================================================
-- DELAY SYNC
-- ============================================================

local function sync_delay()
  -- Master Ack bus fixed at 1/4 note (background wash only)
  local secs = DELAY_DIVS[DEFAULT_DELAY_DIV] * 60 / clock.get_tempo()
  engine.delayTime(secs)
end

-- ============================================================
-- VISUAL HELPERS
-- ============================================================

-- Returns pixel position on ring i at step j
local function ring_xy(ring_i, step, total)
  local angle = TWO_PI * (step - 1) / total - math.pi / 2
  local r = RADII[ring_i]
  return CX + r * math.cos(angle),
         CY + r * math.sin(angle)
end

local function hz_str(hz)
  if hz >= 1000 then return string.format("%.0fk", hz / 1000)
  else return string.format("%.0f", hz) end
end

-- ============================================================
-- REDRAW
-- ============================================================

function redraw()
  screen.clear()

  for i = 1, NUM_TRACKS do
    local t   = tracks[i]
    local sel = (i == cur_track)
    local fl  = track_flash[i]

    -- Ring outline
    screen.level(sel and 3 or 1)
    screen.circle(CX, CY, RADII[i])
    screen.stroke()

    -- Step markers around the ring
    for j = 1, t.length do
      local x, y = ring_xy(i, j, t.length)
      local xi, yi = math.floor(x + 0.5), math.floor(y + 0.5)

      if t.steps[j] == 1 then
        -- Active step: filled dot
        local lv = t.mute and 2 or (sel and 7 or 4)
        screen.level(lv)
        screen.rect(xi - 1, yi - 1, 3, 3)
        screen.fill()
      else
        -- Inactive step: single pixel tick (selected track only)
        if sel then
          screen.level(2)
          screen.rect(xi, yi, 1, 1)
          screen.fill()
        end
      end
    end

    -- Playhead: bright dot at current position, flashes on trigger
    if playing or fl > 0 then
      local px, py = ring_xy(i, track_pos[i], t.length)
      local pxi, pyi = math.floor(px + 0.5), math.floor(py + 0.5)
      local lv = fl > 0 and math.min(15, fl + 4) or (sel and 10 or 5)
      screen.level(lv)
      screen.rect(pxi - 1, pyi - 1, 3, 3)
      screen.fill()
    end
  end

  -- Left panel: track labels + beat density
  for i = 1, NUM_TRACKS do
    local t   = tracks[i]
    local sel = (i == cur_track)
    local y   = 6 + (i - 1) * 15
    screen.level(t.mute and 2 or (sel and 15 or 5))
    screen.move(0, y)
    screen.text(TRACK_ABBR[i])
    screen.level(sel and 6 or 2)
    screen.move(0, y + 7)
    screen.text(t.beats .. "/" .. t.length)
  end

  -- Right panel: separator + delay or filter info depending on held key
  screen.level(2)
  screen.move(RX - 1, 0); screen.line(RX - 1, 57); screen.stroke()

  local td = tracks[cur_track]
  if k2_held then
    -- LP / HP cutoffs
    screen.level(4)
    screen.move(RX, 6); screen.text("LP")
    screen.level(15)
    screen.move(RX, 16); screen.text(hz_str(td.lp_cutoff))

    screen.level(4)
    screen.move(RX, 30); screen.text("HP")
    screen.level(15)
    screen.move(RX, 40); screen.text(hz_str(td.hp_cutoff))
  else
    -- Pitch / decay / div / drift
    local speed  = params:get(cur_track .. "_speed")
    local st     = math.floor(12 * math.log(speed) / math.log(2) + 0.5)
    local st_str = (st >= 0 and "+" or "") .. st .. "st"

    screen.level(4)
    screen.move(RX, 5); screen.text("PCH")
    screen.level(k3_held and 15 or 8)
    screen.move(RX, 11); screen.text(st_str)

    local dcy_pct = math.floor(td.delay_decay * 100 + 0.5)
    screen.level(4)
    screen.move(RX, 20); screen.text("DCY")
    screen.level(k3_held and 15 or 8)
    screen.move(RX, 26); screen.text(dcy_pct .. "%")

    local div_str = td.delay_decay == 0 and "off" or DELAY_NAMES[td.delay_div]
    screen.level(4)
    screen.move(RX, 35); screen.text("DLY")
    screen.level(k3_held and 15 or 8)
    screen.move(RX, 41); screen.text(div_str)

    local dft_str = string.format("%.1fst", td.delay_drift)
    screen.level(4)
    screen.move(RX, 50); screen.text("DFT")
    screen.level(k1_held and 15 or 8)
    screen.move(RX, 56); screen.text(dft_str)
  end

  -- Footer: BPM + clock source + delay rate + play state
  local clk_src = params:string("clock_source")
  screen.level(clk_src == "link" and 12 or 3)
  screen.move(0, 63)
  screen.text(math.floor(clock.get_tempo()) .. (clk_src == "link" and "lnk" or "bpm"))
  screen.level(k2_held and 12 or 3)
  screen.move(40, 63)
  screen.text(TRACK_ABBR[cur_track] .. ":" .. string.format("%+.0fdB", params:get(cur_track .. "_vol")))
  screen.level(playing and 12 or 3)
  screen.move(80, 63)
  screen.text(playing and "PLAY" or "STOP")

  screen.update()
end

-- ============================================================
-- KEYS
-- ============================================================

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
  elseif n == 2 then
    if z == 1 then
      k2_held  = true
      k2_combo = false
    else
      if not k2_combo then
        tracks[cur_track].mute = not tracks[cur_track].mute
        params:set(cur_track .. "_mute", tracks[cur_track].mute and 1 or 0)
      end
      k2_held  = false
      k2_combo = false
    end
  elseif n == 3 then
    if z == 1 then
      k3_held  = true
      k3_combo = false
      if k2_held then
        k2_combo = true   -- suppress mute on K2 release
        if playing then stop_sequencer() else start_sequencer() end
      end
    else
      k3_held  = false
      k3_combo = false
    end
  end
  redraw()
end

-- ============================================================
-- ENCODERS
-- ============================================================

function enc(n, d)
  if n == 1 then
    if k1_held then
      local t = tracks[cur_track]
      local steps = util.clamp(math.floor(t.delay_drift * 10 + 0.5) + d, 0, 20)
      t.delay_drift = steps / 10
      params:set(cur_track .. "_dly_dft", steps)
    elseif k3_held then
      k3_combo = true
      params:delta(cur_track .. "_speed", d)
    elseif k2_held then
      k2_combo = true
      params:delta(cur_track .. "_vol", d)
    else
      cur_track = util.clamp(cur_track + d, 1, NUM_TRACKS)
    end
  elseif n == 2 then
    if k3_held then
      k3_combo = true
      local t = tracks[cur_track]
      -- step decay in 5% increments, 0→95%
      local steps = util.clamp(math.floor(t.delay_decay * 20 + 0.5) + d, 0, 19)
      t.delay_decay = steps / 20
      params:set(cur_track .. "_dly_dcy", steps)
    elseif k2_held then
      k2_combo = true
      local t = tracks[cur_track]
      t.lp_cutoff = util.clamp(t.lp_cutoff * (2 ^ (d / 12)), 20, 20000)
      params:set(cur_track .. "_filter_mode",  1)
      params:set(cur_track .. "_filter_cutoff", t.lp_cutoff)
      params:set(cur_track .. "_lp_cut",        math.floor(t.lp_cutoff + 0.5))
    else
      local t = tracks[cur_track]
      t.beats = util.clamp(t.beats + d, 0, t.length)
      params:set(cur_track .. "_beats", t.beats)
      apply_euclid(t)
    end
  elseif n == 3 then
    if k3_held then
      k3_combo = true
      local t = tracks[cur_track]
      t.delay_div = util.clamp(t.delay_div + d, 1, #DELAY_DIVS)
      params:set(cur_track .. "_dly_div", t.delay_div)
    elseif k2_held then
      k2_combo = true
      local t = tracks[cur_track]
      t.hp_cutoff = util.clamp(t.hp_cutoff * (2 ^ (d / 12)), 20, 20000)
      params:set(cur_track .. "_filter_mode",   3)
      params:set(cur_track .. "_filter_cutoff", t.hp_cutoff)
      params:set(cur_track .. "_hp_cut",        math.floor(t.hp_cutoff + 0.5))
    else
      local t = tracks[cur_track]
      if t.length > 0 then
        t.rotation = (t.rotation + d) % t.length
        params:set(cur_track .. "_rotation", t.rotation)
        apply_euclid(t)
      end
    end
  end
  redraw()
end

-- ============================================================
-- PARAMS
-- ============================================================

local function init_params()
  params:add_separator("ORBIT")
  for ch = 1, NUM_TRACKS do
    Ack.add_channel_sample_param(ch)
    Ack.add_start_pos_param(ch)
    Ack.add_end_pos_param(ch)
    Ack.add_loop_param(ch)
    Ack.add_loop_point_param(ch)
    Ack.add_speed_param(ch)
    Ack.add_vol_param(ch)
    Ack.add_vol_env_atk_param(ch)
    Ack.add_vol_env_rel_param(ch)
    Ack.add_pan_param(ch)
    Ack.add_filter_mode_param(ch)
    Ack.add_filter_cutoff_param(ch)
    Ack.add_filter_res_param(ch)
    Ack.add_filter_env_atk_param(ch)
    Ack.add_filter_env_rel_param(ch)
    Ack.add_filter_env_mod_param(ch)
    Ack.add_bit_depth_param(ch)
    Ack.add_dist_param(ch)
    Ack.add_mutegroup_param(ch)
    Ack.add_delay_send_param(ch)
    params:add_separator()
  end
  -- Delay (time driven by tempo sync, not exposed as raw param)
  params:add_control("delay_feedback", "delay feedback", Ack.specs.delay_feedback)
  params:set_action("delay_feedback", engine.delayFeedback)
  params:add_control("delay_level", "delay level", Ack.specs.delay_level)
  params:set_action("delay_level", engine.delayLevel)
  Ack.add_main_level_param()
  for i = 1, NUM_TRACKS do
    params:set(i .. "_sample", DEFAULT_SAMPLES[i])
    params:set(i .. "_vol",    -6)
  end

  -- Sequencer state (backs the Lua track table so presets save everything)
  params:add_separator("SEQUENCER")
  for i = 1, NUM_TRACKS do
    params:add_number(i .. "_beats",    i .. ": beats",       0, MAX_STEPS,     DEFAULT_EUCLID[i][1])
    params:set_action(i .. "_beats",    function(v) tracks[i].beats    = v; apply_euclid(tracks[i]) end)
    params:add_number(i .. "_rotation", i .. ": rotation",    0, MAX_STEPS - 1, DEFAULT_EUCLID[i][3])
    params:set_action(i .. "_rotation", function(v) tracks[i].rotation = v; apply_euclid(tracks[i]) end)
    params:add_number(i .. "_mute",     i .. ": mute",        0, 1,             0)
    params:set_action(i .. "_mute",     function(v) tracks[i].mute     = (v == 1) end)
    params:add_number(i .. "_dly_div",  i .. ": delay div",   1, #DELAY_DIVS,  DEFAULT_DELAY_DIV)
    params:set_action(i .. "_dly_div",  function(v) tracks[i].delay_div   = v end)
    params:add_number(i .. "_dly_dcy",  i .. ": delay decay", 0, 19,            0)
    params:set_action(i .. "_dly_dcy",  function(v) tracks[i].delay_decay = v / 20 end)
    params:add_number(i .. "_dly_dft",  i .. ": delay drift", 0, 20,            0)
    params:set_action(i .. "_dly_dft",  function(v) tracks[i].delay_drift = v / 10 end)
    params:add_number(i .. "_lp_cut",   i .. ": lp cutoff",   20, 20000,        20000)
    params:set_action(i .. "_lp_cut",   function(v) tracks[i].lp_cutoff  = v end)
    params:add_number(i .. "_hp_cut",   i .. ": hp cutoff",   20, 20000,        20)
    params:set_action(i .. "_hp_cut",   function(v) tracks[i].hp_cutoff  = v end)
  end
end

-- ============================================================
-- INIT / CLEANUP
-- ============================================================

function init()
  math.randomseed(os.time())
  playing = false
  init_params()
  params:read()
  params:bang()
  clock.link.set_start_stop_sync(true)
  clock.transport.start = function()
    clock.run(function()
      clock.sleep(0.05)
      clock.sync(4)
      if not playing then start_sequencer() end
    end)
  end
  clock.transport.stop = function()
    if playing then stop_sequencer() end
  end
  draw_clock = clock.run(function()
    while true do
      if not _menu.mode then
        sync_delay()
        -- Decay flash values each frame
        for i = 1, NUM_TRACKS do
          if track_flash[i] > 0 then
            track_flash[i] = math.max(0, track_flash[i] - 3)
          end
        end
        redraw()
      end
      clock.sleep(1 / FPS)
    end
  end)
end

function cleanup()
  stop_sequencer()
  if draw_clock then clock.cancel(draw_clock) end
end
