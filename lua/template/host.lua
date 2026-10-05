-- TEMPLATE host adapter. Copy to ports/<port>/host.lua and fill in from recon (docs/PLAYBOOK.md 6).
--
-- The host adapter owns EVERY host RAM address and routine the port touches; controllers, guns and
-- drawing code stay memory-free and ask this module. Next to each address, write how it was found
-- (trace + ramsearch, write-watch PC/D, disassembly, cheat code) and in which stages it was verified,
-- and copy the facts into docs/games/<host>.md.
--
-- Until inGameplay() is real, the port does nothing (safe default: write nothing outside gameplay).
local M = {}
local W = emu.memType.snesWorkRam -- NES: emu.memType.nesInternalRam

local function rd(a) return emu.read(a, W, false) end
local function rd16(a) return emu.read(a, W, false) | (emu.read(a + 1, W, false) << 8) end
local function wr(a, v) emu.write(a, v & 0xFF, W) end
local function wr16(a, v) emu.write(a, v & 0xFF, W); emu.write(a + 1, (v >> 8) & 0xFF, W) end
M.rd, M.rd16, M.wr, M.wr16 = rd, rd16, wr, wr16

-- ---------------------------------------------------------------- modes
-- True only while the player is in normal play, in EVERY stage. Find it by tracing boot -> play ->
-- death -> map -> reload and every stage; then write-watch it to learn all its writers (a flag can
-- double as something else and flicker mid-stage). Combine with "player object active".
function M.inGameplay()
  return false -- TODO
end

-- Player has control (not in a stage intro / READY / cutscene). Usually: the player's routine pointer.
-- Don't allocate host objects before this is true (host scripts can wait on slots you'd take).
function M.playerInControl()
  return false -- TODO
end

-- ---------------------------------------------------------------- player + camera
M.PLAYER = 0x0000 -- TODO: player object base (slot stride and field offsets: see the object table)

function M.playerPos()
  return 0, 0 -- TODO: world x, y (pixels) of the anchor point the guest is drawn from (e.g. feet)
end

function M.camera()
  return 0, 0 -- TODO: camera x, y. Verify: playerPos - camera == the player's real OAM position, every stage
end

function M.playerState()
  return 0 -- TODO: the host's state enum (log only when it changes, with input, to map it)
end

-- Is this OAM entry (lua/lib/snes_obj.lua entry) one of the host player's own sprites? Used to hide
-- them and to know the host drew the player this frame (blinking/cutscenes/death inherited for free).
function M.isPlayerSprite(e)
  return false -- TODO: usually by OBJ palette and/or tile range (tools/snes_oam.py --list --box)
end

-- ---------------------------------------------------------------- physics steering
-- Steer the host's own velocity fields (never positions) so its collision keeps working.
function M.setSpeedX(pxPerFrame) end -- TODO
function M.setVelocityY(pxPerFrame) end -- TODO (e.g. on the takeoff frame only)
function M.setGravity(pxPerFrame2) end -- TODO

-- Fields the host rewrites every frame: override the write itself. A write callback that returns a
-- value replaces the value being written. Install once; it only acts while M.speedOverride is set.
M.speedOverride = nil
function M.installSpeedOverride()
  -- TODO: emu.addMemoryCallback(function(addr, value)
  --   if not M.speedOverride then return nil end      -- nil = leave the host's write alone
  --   return <byte of the override for addr>
  -- end, emu.callbackType.write, SPEED_LO, SPEED_HI, emu.cpuType.snes, W)
end

-- ---------------------------------------------------------------- objects (guest attacks)
-- Allocate ONLY through the host's own allocator, mirroring its exact widths (8-bit vs 16-bit index).
-- Find it by write-watching a projectile slot during a native shot (lua/recon/write_watch.lua), then
-- disassembling the spawn and free code (tools/dis65816.py).
function M.alloc(kind)
  return nil -- TODO: pop a slot like the host does; nil when full (never steal)
end

-- Retire an object the way the host would (e.g. move it just short of its own despawn line moving
-- outward, so the host's code frees it). Never zero objects yourself.
function M.retire(slot) end -- TODO

return M
