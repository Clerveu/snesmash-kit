-- kit.lua: shared bootstrap for every entry script (ports, recon, tests). Mesen 2, Lua 5.4.
--
-- Mesen's dofile needs absolute paths and scripts get no arguments, so every entry script starts with:
--
--   local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")   -- this script's folder
--   local kit = dofile(HERE .. "../../lua/lib/kit.lua")              -- adjust the ../ count
--
-- and loads everything else as dofile(KIT .. "lua/lib/<module>.lua"). Loading this file sets:
--   KIT         repo root, forward slashes, trailing "/"
--   KIT_OUT     scratch output folder (KIT .. "out/", git-ignored)
--   KIT_ERRLOG  file every guarded callback logs its errors to (KIT_OUT .. "errors.txt")
-- Parameters come in as globals set by a wrapper (tools/run_headless.py --set NAME=value), so read
-- them with a default: local LEN = TRACE_LEN or 600.
local M = {}

-- "C:/a/ports/x/../../lua/lib" -> "C:/a/lua/lib"
function M.normalize(path)
  path = path:gsub("\\", "/")
  local n
  repeat path, n = path:gsub("/[^/]+/%.%./", "/", 1) until n == 0
  return path
end

local src = M.normalize(debug.getinfo(1, "S").source:gsub("^@", ""))
KIT =src:match("^(.*/)lua/lib/kit%.lua$") or error("kit.lua must live at <root>/lua/lib/kit.lua")
KIT_OUT = KIT_OUT or (KIT .. "out/")
KIT_ERRLOG = KIT_ERRLOG or (KIT_OUT .. "errors.txt")
M.root, M.out = KIT, KIT_OUT

function M.mkdir(dir)
  if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
  else os.execute('mkdir -p "' .. dir .. '"') end
end
M.mkdir(KIT_OUT)

-- ------------------------------------------------------------------ errors
-- Mesen swallows errors inside callbacks (headless shows nothing; a failing callback simply stops
-- partway every frame). guard() wraps a callback: the first occurrence of each error goes to
-- KIT_ERRLOG with a traceback, and to the screen. Wrap EVERY callback; check the file after every run.
local seen = {}
function M.logError(err)
  err = tostring(err)
  if seen[err] then return end
  seen[err] = true
  local f = io.open(KIT_ERRLOG, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. err .. "\n"); f:close() end
  emu.displayMessage("Lua error", err:sub(1, 120))
end

function M.guard(fn)
  return function(...)
    local ok, res = xpcall(fn, debug.traceback, ...)
    if ok then return res end
    M.logError(res)
  end
end

-- ------------------------------------------------------------------ input
-- emu.setInput only overrides the buttons you name; any button left out stays under the real pad's
-- control. So always send every button, explicitly true or false.
M.BUTTONS = { "a", "b", "x", "y", "l", "r", "up", "down", "left", "right", "start", "select" }

function M.pad(pressed)
  local t = {}
  for _, b in ipairs(M.BUTTONS) do t[b] = (pressed and pressed[b]) and true or false end
  return t
end

function M.setPad(pressed, port) emu.setInput(M.pad(pressed), port or 0) end

-- A scripted input plan: list of { fromFrame, toFrame (exclusive), { b = true, right = true } }.
-- Returns function(frame) -> pressed-buttons table. Later entries win where windows overlap.
function M.plan(list)
  return function(frame)
    local p = {}
    for _, e in ipairs(list or {}) do
      if frame >= e[1] and frame < e[2] then for k, v in pairs(e[3]) do p[k] = v end end
    end
    return p
  end
end

-- ------------------------------------------------------------------ memory + files
function M.memSize(memType)
  local ok, n = pcall(emu.getMemorySize, memType)
  return ok and n or 0
end

-- Which console is loaded ("snes", "nes", ...), from which memory types have a size.
function M.system()
  local mt = emu.memType
  if mt.snesWorkRam and M.memSize(mt.snesWorkRam) > 0 then return "snes" end
  if mt.nesInternalRam and M.memSize(mt.nesInternalRam) > 0 then return "nes" end
  if mt.gbWorkRam and M.memSize(mt.gbWorkRam) > 0 then return "gb" end
  if mt.pceWorkRam and M.memSize(mt.pceWorkRam) > 0 then return "pce" end
  if mt.smsWorkRam and M.memSize(mt.smsWorkRam) > 0 then return "sms" end
  return "unknown"
end

-- The console's main work RAM memType (what per-frame RAM traces dump).
function M.workRam()
  local s, mt = M.system(), emu.memType
  return ({ snes = mt.snesWorkRam, nes = mt.nesInternalRam, gb = mt.gbWorkRam, pce = mt.pceWorkRam,
    sms = mt.smsWorkRam })[s]
end

-- Whole memory (or n bytes from start) as a string.
function M.readMem(memType, start, n)
  start = start or 0
  n = n or (M.memSize(memType) - start)
  local t = {}
  for i = start, start + n - 1 do t[#t + 1] = string.char(emu.read(i, memType, false)) end
  return table.concat(t)
end

function M.writeFile(path, data, mode)
  local f = assert(io.open(path, mode or "wb"))
  f:write(data); f:close()
end

function M.screenshot(path) M.writeFile(path, emu.takeScreenshot()) end

-- Every "ppu.*" key of emu.getState() as sorted "key=value" lines (what tools/snesgfx.py reads).
function M.ppuText()
  local keys = {}
  for k, v in pairs(emu.getState()) do
    if tostring(k):find("^ppu") then keys[#keys + 1] = k .. "=" .. tostring(v) end
  end
  table.sort(keys)
  return table.concat(keys, "\n")
end

-- Stop the emulator (headless runs end here). Close your own files first. Callbacks can still fire
-- for a moment after emu.stop, so check kit.stopped before touching anything you closed.
M.stopped = false
function M.finish(code)
  M.stopped = true
  emu.stop(code or 0)
end

return M
