-- Recon: per-frame RAM trace under a scripted input plan, for tools/ramsearch.py.
--
-- Optionally loads a golden savestate, then plays TRACE_PLAN on pad 1 and appends a full snapshot of
-- the console's work RAM to trace.bin every frame (one snapshot = one frame; SNES WRAM is 128 KB, so
-- the default is the first 64 KB bank, where most games keep their objects). Also writes inputs.txt
-- (frame + buttons) and a screenshot every TRACE_SHOT_EVERY frames, so the trace can be read against
-- what was on screen.
--
--   python tools/run_headless.py lua/recon/ram_trace.lua ROMS/game.sfc --set TRACE_STATE=states/game_play.mss \
--     --set 'TRACE_PLAN={{60,160,{right=true}},{200,204,{b=true}}}' --set TRACE_LEN=300
--   python tools/ramsearch.py out/trace/trace.bin --size 0x10000 --rise 60:160 --const 0:60 --word
--
-- Globals (all optional): TRACE_STATE (savestate path, relative to the repo or absolute), TRACE_PLAN
-- (kit.plan list), TRACE_INPUT_FN (function(frame) -> buttons; wins over TRACE_PLAN), TRACE_LEN (600),
-- TRACE_OUT (out/trace/), TRACE_SIZE (bytes per snapshot, 0x10000), TRACE_START (first address, 0),
-- TRACE_MEM (memType; default: the console's work RAM), TRACE_SHOT_EVERY (20; 0 = none).
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local kit = dofile(HERE .. "../lib/kit.lua")
local ss = dofile(KIT .. "lua/lib/savestate.lua")

local OUT = TRACE_OUT or (KIT_OUT .. "trace/")
local LEN = TRACE_LEN or 600
local MEM = TRACE_MEM or kit.workRam()
local START = TRACE_START or 0
local SIZE = math.min(TRACE_SIZE or 0x10000, kit.memSize(MEM) - START)
local SHOT = TRACE_SHOT_EVERY or 20
local input = TRACE_INPUT_FN or kit.plan(TRACE_PLAN)
kit.mkdir(OUT)

local function abs(p) return (p:match("^%a:") or p:match("^/")) and p or KIT .. p end

local ready = not TRACE_STATE
if TRACE_STATE then ss.load(abs(TRACE_STATE), function() ready = true end) end

local trace = assert(io.open(OUT .. "trace.bin", "wb"))
local inputs = assert(io.open(OUT .. "inputs.txt", "w"))
local frame, logged = -1, -1

-- Count frames at startFrame, not inputPolled: games skip input polling on lag frames.
emu.addEventCallback(function() if ready then frame = frame + 1 end end, emu.eventType.startFrame)

emu.addEventCallback(kit.guard(function()
  if frame < 0 or kit.stopped then return end
  local p = input(frame)
  kit.setPad(p, 0)
  if logged == frame then return end -- some games poll more than once per frame
  logged = frame
  local held = {}
  for _, b in ipairs(kit.BUTTONS) do if p[b] then held[#held + 1] = b end end
  inputs:write(string.format("%d %s\n", frame, table.concat(held, ",")))
end), emu.eventType.inputPolled)

emu.addEventCallback(kit.guard(function()
  if not ready or frame < 0 or kit.stopped then return end
  trace:write(kit.readMem(MEM, START, SIZE))
  if SHOT > 0 and frame % SHOT == 0 then kit.screenshot(OUT .. string.format("t%04d.png", frame)) end
  if frame >= LEN - 1 then
    trace:close(); inputs:close()
    kit.writeFile(OUT .. "info.txt", string.format("frames=%d size=0x%X start=0x%X\n", LEN, SIZE, START), "w")
    kit.finish(0)
  end
end), emu.eventType.endFrame)
