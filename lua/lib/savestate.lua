-- Savestate helpers for Mesen 2 Lua. createSavestate/loadSavestate only work inside a CPU exec
-- callback, so both functions arm a one-shot exec hook on the whole address space.
local M = {}
local function once(fn)
  local id
  id = emu.addMemoryCallback(function()
    if id then emu.removeMemoryCallback(id, emu.callbackType.exec, 0, 0xFFFFFF) end
    local f = fn; fn = nil; id = nil
    if f then f() end
  end, emu.callbackType.exec, 0, 0xFFFFFF)
end
function M.save(path, after)
  once(function()
    local f = io.open(path, "wb"); f:write(emu.createSavestate()); f:close()
    if after then after() end
  end)
end
function M.load(path, after)
  local f = io.open(path, "rb"); local s = f:read("a"); f:close()
  once(function() emu.loadSavestate(s); if after then after() end end)
end
return M
