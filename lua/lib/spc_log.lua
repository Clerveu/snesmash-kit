-- SPC/DSP logger (recon, any SNES game).
-- The sound CPU (SPC700) talks to the S-DSP through two registers: $F2 = DSP register index, $F3 = data.
-- Hooking SPC writes to both gives every DSP register write the sound driver makes, in order. Main-CPU
-- writes to the APU ports $2140-$2143 are logged too (that's how the game asks for sounds), so a sound
-- request can be lined up with the key-on (KON, DSP $4C) that follows it.
--
-- Log lines (text, one per event):
--   D <frame> <spc cycle> <reg hex> <value hex>     DSP register write
--   P <frame> <port hex> <value hex>                main CPU -> APU port write
--   M <frame> <text>                                marker from the capture script
--   S <frame> <spc cycle> <256 hex digits>          snapshot of all 128 DSP registers (at start)
-- Use: local L = dofile(KIT .. "lua/lib/spc_log.lua"); L.start(path); ... L.mark("text"); L.stop()
-- L.dumpAram(path) writes the 64 KB of sound RAM; L.dumpDsp(path) the 128 DSP registers.
local M = {}
local SPC = emu.memType.spcMemory
local log, frame, dspAddr = nil, 0, 0

local function cycle()
  -- emu.getState() is a big table, but captures are short; the cycle gives sub-frame timing.
  return emu.getState()["spc.cycle"] or 0
end

function M.start(path, opts)
  opts = opts or {}
  log = io.open(path, "w")
  frame = 0
  local regs = {}
  for a = 0, 0x7F do regs[#regs + 1] = string.format("%02x", emu.read(a, emu.memType.spcDspRegisters, false)) end
  log:write(string.format("S 0 %d %s\n", cycle(), table.concat(regs)))
  emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.startFrame)
  -- $F2 = address latch; $F3 = data (to the latched DSP register). MOVW $F2,YA writes both in one go.
  emu.addMemoryCallback(function(addr, value)
    if addr == 0xF2 then
      dspAddr = value
    else
      log:write(string.format("D %d %d %02x %02x\n", frame, opts.noCycle and 0 or cycle(), dspAddr & 0x7F, value))
    end
  end, emu.callbackType.write, 0xF2, 0xF3, emu.cpuType.spc, SPC)
  emu.addMemoryCallback(function(addr, value)
    log:write(string.format("P %d %x %02x\n", frame, addr - 0x2140, value))
  end, emu.callbackType.write, 0x2140, 0x2143, emu.cpuType.snes, emu.memType.snesMemory)
end

function M.mark(text) if log then log:write(string.format("M %d %s\n", frame, text)) end end
function M.frame() return frame end

function M.stop()
  if log then log:close(); log = nil end
end

function M.dumpAram(path)
  local f = io.open(path, "wb")
  local t = {}
  for a = 0, 0xFFFF do t[#t + 1] = string.char(emu.read(a, emu.memType.spcRam, false)) end
  f:write(table.concat(t)); f:close()
end

function M.dumpDsp(path)
  local f = io.open(path, "wb")
  local t = {}
  for a = 0, 0x7F do t[#t + 1] = string.char(emu.read(a, emu.memType.spcDspRegisters, false)) end
  f:write(table.concat(t)); f:close()
end

return M
