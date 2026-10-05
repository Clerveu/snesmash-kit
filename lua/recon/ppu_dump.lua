-- Recon (SNES): dump OAM / VRAM / CGRAM / WRAM / PPU registers / screenshot at chosen frames, for
-- tools/snes_oam.py (who owns which sprite slots, tiles and palettes) and tools/snesgfx.py.
--
-- Dumps happen at startFrame: the game's vblank DMA has run, so this is exactly what the PPU draws
-- this frame. (At endFrame the next frame's uploads may be half done: torn.)
--
--   python tools/run_headless.py lua/recon/ppu_dump.lua ROMS/game.sfc --set PPU_STATE=states/game_play.mss \
--     --set 'PPU_FRAMES={10,70}' --set 'PPU_PLAN={{60,100,{right=true}}}'
--   python tools/snes_oam.py out/ppu 70 --list --base <ppu.oamBaseAddress> --offset <ppu.oamAddressOffset> --mode <ppu.oamMode>
--     (those three values are in out/ppu/ppu70.txt)
--
-- Files per dumped frame N: oamN.bin vramN.bin cgN.bin wramN.bin ppuN.txt scrN.png. The screenshot is
-- the last finished frame (one frame older than the memory), which matters only while things move.
-- Globals: PPU_STATE, PPU_FRAMES (list, default {1}), PPU_PLAN / PPU_INPUT_FN, PPU_OUT (out/ppu/).
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local kit = dofile(HERE .. "../lib/kit.lua")
local ss = dofile(KIT .. "lua/lib/savestate.lua")

local OUT = PPU_OUT or (KIT_OUT .. "ppu/")
local FRAMES = PPU_FRAMES or { 1 }
local input = PPU_INPUT_FN or kit.plan(PPU_PLAN)
kit.mkdir(OUT)
local want, last = {}, 0
for _, f in ipairs(FRAMES) do want[f] = true; if f > last then last = f end end

local function abs(p) return (p:match("^%a:") or p:match("^/")) and p or KIT .. p end
local ready = not PPU_STATE
if PPU_STATE then ss.load(abs(PPU_STATE), function() ready = true end) end

local frame = -1
local mt = emu.memType

emu.addEventCallback(kit.guard(function()
  if frame >= 0 then kit.setPad(input(frame), 0) end
end), emu.eventType.inputPolled)

emu.addEventCallback(kit.guard(function()
  if not ready or kit.stopped then return end
  frame = frame + 1
  if want[frame] then
    local tag = tostring(frame)
    kit.writeFile(OUT .. "ppu" .. tag .. ".txt", kit.ppuText(), "w")
    kit.writeFile(OUT .. "oam" .. tag .. ".bin", kit.readMem(mt.snesSpriteRam))
    kit.writeFile(OUT .. "cg" .. tag .. ".bin", kit.readMem(mt.snesCgRam))
    kit.writeFile(OUT .. "vram" .. tag .. ".bin", kit.readMem(mt.snesVideoRam))
    kit.writeFile(OUT .. "wram" .. tag .. ".bin", kit.readMem(mt.snesWorkRam))
    kit.screenshot(OUT .. "scr" .. tag .. ".png")
  end
  if frame >= last then kit.finish(0) end
end), emu.eventType.startFrame)
