-- Repaint part of a static screen (title logo, menus...) live through VRAM; put it all back afterwards.
--
-- The patch comes from tools/screen_patch.py (the user edits a PNG of the screen; the tool works out layers,
-- palettes and final tiles). At runtime, once the screen is really there, each patched map cell gets its
-- final tile written into a VRAM tile nothing uses and the cell is pointed at it. Tiles shared with other
-- cells (or drawn flipped elsewhere) stay untouched, and no ROM is patched (SGnG's art is compressed).
--
--   local bgpatch = dofile(".../lib/bg_patch.lua")
--   local p = bgpatch.new(dofile("assets/.../patch.lua"))
--   p:show()   -- every frame while the host says the screen is up (applies once, keeps it applied)
--   p:hide()   -- every frame otherwise (restores once)
--
-- "Really there" = BG mode and each patched layer's registers as captured, display on, and every patched
-- cell holding the captured map word and tile (hash). A game may flag a screen before programming the
-- PPU: SGnG's title flag comes on 2 frames early, and painting then (first version, which checked map
-- words only) wrote over the logo's map. Call from startFrame (VRAM writes then show this frame).
local M = {}
local VRAM = emu.memType.snesVideoRam

local function rd(a) return emu.read(a & 0xFFFF, VRAM, false) end
local function rw(a) return rd(a) | (rd(a + 1) << 8) end
local function ww(a, v) emu.write(a & 0xFFFF, v & 255, VRAM); emu.write((a + 1) & 0xFFFF, (v >> 8) & 255, VRAM) end

-- 32-bit FNV-1a over n bytes of VRAM (tools/snesgfx.py fnv1a computes the same offline)
local function hash(a, n)
  local h = 2166136261
  for k = 0, n - 1 do h = ((h ~ rd(a + k)) * 16777619) & 0xFFFFFFFF end
  return h
end

local function unhex(s)
  local t = {}
  for i = 1, #s, 2 do t[#t + 1] = tonumber(s:sub(i, i + 1), 16) end
  return t
end

-- Diagnostics go to the file named by the global KIT_ERRLOG (set by lua/lib/kit.lua), if any.
local function log(msg)
  local f = KIT_ERRLOG and io.open(KIT_ERRLOG, "a")
  if f then f:write(os.date() .. " bg_patch: " .. msg .. "\n"); f:close() end
end

local Patch = {}
Patch.__index = Patch

function M.new(patch)
  for _, g in ipairs(patch.layers) do
    for _, c in ipairs(g.cells) do c.bytes = unhex(c.tile) end
  end
  return setmetatable({ patch = patch, applied = nil, retryAt = 0, frame = 0 }, Patch)
end

-- Is the captured screen up, fully set up? Returns the PPU state when it is.
function Patch:matches()
  local st = emu.getState()
  if st["ppu.bgMode"] ~= self.patch.mode or st["ppu.forcedBlank"] then return nil end
  for _, g in ipairs(self.patch.layers) do
    local L = "ppu.layers[" .. g.bg .. "]."
    if st[L .. "chrAddress"] ~= g.chr or st[L .. "tilemapAddress"] ~= g.map
      or (st[L .. "doubleWidth"] == true) ~= (g.w == 64) or (st[L .. "doubleHeight"] == true) ~= (g.h == 64) then
      return nil
    end
    local size = 8 * g.bpp
    for _, c in ipairs(g.cells) do
      if rw(g.map * 2 + c.off) ~= c.word then return nil end
      if hash(g.chr * 2 + (c.word & 0x3FF) * size, size) ~= c.hash then return nil end
    end
  end
  return st
end

-- Blank tiles no cell of this layer's map references, below the next VRAM region (other layers' maps or
-- characters, sprites) so we never write into data something else reads.
local function freeTiles(st, g)
  local chr, size = g.chr * 2, 8 * g.bpp
  local limit = 0x10000
  for i = 0, 3 do
    for _, k in ipairs({ "chrAddress", "tilemapAddress" }) do
      local a = (st["ppu.layers[" .. i .. "]." .. k] or 0) * 2
      if a > chr and a < limit then limit = a end
    end
  end
  local obj = (st["ppu.oamBaseAddress"] or 0) * 2
  if obj > chr and obj < limit then limit = obj end
  local used = {}
  for i = 0, g.w * g.h - 1 do used[rw(g.map * 2 + i * 2) & 0x3FF] = true end
  local free = {}
  for n = 1, math.min(1023, (limit - chr) // size - 1) do
    if not used[n] then
      local a, blank = chr + n * size, true
      for k = 0, size - 1 do if rd(a + k) ~= 0 then blank = false; break end end
      if blank then free[#free + 1] = n end
    end
  end
  return free
end

function Patch:apply()
  local st = self:matches()
  if not st then return false end
  local applied = { cells = {}, tiles = {} }
  local plan = {}
  for _, g in ipairs(self.patch.layers) do
    local free = freeTiles(st, g)
    if #free < #g.cells then
      if not self.warned then self.warned = true; log("BG" .. (g.bg + 1) .. ": " .. #free .. " free tiles, need " .. #g.cells) end
      return false
    end
    plan[#plan + 1] = { g = g, free = free }
  end
  for _, p in ipairs(plan) do
    local g, size = p.g, 8 * p.g.bpp
    for i, c in ipairs(g.cells) do
      local n = p.free[i]
      local taddr = g.chr * 2 + n * size
      for k = 1, size do emu.write((taddr + k - 1) & 0xFFFF, c.bytes[k], VRAM) end
      local maddr = g.map * 2 + c.off
      local new = n | (c.pal << 10) | (c.word & 0x2000) -- flips are baked into the tile; keep priority
      ww(maddr, new)
      applied.cells[#applied.cells + 1] = { addr = maddr, orig = c.word, new = new }
      applied.tiles[#applied.tiles + 1] = { addr = taddr, bytes = c.bytes, size = size }
    end
  end
  self.applied = applied
  return true
end

-- Put back what we changed, but only where our data is still there: if the game already loaded the
-- next screen over it, its new data stays.
function Patch:restore()
  local a = self.applied
  if not a then return end
  for _, c in ipairs(a.cells) do
    if rw(c.addr) == c.new then ww(c.addr, c.orig) end
  end
  for _, t in ipairs(a.tiles) do
    local ours = true
    for k = 1, t.size do if rd(t.addr + k - 1) ~= t.bytes[k] then ours = false; break end end
    if ours then for k = 0, t.size - 1 do emu.write((t.addr + k) & 0xFFFF, 0, VRAM) end end -- were blank
  end
  self.applied = nil
end

function Patch:intact()
  for _, c in ipairs(self.applied.cells) do
    if rw(c.addr) ~= c.new then return false end
  end
  for _, t in ipairs(self.applied.tiles) do
    for k = 1, t.size do if rd(t.addr + k - 1) ~= t.bytes[k] then return false end end
  end
  return true
end

function Patch:show()
  self.frame = self.frame + 1
  if self.applied then
    if self:intact() then return end
    self:restore() -- the game redrew the screen, wrote over our tiles, or moved on: start over
  end
  if self.frame < self.retryAt then return end
  if not self:apply() then self.retryAt = self.frame + 2 end -- not our screen (yet): re-check soon
end

function Patch:hide()
  if self.applied then self:restore() end
  self.retryAt = 0
end

return M
