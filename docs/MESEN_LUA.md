# Mesen 2 Lua: facts that matter for this work

Checked against Mesen 2.1.1 (Lua 5.4). Names differ between consoles and versions:
`lua/recon/smoke_test.lua` writes this build's real `emu.memType` / `emu.cpuType` / `emu.eventType`
lists and `getState()` keys to `out/smoke/report.txt`. Trust that file over memory, and the official
API reference (Mesen's Script window > Help, or the docs on mesen.ca) over both.

## Events and timing
- `emu.addEventCallback(fn, emu.eventType.X)`: `startFrame`, `endFrame`, `inputPolled`, `nmi`, `irq`,
  `reset`, `stateLoaded`, `stateSaved`, `codeBreak`, `scriptEnded`.
- **`startFrame`**: the game's vblank work (DMA to VRAM/OAM/CGRAM) is done, and the PPU is about to
  draw. Read PPU memory here, and write sprites/tiles/colours here so they show this frame.
  **Never read PPU memory at `endFrame`**: games stream tiles in vblank, so it's torn.
- **`inputPolled`**: after the game read the pad. Steer game logic here (between the previous frame's
  logic and this one's). Games may poll more than once a frame and skip polling on lag frames: guard
  "once per frame" with your own frame counter, and count frames at `startFrame`.
- Callbacks keep firing for a moment after `emu.stop()`. Don't touch files you've closed
  (`kit.stopped`).
- `ScriptTimeout` is per callback (default 1 s). Heavy setup (building tile sets) is fine at load.

## Memory
- `emu.read(addr, memType, signed)`, `emu.write(addr, value, memType)`, plus `read16/write16/readWord`.
  `addr` is an offset inside that memType (SNES `snesWorkRam` 0-0x1FFFF = $7E0000-$7FFFFF).
- SNES memTypes: `snesWorkRam`, `snesVideoRam`, `snesSpriteRam` (OAM, 544 bytes), `snesCgRam`,
  `snesMemory` (CPU bus: registers like `$2140`), `snesPrgRom`. Sound: `spcRam` (64 KB, writable),
  `spcDspRegisters` (128, writable; a KON write keys a voice on), `spcMemory` (hook with
  `emu.cpuType.spc`).
- NES: `nesInternalRam` (2 KB), `nesSpriteRam`, `nesPaletteRam` (sprite palettes at 16-31),
  `nesPpuMemory`, `nesChrRom`, `nesPrgRom`. Other consoles: `gb*`, `gba*`, `pce*`, `sms*`, `ws*`.
- PPU memories are writable from Lua.
- `emu.getMemorySize(memType)` errors for some memTypes on some consoles: wrap probes in `pcall`.

## Memory callbacks
- `emu.addMemoryCallback(fn, emu.callbackType.write|read|exec, startAddr, endAddr, cpuType, memType)`;
  `fn(address, value)`. Remove with `emu.removeMemoryCallback(id, type, start, end[, cpuType, memType])`.
- **A write callback's return value replaces the value being written** (`return nil` = unchanged).
  This is how to override a field the game rewrites every frame, and how to swallow a sound driver's
  DSP writes.
- They fire for CPU writes to WRAM. They did not fire for DMA into VRAM.
- In a write callback, `emu.getState()["cpu.pc"]` was the address *after* the writing instruction in
  every case checked; `cpu.k` = program bank, `cpu.d` = direct page (on SNES usually the current
  object's base), `cpu.dbr` = data bank.
- SPC side: hook `$F2`/`$F3` writes on `spcMemory` with `emu.cpuType.spc` to see every DSP register
  write; `$2140-$2143` writes on `snesMemory` are the main CPU's sound requests.
- Callbacks are cheap (hundreds of thousands per run); `emu.getState()` is not (~0.26 ms, a big table):
  avoid it in hot callbacks and per-frame code where you can.

## State
- `emu.getState()` returns a flat table with dotted keys: `cpu.pc`, `cpu.k`, `cpu.d`, `cpu.dbr`, `cpu.a`,
  `ppu.bgMode`, `ppu.forcedBlank`, `ppu.oamBaseAddress` / `ppu.oamAddressOffset` (OBSEL, in VRAM
  words), `ppu.oamMode`, `ppu.layers[0].hscroll`, `ppu.layers[0].chrAddress`, `ppu.mainScreenLayers`,
  `spc.cycle`, `spc.timer0.target`, `spc.dsp.*`, `frameCount`.
- `spc.cycle` counts at 2.048 MHz (34,036 per frame; one 32 kHz DSP sample = 64 counts).

## Savestates
- `emu.createSavestate()` returns a string; `emu.loadSavestate(s)` loads one. **Both only work inside a
  CPU exec callback**: `lua/lib/savestate.lua` arms a one-shot exec hook for you.
- After a load, `stateLoaded` fires; anything your script believed about RAM may now be wrong (forget,
  don't restore).

## Input
- `emu.getInput(port)` reads the pad; `emu.setInput(table, port)` overrides it for this frame.
- **`setInput` only overrides the buttons you name.** Unnamed buttons stay under the real pad's
  control. Always pass every button true/false (`kit.setPad`). Names: `a b x y l r up down left right
  start select`. `setInput` worked on NES with SNES port settings.

## Drawing and output
- `emu.takeScreenshot()` returns PNG bytes. `emu.displayMessage(title, text)` shows an on-screen note.
- `emu.drawRectangle/drawString/drawPixel` draw on a HUD surface that sits 8 lines above the SNES
  picture; colours are ARGB with inverted alpha. Prefer real PPU sprites (`lua/lib/snes_obj.lua`).
- OAM Y is one line above the first displayed row.

## Running scripts
- **Live**: Mesen > Debug > Script Window, open the script. Script settings must allow "access to I/O
  and OS functions" (needed for `dofile`, `io.open`), plus network access for UDP. A controller must be
  on port 1.
- **Headless**: `Mesen --testRunner --timeout=<s> <script.lua> <rom>`; the script ends the run with
  `emu.stop(code)` (the process exit code). Use `tools/run_headless.py`, which also passes parameters as
  globals and reports Lua errors. Mesen's stdout floods with uninitialised-read warnings: discard it.
- **Mesen swallows Lua errors** in callbacks, and a syntax error in a `dofile`d module silently leaves
  the script dead. Wrap every callback in `kit.guard`, check `out/errors.txt` after every run.
- `dofile` needs absolute paths. A script finds its own folder with
  `debug.getinfo(1, "S").source:match("^@(.*[/\\])")`. On Windows use `C:/...` paths; an MSYS-style
  `/c/...` path fails silently.
- `os.getenv`, `io.*`, `os.execute` work when I/O access is allowed. There's no `arg` table.
- Lua 5.4: integer division `//`, bitwise operators `& | ~ << >>`. Bitwise operators on non-integer
  floats throw: floor first.
- LuaSocket is available for UDP (`local socket = require("socket.core"); local udp = socket.udp()`, with
  network access allowed); `udp:receive()` defaults to 8 KB, pass 65507.
