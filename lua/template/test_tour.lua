-- TEMPLATE headless test: load a golden state, play a scripted input plan through the port, save
-- screenshots, stop. Copy to ports/<port>/test_tour.lua.
--
--   python tools/run_headless.py ports/<port>/test_tour.lua ROMS/<host> --set TOUR_STATE=states/<host>_stage1.mss
--   python tools/sheet.py out/tour "t*.png" out/tour_sheet.png 6     -> then look at the sheet
--
-- Variants set globals and dofile this: TOUR_PLAN (kit.plan list) or TOUR_INPUT_FN (e.g. seeded random
-- input for soak tests), TOUR_LEN, TOUR_SHOT_EVERY, TOUR_OUT, TOUR_CHECK (function(frame) called every
-- frame after the port's callbacks; error() in it to fail the run).
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local kit = dofile(HERE .. "../../lua/lib/kit.lua")
local ss = dofile(KIT .. "lua/lib/savestate.lua")

local OUT = TOUR_OUT or (KIT_OUT .. "tour/")
local LEN = TOUR_LEN or 600
local SHOT = TOUR_SHOT_EVERY or 30
kit.mkdir(OUT)

PORT_INPUT = TOUR_INPUT_FN or kit.plan(TOUR_PLAN or {
  { 30, 150, { right = true } },
  { 90, 94, { b = true } },
  { 150, 200, { left = true } },
  { 220, 260, { y = true } },
})

local function abs(p) return (p:match("^%a:") or p:match("^/")) and p or KIT .. p end
local frame = -1
local function start()
  dofile(HERE .. "main.lua") -- the port registers its callbacks now, on the loaded state
  emu.addEventCallback(kit.guard(function()
    if kit.stopped then return end
    frame = frame + 1
    if TOUR_CHECK then TOUR_CHECK(frame) end
    if SHOT > 0 and frame % SHOT == 0 then kit.screenshot(OUT .. string.format("t%05d.png", frame)) end
    if frame >= LEN then kit.finish(0) end
  end), emu.eventType.endFrame)
end

if TOUR_STATE then ss.load(abs(TOUR_STATE), kit.guard(start)) else start() end
