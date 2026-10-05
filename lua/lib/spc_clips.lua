-- SPC clip player: plays sound effects captured from another SNES game (clips, see tools/spc_clip.py)
-- inside the running host game, by driving one of the host's DSP voices directly.
--
-- How it works:
--   Samples. A clip's BRR samples are written into host sound RAM and pointed to by spare entries of
--   the host's sample directory (DSP DIR). Small ones go into RAM the host never touches (profile.free,
--   written at install). Big ones are *borrowed*: written over a host sample (profile.borrow) that no
--   voice is playing, only when a clip needs it. If the host then picks that sample (a SRCN write or a
--   key-on that would play it), the original bytes are put back inside the same write callback, before
--   the DSP reads them, and the clip that used them stops.
--   Voices. A clip plays on a borrowed host voice (profile.lanes, one per lane). While it plays, a write
--   callback on the SPC's DSP ports ($F2 address / $F3 data) replaces the host driver's writes to that
--   voice with ours (Mesen: a write callback's return value replaces the written value), keeps the host
--   from keying it off, and keeps it out of echo/noise/pitch-mod. The host's swallowed writes are
--   remembered and put back when the clip ends, so the host's music/effects on that voice carry on with
--   the right instrument. If the host keys the voice on itself, a lane with yield = true gives it up
--   (two effects on one voice, latest wins, as on a real SNES); yield = false keeps it (for a voice the
--   host's music also uses, so a note can't cut the clip).
--   Clock. Clip events are stamped in 32 kHz DSP samples. The host driver polls its timer counter
--   ($FD-$FF, reads clear it); a read callback adds (ticks read x timer period) to our clock and applies
--   every event that is due. So events land on the host driver's own tick (SGnG: 125 Hz), well below
--   a frame. emu.getState() is too slow to call per tick (0.26 ms), callbacks are nearly free.
--
-- Host profile (owned by the host adapter):
--   dirSlots = { n, ... }        spare sample-directory entries (DIR base is read from DSP $5D)
--   free     = { {first, last} } sound RAM nobody touches
--   borrow   = { srcn, ... }      host samples that may be borrowed while silent (preference order)
--   sums     = { [srcn] = n }     expected checksum of each borrowable sample (see M.checksum)
--   lanes    = { {voice=, yield=}, ... }  host voices to borrow; lane 1 = the main one
--   timer    = 0..2              the timer the host driver polls
-- Rules: install only during gameplay, uninstall when leaving it; all sound RAM and DSP
-- writes go through here.
local M = {}
M.__index = M
local DSP, ARAM, SPCMEM = emu.memType.spcDspRegisters, emu.memType.spcRam, emu.memType.spcMemory
local KON, KOF, EON, NON, PMON = 0x4C, 0x5C, 0x4D, 0x3D, 0x2D

local function hexbytes(hex)
  return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- Checksum of a byte string (to recognise a host sample: detects one we left borrowed in a savestate).
function M.checksum(s)
  local a, b = 1, 0
  for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
  return b * 65536 + a
end

local function readBytes(addr, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char(emu.read(addr + i, ARAM, false)) end
  return table.concat(t)
end

local function writeBytes(addr, s)
  for i = 1, #s do emu.write(addr + i - 1, s:byte(i), ARAM) end
end

-- BRR sample length in bytes starting at addr (through the block with the end flag).
local function brrLength(addr)
  local p = addr
  while p + 9 <= 0x10000 do
    local h = emu.read(p, ARAM, false)
    p = p + 9
    if h & 1 == 1 then break end
  end
  return p - addr
end

-- opts.onError(traceback): optional error reporter for the SPC callbacks
function M.new(profile, data, opts)
  local self = setmetatable({
    P = profile, clips = data.clips, samples = {}, lanes = {}, byVoice = {},
    installed = false, clock = 0, period = 256, dspAddr = 0,
    borrowed = {},   -- host srcn -> our sample record currently sitting on it
    origCache = {},  -- host srcn -> its original bytes (kept for the session, checksum-verified)
    hostUse = {},    -- host srcn -> key-ons by the host since install (to pick what to borrow)
    volume = 1.0,    -- scales the clips' VOL registers
    log = nil,       -- optional function(text) for diagnostics
  }, M)
  for srcn, s in pairs(data.samples) do
    self.samples[srcn] = { srcn = srcn, bytes = hexbytes(s.brr), loop = s.loop }
  end
  -- which samples each clip needs (its first SRCN plus any SRCN changes)
  for _, c in pairs(self.clips) do
    local need = { [c.regs[5]] = true }
    for _, e in ipairs(c.events) do if e[2] == 4 then need[e[3]] = true end end
    c.need = need
  end
  for i, l in ipairs(profile.lanes) do
    local v = l.voice
    local lane = { voice = v, bit = 1 << v, yield = l.yield, active = false, shadow = {}, hostRegs = {}, ev = 1, t0 = 0 }
    self.lanes[i] = lane
    self.byVoice[v] = lane
  end
  self.onError = (opts or {}).onError
  self:hook()
  return self
end

function M:say(fmt, ...) if self.log then self.log(string.format(fmt, ...)) end end

-- ---------------------------------------------------------------- install / uninstall
function M:install()
  if self.installed then return true end
  self.dir = emu.read(0x5D, DSP, false) << 8
  local target = emu.getState()["spc.timer" .. self.P.timer .. ".target"] or 0
  if target == 0 then target = 256 end
  self.period = target * (self.P.timer == 2 and 0.5 or 4) -- timers 0/1 count at 8 kHz, timer 2 at 64 kHz
  self.saved = {} -- {addr, original bytes} for everything written at install
  local function save(addr, n) self.saved[#self.saved + 1] = { addr, readBytes(addr, n) } end

  -- directory slots, biggest samples first into the free regions (first fit)
  local list = {}
  for _, s in pairs(self.samples) do list[#list + 1] = s end
  table.sort(list, function(a, b) return #a.bytes > #b.bytes end)
  if #list > #self.P.dirSlots then self:say("more samples than spare directory slots"); return false end
  local cursor = {}
  for i, r in ipairs(self.P.free) do cursor[i] = r[1] end
  for i, s in ipairs(list) do
    s.slot = self.P.dirSlots[i]
    s.addr, s.resident, s.on = nil, false, nil
    for j, r in ipairs(self.P.free) do
      if cursor[j] + #s.bytes - 1 <= r[2] then
        s.addr = cursor[j]
        cursor[j] = cursor[j] + #s.bytes
        break
      end
    end
  end
  for _, s in ipairs(list) do
    save(self.dir + s.slot * 4, 4)
    if s.addr then
      save(s.addr, #s.bytes)
      writeBytes(s.addr, s.bytes)
      self:setDir(s, s.addr)
      s.resident = true
    end
  end
  self.hostUse, self.borrowed = {}, {}
  self.installed = true
  self:say("installed: DIR %04X, timer period %d samples", self.dir, self.period)
  return true
end

function M:setDir(s, addr)
  local e = self.dir + s.slot * 4
  local loop = addr + (s.loop or 0)
  emu.write(e, addr & 0xFF, ARAM); emu.write(e + 1, addr >> 8, ARAM)
  emu.write(e + 2, loop & 0xFF, ARAM); emu.write(e + 3, loop >> 8, ARAM)
end

function M:uninstall()
  if not self.installed then return end
  for _, lane in ipairs(self.lanes) do self:stopLane(lane) end
  for hs in pairs(self.borrowed) do self:giveBack(hs) end
  for i = #self.saved, 1, -1 do writeBytes(self.saved[i][1], self.saved[i][2]) end
  self.saved = {}
  self.installed = false
  self:say("uninstalled")
end

-- A savestate was loaded: sound RAM and the DSP are whatever the state holds. Forget, don't restore.
function M:forget()
  for _, lane in ipairs(self.lanes) do lane.active = false end
  for _, s in pairs(self.samples) do s.resident = false; s.on = nil end
  self.borrowed, self.saved, self.installed = {}, {}, false
end

-- ---------------------------------------------------------------- borrowing host samples
function M:hostSample(hs)
  local e = self.dir + hs * 4
  local start = emu.read(e, ARAM, false) | emu.read(e + 1, ARAM, false) << 8
  return start, brrLength(start)
end

function M:audible(hs)
  for v = 0, 7 do
    if not (self.byVoice[v] and self.byVoice[v].active) and emu.read(v * 16 + 4, DSP, false) == hs
        and emu.read(v * 16 + 8, DSP, false) > 0 then
      return true
    end
  end
  return false
end

function M:borrow(s)
  local best, bestUse
  for _, hs in ipairs(self.P.borrow) do
    if not self.borrowed[hs] then
      local start, len = self:hostSample(hs)
      if len >= #s.bytes and not self:audible(hs) then
        local use = self.hostUse[hs] or 0
        if not best or use < bestUse then best, bestUse = hs, use end
      end
    end
  end
  if not best then return false end
  local start, len = self:hostSample(best)
  local orig = readBytes(start, len)
  local sum = self.P.sums and self.P.sums[best]
  if sum and M.checksum(orig) ~= sum then
    -- not the host's sample (a savestate made mid-borrow?): repair from the session cache or skip
    if not self.origCache[best] then self:say("host sample %d has unexpected contents; not borrowing", best); return false end
    orig = self.origCache[best]
  end
  self.origCache[best] = orig
  self.borrowed[best] = { s = s, start = start, orig = orig }
  writeBytes(start, s.bytes)
  self:setDir(s, start)
  s.resident, s.on = true, best
  self:say("borrowed host sample %d (%d bytes at %04X) for clip sample %02X", best, len, start, s.srcn)
  return true
end

function M:giveBack(hs)
  local b = self.borrowed[hs]
  if not b then return end
  writeBytes(b.start, b.orig)
  b.s.resident, b.s.on = false, nil
  self.borrowed[hs] = nil
  for _, lane in ipairs(self.lanes) do
    if lane.active and lane.clip.need[b.s.srcn] then self:stopLane(lane) end
  end
  self:say("gave back host sample %d", hs)
end

-- ---------------------------------------------------------------- playing
function M:writeReg(lane, r, val)
  if r == 4 then
    val = self.samples[val] and self.samples[val].slot or val
  elseif r <= 1 and self.volume ~= 1.0 then
    local sv = val >= 0x80 and val - 0x100 or val
    sv = math.max(-128, math.min(127, math.floor(sv * self.volume + 0.5)))
    val = sv & 0xFF
  end
  lane.shadow[r] = val
  emu.write(lane.voice * 16 + r, val, DSP)
end

function M:keyOn(lane)
  lane.kof = false
  emu.write(KOF, emu.read(KOF, DSP, false) & ~lane.bit, DSP)
  emu.write(KON, lane.bit, DSP)
end

-- Play clip `name` on lane `laneNo` (default 1). Restarts the lane if it is already playing.
function M:play(name, laneNo)
  if not self.installed then return false end
  local c, lane = self.clips[name], self.lanes[laneNo or 1]
  if not c or not lane then return false end
  for srcn in pairs(c.need) do
    local s = self.samples[srcn]
    if not s.resident and not self:borrow(s) then
      self:say("%s: no room for sample %02X", name, srcn)
      return false
    end
  end
  if not lane.active then
    for r = 0, 7 do lane.hostRegs[r] = emu.read(lane.voice * 16 + r, DSP, false) end
  end
  lane.clip, lane.ev, lane.t0, lane.active = c, 1, self.clock, true
  for _, r in ipairs({ EON, NON, PMON }) do emu.write(r, emu.read(r, DSP, false) & ~lane.bit, DSP) end
  for r = 0, 7 do self:writeReg(lane, r, c.regs[r + 1]) end
  self:keyOn(lane)
  return true
end

-- The lane gives its voice back: the host's latest register values go back in.
function M:release(lane)
  lane.active = false
  for r = 0, 7 do emu.write(lane.voice * 16 + r, lane.hostRegs[r], DSP) end
end

function M:stopLane(lane)
  if not lane.active then return end
  emu.write(KOF, emu.read(KOF, DSP, false) | lane.bit, DSP)
  self:release(lane)
end

function M:playing(laneNo) return self.lanes[laneNo or 1].active end

function M:step()
  for _, lane in ipairs(self.lanes) do
    if lane.active then
      local c, t = lane.clip, self.clock - lane.t0
      local ev = c.events
      while lane.ev <= #ev and ev[lane.ev][1] <= t do
        local e = ev[lane.ev]
        lane.ev = lane.ev + 1
        if e[2] == KON then
          self:keyOn(lane)
        elseif e[2] == KOF then
          lane.kof = true
          emu.write(KOF, emu.read(KOF, DSP, false) | lane.bit, DSP)
        else
          self:writeReg(lane, e[2], e[3])
        end
      end
      if t >= c.length then self:release(lane) end -- already silent: the voice goes back to the host
    end
  end
end

-- ---------------------------------------------------------------- SPC callbacks
function M:activeMask()
  local m = 0
  for _, lane in ipairs(self.lanes) do if lane.active then m = m | lane.bit end end
  return m
end

function M:onDspWrite(value)
  local r = self.dspAddr
  if r >= 0x80 or not self.installed then return nil end
  local lo, v = r & 0x0F, r >> 4
  if lo <= 7 then
    local lane = self.byVoice[v]
    if lane and lane.active then -- our voice: keep our value, remember the host's
      lane.hostRegs[lo] = value
      return lane.shadow[lo]
    end
    if lo == 4 and self.borrowed[value] then self:giveBack(value) end -- host is about to use it
    return nil
  end
  if r == KON then
    local strip = 0
    for vv = 0, 7 do
      if value >> vv & 1 == 1 then
        local lane = self.byVoice[vv]
        if lane and lane.active then
          if lane.yield then
            self:release(lane) -- the host keys its own sound on this voice: host wins
            self:say("host took voice %d", vv)
          else
            strip = strip | lane.bit
          end
        end
        if strip & (1 << vv) == 0 then
          local hs = emu.read(vv * 16 + 4, DSP, false)
          self.hostUse[hs] = (self.hostUse[hs] or 0) + 1
          if self.borrowed[hs] then self:giveBack(hs) end
        end
      end
    end
    if strip ~= 0 then return value & ~strip end
    return nil
  end
  local mask = self:activeMask()
  if mask == 0 then return nil end
  if r == KOF then
    local ours = 0
    for _, lane in ipairs(self.lanes) do if lane.active and lane.kof then ours = ours | lane.bit end end
    return (value & ~mask) | ours
  end
  if r == EON or r == NON or r == PMON then return value & ~mask end
  return nil
end

-- Run fn(...) and pass its result through; report errors (Mesen swallows errors in callbacks).
function M:try(fn, ...)
  local ok, res = xpcall(fn, debug.traceback, ...)
  if ok then return res end
  if self.onError then self.onError(res) end
  return nil
end

function M:hook()
  local function onData(value) return self:onDspWrite(value) end
  local function onTick(value)
    self.clock = self.clock + value * self.period
    self:step()
  end
  -- $F2 writes only latch the DSP register address
  emu.addMemoryCallback(function(addr, value)
    if addr == 0xF2 then self.dspAddr = value; return nil end
    if not self.installed then return nil end
    return self:try(onData, value)
  end, emu.callbackType.write, 0xF2, 0xF3, emu.cpuType.spc, SPCMEM)
  local counter = 0xFD + self.P.timer
  emu.addMemoryCallback(function(addr, value)
    if value > 0 and self.installed then self:try(onTick, value) end
  end, emu.callbackType.read, counter, counter, emu.cpuType.spc, SPCMEM)
  if emu.eventType.stateLoaded then
    emu.addEventCallback(function() self:forget() end, emu.eventType.stateLoaded)
  end
end

return M
