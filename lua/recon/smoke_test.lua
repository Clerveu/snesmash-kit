-- Setup check: run on any ROM to prove the toolchain works before real work starts.
--
--   python tools/run_headless.py lua/recon/smoke_test.lua "ROMS/<any game>"
--
-- Checks: the kit root resolves, out/ is writable, the console is detected, guarded callbacks log
-- errors to KIT_ERRLOG, savestates save and load (lua/lib/savestate.lua), screenshots work, and (SNES)
-- a PPU capture is written that tools/snes_oam.py and tools/snesgfx.py can read. Writes
-- out/smoke/report.txt, which also lists this Mesen build's memTypes, cpuTypes and getState() keys
-- (names differ between consoles and Mesen versions: trust this list over memory).
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local kit = dofile(HERE .. "../lib/kit.lua")
local ss = dofile(KIT .. "lua/lib/savestate.lua")
local capture = dofile(KIT .. "lua/lib/capture.lua")

local OUT = KIT_OUT .. "smoke/"
kit.mkdir(OUT)
local lines = {}
local function say(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
local function names(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = tostring(k) end
  table.sort(ks)
  return table.concat(ks, " ")
end

say("KIT = %s", KIT)
say("KIT_ERRLOG = %s", KIT_ERRLOG)
local sys = kit.system()
say("system = %s, work RAM = %d bytes", sys, kit.memSize(kit.workRam()))
say("emu.memType: %s", names(emu.memType))
say("emu.cpuType: %s", names(emu.cpuType))
say("emu.eventType: %s", names(emu.eventType))

-- guarded callbacks must log instead of dying silently
local realLog = KIT_ERRLOG
KIT_ERRLOG = OUT .. "guard_check.txt" -- keep the expected error out of the real log
os.remove(KIT_ERRLOG)
local marker = "smoke test: this error is expected " .. os.time()
kit.guard(function() error(marker) end)()
local f = io.open(KIT_ERRLOG, "r")
KIT_ERRLOG = realLog
local logged = f and f:read("a"):find(marker, 1, true) ~= nil
if f then f:close() end
say("guard -> errors log: %s", logged and "OK" or "FAILED (check write access to out/)")

local frame, saved, loaded, done = 0, false, false, false
local statePath = OUT .. "smoke.mss"

emu.addEventCallback(kit.guard(function()
  -- press Start now and then so most games leave their intro
  kit.setPad({ start = frame % 120 >= 100 and frame % 120 < 104 }, 0)
end), emu.eventType.inputPolled)

emu.addEventCallback(kit.guard(function()
  frame = frame + 1
  if frame == 60 then
    ss.save(statePath, function()
      local g = io.open(statePath, "rb")
      local n = g and #g:read("a") or 0
      if g then g:close() end
      saved = n > 0
      say("savestate save: %s (%d bytes)", saved and "OK" or "FAILED", n)
      if saved then ss.load(statePath, function() loaded = true; say("savestate load: OK") end) end
    end)
  end
  if frame == 240 and not done then
    done = true
    if not loaded then say("savestate load: FAILED (callback never ran)") end
    kit.screenshot(OUT .. "screen.png")
    say("screenshot: out/smoke/screen.png")
    local st = emu.getState()
    local prefixes, cpu = {}, {}
    for k in pairs(st) do
      local p = tostring(k):match("^([%w_]+)%.") or tostring(k)
      prefixes[p] = (prefixes[p] or 0) + 1
      if tostring(k):find("^cpu%.") then cpu[#cpu + 1] = tostring(k) end
    end
    table.sort(cpu)
    local pl = {}
    for p, n in pairs(prefixes) do pl[#pl + 1] = p .. "(" .. n .. ")" end
    table.sort(pl)
    say("getState() key groups: %s", table.concat(pl, " "))
    say("getState() cpu keys: %s", table.concat(cpu, " "))
    if sys == "snes" then
      capture.save(OUT .. "capture")
      say("PPU capture: out/smoke/capture (BG mode %s)", tostring(st["ppu.bgMode"]))
      say("  python tools/snes_oam.py needs: --base 0x%X --offset 0x%X --mode %s",
        st["ppu.oamBaseAddress"] or 0, st["ppu.oamAddressOffset"] or 0, tostring(st["ppu.oamMode"]))
    end
    say("DONE")
    kit.writeFile(OUT .. "report.txt", table.concat(lines, "\n") .. "\n", "w")
    kit.finish(0)
  end
end), emu.eventType.startFrame)
