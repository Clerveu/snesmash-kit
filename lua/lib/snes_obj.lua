-- Draw your own sprites through the real SNES PPU from a Mesen Lua script.
--
-- Call everything from an emu.eventType.startFrame callback: by then the game's vblank DMA has
-- filled OAM/VRAM/CGRAM for the frame about to be drawn, and anything written now is what the PPU
-- renders. The game overwrites it all again next vblank, so redraw every frame.
--
--   local obj = dofile(".../lib/snes_obj.lua")
--   local layer = obj.new{ tiles = {0,1,2,...}, palette = 0 }   -- OBJ tile numbers + palette we own
--   layer:setColors({ [1] = 0xRRGGBB, ... })                     -- palette entries 1-15
--   layer:setColors(colors, p)                                   -- ...of another OBJ palette p
--   local tile = obj.encodeTile(pixels8x8)                       -- 64 indices -> 32-byte 4bpp string
--   layer:begin()                                                -- read this frame's OAM
--   layer:hide(function(e) return e.pal == 0 end)                -- take some of the game's slots
--   layer:sprite(x, y, tile, { hflip = true, prio = 2, pal = p })  -- queue 8x8 sprites
--   layer:sprite16(x, y, tile4, opts)                            -- 16x16 (tile4 = 4 tiles TL,TR,BL,BR
--                                                                --  concatenated; needs cfg.blocks)
--   local p = layer:freePalette({ 6, 4 })                        -- an OBJ palette nobody uses now
--   layer:flush()                                                -- write tiles + OAM
local M = {}

local VRAM, OAM, CGRAM = emu.memType.snesVideoRam, emu.memType.snesSpriteRam, emu.memType.snesCgRam
local OFFSCREEN_Y = 240

-- pixels: flat array of 64 palette indices (row-major, 0 = transparent) -> SNES 4bpp planar tile
function M.encodeTile(px)
  local lo, hi = {}, {}
  for r = 0, 7 do
    local p0, p1, p2, p3 = 0, 0, 0, 0
    for c = 0, 7 do
      local v = px[r * 8 + c + 1] or 0
      local bit = 1 << (7 - c)
      if v & 1 ~= 0 then p0 = p0 | bit end
      if v & 2 ~= 0 then p1 = p1 | bit end
      if v & 4 ~= 0 then p2 = p2 | bit end
      if v & 8 ~= 0 then p3 = p3 | bit end
    end
    lo[#lo + 1] = string.char(p0, p1)
    hi[#hi + 1] = string.char(p2, p3)
  end
  return table.concat(lo) .. table.concat(hi)
end

function M.bgr555(rgb)
  local r, g, b = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
  return (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
end

local Layer = {}
Layer.__index = Layer

-- cfg.tiles: OBJ tile numbers (0-511) this layer may overwrite in VRAM (8x8 sprites).
-- cfg.blocks: top-left tile numbers of 2x2 tile blocks (t, t+1, t+16, t+17) for 16x16 sprites.
--   Large OAM sprites cost 1 OAM slot instead of 4 and count once toward the 32-sprites-per-line
--   limit. Assumes OBSEL size mode 0 (8x8 / 16x16).
-- cfg.palette: OBJ palette 0-7 this layer draws with.
-- cfg.base / cfg.offset: OBSEL name base / name select gap in VRAM *words*. Read once from
-- emu.getState() ("ppu.oamBaseAddress", "ppu.oamAddressOffset") unless given.
function M.new(cfg)
  local self = setmetatable({}, Layer)
  self.tiles = cfg.tiles
  self.blocks = cfg.blocks or {}
  self.palette = cfg.palette or 0
  if not (cfg.base and cfg.offset) then
    local st = emu.getState()
    cfg.base = cfg.base or st["ppu.oamBaseAddress"]
    cfg.offset = cfg.offset or st["ppu.oamAddressOffset"]
  end
  self.base, self.offset = cfg.base, cfg.offset
  self.colors = {} -- OBJ palette -> { [index] = 0xRRGGBB }
  return self
end

function Layer:setColors(colors, pal) self.colors[pal or self.palette] = colors end

local function tileByteAddr(self, t)
  local word = self.base + ((t >= 256) and self.offset or 0) + (t & 255) * 16
  return (word * 2) & 0xFFFF
end

-- Save the current VRAM contents of every tile this layer may overwrite, so restore() can put the
-- game's graphics back. Tiles that look unused during play can still hold data the game loaded once
-- and needs later (SGnG's GAME OVER / continue screen came up garbled without this).
function Layer:snapshot()
  self.saved = {}
  local function save(t)
    local a = tileByteAddr(self, t)
    local b = {}
    for k = 0, 31 do b[k + 1] = emu.read((a + k) & 0xFFFF, VRAM, false) end
    self.saved[t] = b
  end
  for _, t in ipairs(self.tiles) do save(t) end
  for _, t in ipairs(self.blocks) do save(t); save(t + 1); save(t + 16); save(t + 17) end
end

function Layer:restore()
  for t, b in pairs(self.saved or {}) do
    local a = tileByteAddr(self, t)
    for k = 0, 31 do emu.write((a + k) & 0xFFFF, b[k + 1], VRAM) end
  end
  self.saved = nil
end

-- Snapshot OAM; returns the decoded entries (also kept in self.entries).
function Layer:begin()
  local es = {}
  local hiBytes = {}
  for i = 0, 31 do hiBytes[i] = emu.read(512 + i, OAM, false) end
  for i = 0, 127 do
    local x = emu.read(i * 4, OAM, false)
    local y = emu.read(i * 4 + 1, OAM, false)
    local t = emu.read(i * 4 + 2, OAM, false)
    local a = emu.read(i * 4 + 3, OAM, false)
    local hi = (hiBytes[i // 4] >> ((i % 4) * 2)) & 3
    x = x | ((hi & 1) << 8)
    if x >= 256 then x = x - 512 end
    es[i] = { i = i, x = x, y = y, tile = t | ((a & 1) << 8), pal = (a >> 1) & 7, prio = (a >> 4) & 3,
      hflip = (a >> 6) & 1 == 1, vflip = (a >> 7) & 1 == 1, large = (hi & 2) ~= 0,
      onscreen = not (y >= 224 and y < 240 + 16) }
  end
  self.entries = es
  self.free = {}
  self.queue = {}
  -- Our own entries from last frame are still there if the game skipped its OAM upload (lag/slowdown
  -- frames): reclaim every slot that still holds exactly what we wrote, or they pile up frame by frame.
  local mine = {}
  self.reclaimed = 0 -- > 0 means the game skipped its OAM upload this frame (a lag frame)
  for i, w in pairs(self.written or {}) do
    local same = true
    for k = 0, 3 do if emu.read(i * 4 + k, OAM, false) ~= w[k + 1] then same = false; break end end
    if same then
      mine[i] = true
      self.reclaimed = self.reclaimed + 1
      emu.write(i * 4 + 1, OFFSCREEN_Y, OAM)
      es[i].y, es[i].onscreen = OFFSCREEN_Y, false
    end
  end
  self.written = {}
  -- slots the game isn't using this frame (parked below the picture)
  for i = 0, 127 do
    local e = es[i]
    if e.y >= 224 and e.y <= 240 then self.free[#self.free + 1] = i end
  end
  return es
end

-- Park every game sprite matching pred(entry) offscreen and make its slot ours. Returns the count.
-- self.hiddenPrio = highest priority among them, so a replacement can sit at the same depth
-- (games change it per stage: SGnG draws Arthur at priority 2 in stage 1 but higher in stage 5).
function Layer:hide(pred)
  local n = 0
  self.hiddenPrio = nil
  local taken = {}
  for i = 0, 127 do
    local e = self.entries[i]
    if e.onscreen and pred(e) then
      emu.write(i * 4 + 1, OFFSCREEN_Y, OAM)
      e.hidden = true
      if not self.hiddenPrio or e.prio > self.hiddenPrio then self.hiddenPrio = e.prio end
      taken[#taken + 1] = i
      n = n + 1
    end
  end
  -- prefer the hidden slots (keeps the game's sprite-priority order for the replacement)
  for k = #taken, 1, -1 do table.insert(self.free, 1, taken[k]) end
  return n
end

-- First OBJ palette from prefs that no visible game sprite uses this frame (call after hide()).
-- Returns nil if all are taken.
function Layer:freePalette(prefs)
  local used = {}
  for i = 0, 127 do
    local e = self.entries[i]
    if e.onscreen and not e.hidden then used[e.pal] = true end
  end
  for _, p in ipairs(prefs) do if not used[p] and p ~= self.palette then return p end end
end

-- Queue one 8x8 sprite. tile = 32-byte 4bpp string; opts.hflip/vflip/prio (default prio 2).
function Layer:sprite(x, y, tile, opts)
  self.queue[#self.queue + 1] = { x = x, y = y, tile = tile, o = opts or {} }
end

-- Queue one 16x16 sprite. tile4 = 128-byte string: top-left, top-right, bottom-left, bottom-right.
function Layer:sprite16(x, y, tile4, opts)
  self.queue[#self.queue + 1] = { x = x, y = y, tile = tile4, big = true, o = opts or {} }
end

local function setHi(i, xHigh, large)
  local addr = 512 + i // 4
  local shift = (i % 4) * 2
  local v = emu.read(addr, OAM, false)
  v = (v & ~(3 << shift)) | (((xHigh and 1 or 0) | (large and 2 or 0)) << shift)
  emu.write(addr, v, OAM)
end

-- Write queued sprites. Identical tile data shares one VRAM tile. Returns how many were drawn.
function Layer:flush()
  for p, colors in pairs(self.colors) do
    for idx, rgb in pairs(colors) do
      local c = M.bgr555(rgb)
      local a = (128 + p * 16 + idx) * 2
      emu.write(a, c & 255, CGRAM)
      emu.write(a + 1, c >> 8, CGRAM)
    end
  end
  self.colors = {}
  local slotOf = {} -- tile string -> OBJ tile number (8x8) or block top-left (16x16)
  local nextTile, nextBlock, nextSlot, drawn = 1, 1, 1, 0
  local function upload(t, data, off)
    local a = tileByteAddr(self, t)
    for k = 1, 32 do emu.write((a + k - 1) & 0xFFFF, data:byte(off + k), VRAM) end
  end
  for _, s in ipairs(self.queue) do
    local t = slotOf[s.tile]
    if not t then
      if s.big then
        t = self.blocks[nextBlock]
        if t then
          nextBlock = nextBlock + 1
          upload(t, s.tile, 0); upload(t + 1, s.tile, 32); upload(t + 16, s.tile, 64); upload(t + 17, s.tile, 96)
        end
      else
        t = self.tiles[nextTile]
        if t then nextTile = nextTile + 1; upload(t, s.tile, 0) end
      end
      if t then slotOf[s.tile] = t end
    end
    local i = t and self.free[nextSlot]
    if i then
      nextSlot = nextSlot + 1
      local x, y, size = s.x, s.y, s.big and 16 or 8
      if x <= -size or x >= 256 or y <= -size or y >= 224 then
        emu.write(i * 4 + 1, OFFSCREEN_Y, OAM)
      else
        local attr = ((t >> 8) & 1) | ((s.o.pal or self.palette) << 1) | ((s.o.prio or 2) << 4) |
          (s.o.hflip and 0x40 or 0) | (s.o.vflip and 0x80 or 0)
        emu.write(i * 4, x & 255, OAM)
        emu.write(i * 4 + 1, y & 255, OAM)
        emu.write(i * 4 + 2, t & 255, OAM)
        emu.write(i * 4 + 3, attr, OAM)
        setHi(i, x < 0, s.big)
        self.written[i] = { x & 255, y & 255, t & 255, attr }
        drawn = drawn + 1
      end
    end
  end
  return drawn
end

return M
