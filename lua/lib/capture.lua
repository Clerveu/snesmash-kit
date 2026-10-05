-- Capture the whole picture state for offline tools (tools/snesgfx.py Capture): call from a startFrame
-- callback (endFrame is torn) once the screen is up. Writes <dir>/vram.bin, cgram.bin, oam.bin, ppu.txt
-- (every "ppu.*" key of emu.getState()) and screen.png.
--
--   local capture = dofile(KIT .. "lua/lib/capture.lua")
--   capture.save(KIT .. "art/<game>/<screen>/ref/")
local M = {}

local function mkdir(dir)
  if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
  else os.execute('mkdir -p "' .. dir .. '"') end
end

local function dump(path, memType)
  local t = {}
  for i = 0, emu.getMemorySize(memType) - 1 do t[#t + 1] = string.char(emu.read(i, memType, false)) end
  local f = assert(io.open(path, "wb")); f:write(table.concat(t)); f:close()
end

function M.save(dir)
  mkdir(dir)
  local st = emu.getState()
  local keys = {}
  for k, v in pairs(st) do if tostring(k):find("^ppu") then keys[#keys + 1] = k .. "=" .. tostring(v) end end
  table.sort(keys)
  local f = assert(io.open(dir .. "/ppu.txt", "w")); f:write(table.concat(keys, "\n")); f:close()
  dump(dir .. "/vram.bin", emu.memType.snesVideoRam)
  dump(dir .. "/cgram.bin", emu.memType.snesCgRam)
  dump(dir .. "/oam.bin", emu.memType.snesSpriteRam)
  local p = assert(io.open(dir .. "/screen.png", "wb")); p:write(emu.takeScreenshot()); p:close()
end

return M
