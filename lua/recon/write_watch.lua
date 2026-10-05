-- Recon: who writes (or reads) these addresses? Logs each distinct writer once: frame, address, value,
-- and the CPU state at the write: PC (bank:addr), D (direct page) and DB (data bank).
--
-- On SNES, D is usually the base address of the object whose code is running, so it says *whose*
-- code did the write. Then read that code with tools/dis65816.py. Uses: finding the allocator (watch
-- a projectile slot during a native shot), every writer of a "gameplay" flag before trusting it, and
-- the culprit behind RAM corruption.
--
--   python tools/run_headless.py lua/recon/write_watch.lua ROMS/game.sfc --set WATCH_STATE=states/game_play.mss \
--     --set 'WATCH={{0x032E, "flag"}, {0x0450, "speed", 2}}' --set WATCH_LEN=600 --set 'WATCH_PLAN={{10,200,{right=true}}}'
--
-- Globals: WATCH = list of { address, name, [length = 1] }; WATCH_MEM (memType, default work RAM);
-- WATCH_KIND = "write" (default) or "read"; WATCH_ALL = true logs every access instead of each new PC once;
-- WATCH_STATE, WATCH_PLAN / WATCH_INPUT_FN, WATCH_LEN (600), WATCH_OUT (out/watch.txt).
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local kit = dofile(HERE .. "../lib/kit.lua")
local ss = dofile(KIT .. "lua/lib/savestate.lua")

local LEN = WATCH_LEN or 600
local MEM = WATCH_MEM or kit.workRam()
local KIND = (WATCH_KIND == "read") and emu.callbackType.read or emu.callbackType.write
local input = WATCH_INPUT_FN or kit.plan(WATCH_PLAN)
local log = assert(io.open(WATCH_OUT or (KIT_OUT .. "watch.txt"), "w"))
local sys = kit.system()
local cpu = ({ snes = emu.cpuType.snes, nes = emu.cpuType.nes, gb = emu.cpuType.gameboy,
  pce = emu.cpuType.pce, sms = emu.cpuType.sms })[sys]

local function abs(p) return (p:match("^%a:") or p:match("^/")) and p or KIT .. p end
local ready = not WATCH_STATE
if WATCH_STATE then ss.load(abs(WATCH_STATE), function() ready = true end) end

local frame, seen = -1, {}

for _, w in ipairs(WATCH or error("set WATCH = {{address, name}, ...}")) do
  local a, name, n = w[1], w[2] or string.format("%04X", w[1]), w[3] or 1
  emu.addMemoryCallback(kit.guard(function(addr, value)
    if not ready or kit.stopped then return end
    local s = emu.getState()
    local pc, k = s["cpu.pc"] or 0, s["cpu.k"] or 0
    local key = name .. ":" .. k .. ":" .. pc
    if seen[key] and not WATCH_ALL then return end
    seen[key] = true
    log:write(string.format("f%d %s $%04X=%02X pc=%02X:%04X d=%04X db=%02X\n", frame, name, addr, value,
      k, pc, s["cpu.d"] or 0, s["cpu.dbr"] or 0))
    log:flush()
  end), KIND, a, a + n - 1, cpu, MEM)
end

emu.addEventCallback(kit.guard(function()
  if frame >= 0 then kit.setPad(input(frame), 0) end
end), emu.eventType.inputPolled)

emu.addEventCallback(kit.guard(function()
  if not ready or kit.stopped then return end
  frame = frame + 1
  if frame >= LEN then log:close(); kit.finish(0) end
end), emu.eventType.startFrame)
