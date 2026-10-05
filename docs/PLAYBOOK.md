# Playbook: putting a character from one retro game into another

General, game-independent lessons from SNESMASH, written down as they were paid for. Specific
addresses appear only as worked examples (the real notes are in `docs/games/`). **Add to this file
whenever something you learn generalises**, and keep game facts in `docs/games/<game>.md`.

Ports these lessons come from:
- Ryu (Super Street Fighter II) in Super Mario World: live drive over UDP, proof of concept.
- Bill Rizer (Super C, NES) in Super Ghouls 'n Ghosts: capture + reimplement.
- Jimbo (Contra III) in Super Ghouls 'n Ghosts: capture + reimplement, bit-exact homing missiles,
  Contra III's own sound effects played on SGnG's sound hardware, a title-card edit of SGnG's logo.

## 0. The playbook, short version
1. Pick the architecture (section 1).
2. **Source game**: look for a public disassembly first (section 2). Extract sprites from ROM tables or
   PPU captures, measure physics/weapons, write an asset package (`assets/<game>/`) and a game doc.
3. **Host game**: make a golden savestate at "player in control" (section 6), then find the player
   object, the object pool and its allocator, the camera, the player state enum and a reliable
   *in-gameplay* flag.
4. Steer the host's own physics with the guest's numbers (section 3).
5. Draw the guest through the PPU in the host character's sprite resources (section 4).
6. Guest attacks ride on native host objects, allocated through the host's own allocator (section 5).
7. Sound: the source game's own effects as DSP clips on a borrowed host voice (section 5b).
8. Headless tests throughout: a scripted tour, per-feature tests, a cold boot, seeded random soak
   runs (section 7).

Nothing here patches a ROM. Everything is a Lua script steering the running host game, so the user
needs only their own ROM dumps and Mesen.

## 1. Pick an architecture per character

| | Live drive (two emulators) | Capture + reimplement (one emulator) |
|---|---|---|
| How | The source game runs the character; pixels/state stream over UDP to the host's window | The source game is used offline: sprites extracted to an asset file, physics/weapons measured into constants; at runtime only the host runs |
| Good for | Big, self-contained logic in a neutral arena (fighting games: move lists, frame data) | Small logic tied to its own terrain (platformers, run-and-guns) |
| Costs | Two windows; you must neutralise the source game (pin positions, refill HP, freeze the timer) | You must measure and reimplement; it's only as faithful as the measurements |
| Used for | Ryu -> SMW | Bill -> SGnG, Jimbo -> SGnG |

Rule of thumb: if the source character would die or wander off in his own level without you, don't
run him live. Cross-system works fine with capture + reimplement (NES -> SNES needed nothing beyond
converting tiles to 4bpp; an NES character's palette fits in one 15-colour SNES palette).

Live drive, briefly (if you build one): the source Mesen instance drives its game into a match with
scripted input, pins/refills what would end it, and sends the character's state (pose id, position,
facing, or the pixels of its sprites) every frame over LuaSocket UDP; the host instance receives it
and draws it. `udp:receive()` defaults to 8 KB, so pass 65507. Run both Mesen instances with
SingleInstance off and network access on in script settings.

## 2. Source-game extraction
- **Search for a disassembly first** ("<game> disassembly github", Data Crystal, TASVideos game
  resources, romhacking.net). Super C had a fully labelled one (RAM map, physics, weapon tables,
  metasprite format), which saved hours of RAM diffing. Clone it to a scratch folder, cite labels, and
  verify key values in the emulator, since a disassembly may describe a different revision.
- **No disassembly? Cheat databases are a RAM map.** libretro-database `cht/` files (Pro Action Replay
  `7Exxxx` codes) name lives, bombs, weapon slots, invincibility, stage select. Game Genie codes
  point at ROM instructions worth disassembling.
- **Extract sprites from the ROM's metasprite tables, not screen captures**, when the tables can be
  decoded: captures only get poses you triggered, and fight flicker. Find tables by searching for
  known byte sequences (no hard-coded offsets). Then prove it: draw the asset next to the real sprite
  in the source game and compare.
- **Streamed sprites: capture beats table decoding.** When the player's tiles are DMA'd into a small
  VRAM window every frame (Contra III), dump OAM + VRAM + CGRAM at `startFrame` and compose offline.
  Key frames by the game's own metasprite pointer and keep the most common capture per pose (that
  filters blinking). Record *everything* per frame so new questions can be answered offline.
- **Anchor every frame on one point derived from the game's own position variable** (e.g. X and the
  ground line). Find the constant against a screenshot's lowest pixel, not the tile layout. Jump and
  death frames then carry their own offsets and the host only tracks one point.
- **Verify the OAM row convention against a screenshot, per game** (a brute-force dx/dy search on one
  standing frame); "row = OAM y + 1" was off by one for one game's captures.
- **Bit-exact behaviour: port the routine, then replay it against a recording.** Contra III's homing
  went from 94.5% to 98.5% matching steps by porting the ROM's own table-based atan2 instead of
  `math.atan2`. Separate logic frames from lag frames (the game's own frame toggle), or slowdown looks
  like mismatches.
- **Exec hooks at a dispatch point** capture parameters cheaply (one hook on a weapon handler logged
  the aim index and muzzle offset for every shot in every pose).
- **Mind the data bank** when reading tables found in code: `LDA $8E1A,Y` reads `DB:8E1A`, not the
  code's bank.
- Store assets as a generated Lua table (`dofile`-able) with a Python generator that rebuilds them
  from the ROM alone, plus a labelled contact sheet for humans. Never hand-edit generated assets.
- Precompute 8x8 tiles at load, choosing the grid alignment that needs the fewest tiles (41 poses fit
  in at most 11 tiles each this way). Loading took 0.13 s, well inside Mesen's script timeout.

## 3. Let the host keep its physics; steer it
Writing positions bypasses the host's collision. Instead find the host character's **velocity /
direction fields** and overwrite them each frame, so the host moves and collides as usual, with the
guest's numbers.
- Examples: Mario's X speed from Ryu's per-frame movement; Arthur's speed magnitude + direction byte
  rewritten every airborne frame (Contra's air-control latch), jump velocity replaced on the takeoff
  frame, gravity set while jumping.
- Write at `emu.eventType.inputPolled` (between the previous frame's logic and this one's). Guard it
  to run once per frame (games may poll more than once, and skip polling on lag frames).
- **Fields the game rewrites every frame: override the write itself.** A Mesen write callback that
  returns a value replaces the value being written (`emu.addMemoryCallback(fn, emu.callbackType.write,
  ...)`; `return newValue`; `return nil` leaves it alone). SGnG writes Arthur's walk speed every frame;
  a callback on those two bytes turns it into Contra III's speed while SGnG keeps walls and slopes.
  Only override while the guest is actually moving, so the game's zero/knockback speeds pass.
- **`emu.setInput` only overrides the buttons you name.** Any button left out stays under the real
  pad's control. Leaving Y out let the real Y reach SGnG, so Arthur stopped to throw mid-run. Always
  pass every button explicitly (`kit.setPad`). Headless tests can't catch this (no physical pad).
- Filter the pad: strip what the host must not act on (the fire button, which the port handles;
  "down" while walking, which the host would turn into a crouch).
- States the host has no byte for can often be inferred (no ledge-fall state: Y dropping >= 2 px/frame
  while in a ground state).

## 3b. Art rules for anything added (defaults; ask the user)
SNESMASH's owner set these for every project; they're good defaults, but confirm with your user:
- **Stick to the source palette** of the screen you draw on: new text/graphics use colours already
  present in that screen's palettes (read CGRAM at runtime or from a capture), never new ones.
- **Always 1:1 with the existing pixel grid**: no scaling, no sub-pixel or rotated placement, no
  smoothing. Art is authored at native resolution and placed on whole pixels, aligned like the game's
  own art.
- Guest characters keep their own source-game palettes and pixels.
- **When there's a visual choice, mock it up on a real screen capture and let the user pick.**
- **Small text on art**: 4x6 letters with a dark outline + drop shadow survive a busy background (3x5
  didn't). For a slant, shear (each pixel column rises a little) rather than stepping whole letters.
- Check which layers are on before planning an overlay: SGnG's title has OBJ disabled on the main
  screen, so a sprite overlay would have been invisible; drawing into the screen's own BG layers was
  the way.

**Editing a static screen (title, menu) without touching the ROM: the user edits a PNG.**
`tools/screen_patch.py kit` makes an edit kit from a capture (`lua/lib/capture.lua`): `clean.png`,
`palette.gpl`, `palettes.png`. `screen_patch.py build` diffs the edited PNG, puts each changed pixel on
a layer (cells with art keep their palette; empty cells take any palette that holds all their new
colours; painting behind a layer clears the front pixel; the backdrop colour erases), and writes final
tiles + map words + tile hashes. It re-renders the screen from those tiles (`tools/snesgfx.py`, BG
modes 0/1, checked pixel-exact against the capture first) and refuses to write anything unless the
result equals the PNG; problems are marked in `<png>_problems.png`. At runtime `lua/lib/bg_patch.lua`
writes each final tile into a blank, unreferenced tile and repoints only that cell (shared/flipped
tiles stay intact), and restores only what's still its own when the screen goes.
- Only paint once the screen is fully set up: BG mode + layer registers as captured, display on, every
  cell's map word **and tile hash** as captured. A game can flag a screen before programming the PPU
  (SGnG: 2 frames early), and painting then wrote our tiles over the logo's map.
- VRAM holds different leftovers depending on the route to a screen. Test the live path (power-on,
  several input timings), not just a savestate of the finished screen.
- Keep hand-edited source art in `art/` and generated output in `assets/`.

## 4. Draw the guest through the real PPU
`lua/lib/snes_obj.lua` writes 4bpp tiles to VRAM, colours to CGRAM and entries to OAM from a
**`startFrame`** callback. The game's vblank DMA has already run by then, so these writes are what
gets drawn this frame; redraw every frame.
- Take over the host character's own resources: his OBJ palette, his streamed tile range and his OAM
  slots (park his entries offscreen and reuse those slots first, so sprite-priority order is kept).
  Free OAM slots are the ones the game parks below the picture.
- **Only draw the guest when the host's sprites were in OAM this frame**: invulnerability blinking,
  cutscene hiding and death are inherited for free.
- Anchor on the host's RAM position minus the camera, not his sprite bounding box. Verify the camera in
  every stage by comparing the prediction with the host's real OAM position (run the host vanilla).
- Copy the host sprites' **priority** each frame (`layer.hiddenPrio`); games change it per stage, and a
  fixed value put the guest behind one stage's background.
- Need more colours than the host's palette? Pick a palette no visible sprite uses this frame
  (`layer:freePalette({6, 4})`), since usage differs per stage.
- OAM Y is one line above the first displayed row (true on NES too).
- Host state can drive the guest's look cheaply: SGnG's armor became the guest's trouser colour (one
  palette entry).
- When the host transforms the player (curses, power-ups with their own sprite), step aside entirely:
  let the host draw and run its own form. It's funny, and it's free.
- **Lag frames: the game may skip its OAM upload** (slowdown). Then last frame's injected sprites are
  still in OAM and look like game sprites. Remember exactly what you wrote and reclaim any slot that
  still holds those bytes (`snes_obj` does this), and on such frames keep last frame's "host visible"
  answer, or the guest vanishes during slowdown.
- **Borrowed VRAM must be given back.** Tiles no sprite references during play can still hold graphics
  the game loaded once and needs later (a GAME OVER screen came up garbled). Snapshot every tile you
  claim before the first write and restore it when gameplay ends (`layer:snapshot()` /
  `layer:restore()`).
- 16x16 OAM sprites (2x2 tile blocks, `layer:sprite16`) for big effects: one OAM slot instead of four,
  and they count once toward the 32-sprites-per-line limit.
- Why not `emu.drawRectangle` overlays (the first proof of concept did that): PPU sprites layer
  correctly behind foreground, show in screenshots and recordings, have no HUD offset, and are cheap.

## 5. Guest attacks as native host objects (and how not to crash the host)
Spawning host weapon objects means the host does collision, damage, enemy deaths, drops and bosses.
Lua owns motion and looks. Rules learned the hard way:
1. **Allocate through the host's allocator.** Find it by write-watching a projectile slot during a
   native shot (`lua/recon/write_watch.lua`), then disassembling the spawn code. SGnG pops slot
   addresses off a free stack and bumps a per-type live count; its free routine pushes back and
   decrements. Grabbing "empty-looking" slots by hand double-pushed them, the stack ran off its end
   into a graphics variable, and the game crashed seconds later somewhere unrelated.
2. **Mirror the allocator's exact widths.** SGnG's stack index is 8-bit (bit 7 = empty). Treating it as
   16-bit wrote $FF into the next byte and the stack looked permanently empty.
3. **Turn off the host's rendering of your objects** (a draw flag in the object) and draw your own. The
   host only budgets sprites and tile uploads for its own small numbers of objects.
4. **Respect the native lifecycle.** "In flight" = the object's routine pointer is still the flight
   routine. On a hit the host flags the object and swaps routines; stop steering it then. Never zero
   an object yourself, and never teleport it far off screen (that took a generic offscreen path that
   corrupted RAM). To retire one, place it just short of its own despawn line moving outward, so its
   own code frees it.
5. **Write nothing outside gameplay.** Fades, map screens and stage loading reuse object RAM. Find a
   gameplay flag by tracing a death -> map -> reload cycle, an intro **and every stage**. Label
   snapshots automatically (e.g. by HUD pixels in the screenshot) and search for a byte that matches
   the label everywhere. SGnG's first two candidates held only in stage 1. Outside gameplay: pass the
   pad through, forget in-flight objects without touching RAM, draw nothing.
6. **A gameplay flag that holds in every stage can still flicker inside one.** SGnG's flag doubled as a
   screen-flicker toggle during one stage's tidal wave: 0 every other frame while the game ran on. The
   port went "hands off" on those frames and rebuilt its controller, the fresh controller took the
   airborne host for a new takeoff, and relaunched the jump every other frame (stuck in the air).
   Write-watch the flag to learn **every** writer before trusting it, and make controllers safe to
   rebuild mid-action: with no previous frame, never fire edge events (takeoff, landing, press).
7. **Host scripts can wait on the slots you borrow.** SGnG's READY GO text lives in weapon slot 1, and
   Arthur's intro loops until that slot is empty. The port's shots took slot 1 the moment it freed (the
   free stack is LIFO), and Arthur never got control. Don't allocate while the player isn't in control
   (detect it from the player's routine pointer), and when you touch objects in a shared pool, check the
   type so you only touch yours.
8. Area effects (smart bombs, splash): park an invisible native weapon on each target for a frame or
   two and let the host's collision deal the damage. Find targets the way the host's collision does
   ("vulnerable" bit + HP > 0) to skip scenery.
9. Native quirks become features: SGnG's monolith and coffins deflect weapons, so they deflect Contra
   bullets too.

## 5b. Sound
**"Port" means the source game's own sounds.** Translating between sound drivers (Konami's, Capcom's,
Nintendo's N-SPC...) is unique per game pair and never generalises, so effects travel as **clips**,
and the port drives a host DSP voice itself. Built and working for Contra III into SGnG; the pieces
are game-independent:

| Piece | What it does |
|---|---|
| `lua/lib/spc_log.lua` | capture: every DSP register write the sound CPU makes (SPC writes to `$F2` address / `$F3` data), stamped with frame + SPC cycle; main-CPU APU port writes; a start snapshot of the 128 DSP registers; sound-RAM dump |
| `tools/spc_clip.py` | cut a clip: one voice from a key-on until silent. Registers at key-on, later writes / re-keys / key-offs in 32 kHz samples, and the BRR samples **trimmed to what's heard** (it simulates the ADSR/GAIN envelope and BRR read position). `list` shows every key-on |
| a `build_sounds.py` per source game (you write it) | names the clips (marker in the capture + voice) via `spc_clip.py`'s library functions and writes `assets/<source>/sounds.lua` with `clips_to_lua` |
| `lua/lib/spc_clips.lua` | runtime player, driven by a host profile (below) |

Source side (SNES): script a capture scenario (each effect triggered once, with `L.mark()` markers),
find each effect's voice with `spc_clip.py list` (effects usually own the top voices), cut. NES and
other synthesized sources (not built yet): record the effect as audio, encode to BRR, make a
one-key-on clip.

Host side (recon once per host, then a profile in the host adapter):
- **Voices**: log key-ons per voice across every stage and correlate them with sound requests. Hosts
  with no idle voice are normal; borrow an *effect* voice (the one the host character's own attack
  uses is ideal, since the guest replaces that attack).
- **Free sound RAM**: diff RAM dumps across stages for never-changing zero runs, then *prove* them with
  read/write watches on those ranges while every host sound ID plays. The watch also catches the DSP's
  own accesses (echo buffer, sample directory), so it's thorough. Spare sample-directory entries (DIR
  register `$5D` x `$100`, 4 bytes each) hold the clip samples' pointers.
- **Sound census**: request every sound ID from a fixed savestate and log which samples (SRCN) each
  key-on uses; diff against a no-request baseline (emulation is deterministic). This shows which host
  samples are rare, which IDs are music, and which voices effects use.
- **Clock**: which timer the driver polls (`$FD-$FF` reads with value > 0) and its target (period).

Runtime (`spc_clips.lua`):
- **Samples**: small ones go into proven-free RAM at install. Big ones are **borrowed**: written over a
  host sample no voice is playing, chosen by fewest host uses this session. If the host then writes
  that SRCN or keys a voice on it, the original bytes go back *inside that write callback*, before the
  DSP latches the key-on, and the clip stops. Checksums of borrowable host samples (in the profile)
  catch a savestate made mid-borrow.
- **Voice**: write callbacks replace the written value, so the player swallows the host's writes to the
  borrowed voice while a clip plays (remembering them, and putting them back at the end so the host's
  next note has the right instrument), strips the voice from the host's key-off/echo/noise/pitch-mod
  writes, and keys it on/off itself through `spcDspRegisters`. A lane with `yield` gives the voice up
  when the host keys it on; without `yield` it keeps it.
- **Timing**: events are applied on the host driver's own ticks (a read callback on its timer counter
  adds ticks x period to the clip clock), so pitch sweeps land within one driver tick, not per frame.
- Install only during gameplay; uninstall restores every byte (verify byte-identical).

Facts that cost time: Mesen's `spc.cycle` counts at 2.048 MHz (34,036 per frame), so one 32 kHz DSP
sample = 64 counts. `emu.getState()` costs ~0.26 ms; SPC memory callbacks are nearly free. Lua writes
to `spcDspRegisters` behave like SPC writes (a KON write keys the voice on). Sound drivers update at
their timer rate (Contra III 250 Hz, SGnG 125 Hz), so replaying at 60 Hz stair-steps pitch sweeps.

**Stopgap** (before a real port of the sounds exists): play the host's own effects. Find the host's
sound-request routine by write-watching the APU ports (`$2140-$2143` on `snesMemory`), trace back to
the queue it drains, and request a sound by doing what the host's routine does. Guard against a full
queue (drop yours, never the host's). A small sound-test script lets the user audition IDs.

## 6. Recon workflow
- **Golden savestates.** Script the boot once, save a state at "player in control", load it in every
  test (`lua/lib/savestate.lua`; `createSavestate`/`loadSavestate` only work inside a CPU exec
  callback). Boot sequences are rarely frame-stable.
- **Stage warps**: search "<game> pro action replay stage select". A held RAM byte during boot gives a
  golden state per stage, essential for checking camera, priority and palettes everywhere. **Warp
  states are valid only until the first death**: other variables decide where a respawn goes (a stage-5
  warp respawned into stage 4, and the next reload garbled; vanilla too, so don't blame the port). Use
  natural boots for death/reload tests.
- **Per-frame RAM traces + search.** `lua/recon/ram_trace.lua` dumps work RAM every frame under a
  scripted plan; search offline with `tools/ramsearch.py` (`--rise/--fall/--const/--changes`, `--show
  addr:2`). Dump the whole bank, because objects are not always in the first 8 KB. Search by behaviour:
  "changes while walking, constant idle" finds X; "decrements by 1 per frame" finds timers.
- **Find the object table, not single variables.** Dump around the first field you find. The slot
  stride shows in neighbouring slots, and a pointer list in RAM (often the allocator's free stack)
  confirms it. Then every object shares the same offsets.
- **State-transition logging**: log only when a candidate state byte changes, with the input and a note
  of what the script was trying to do. One run gives the enum.
- **Probe by poking**: write each candidate value and screenshot (weapon IDs, armor types, curses fell
  out in minutes).
- **Corruption hunting**: write-watch the corrupted address and log PC plus the **D register**
  (`lua/recon/write_watch.lua`). On SNES, D is usually the current object's base, so it tells you
  *whose* code did it. **The PC Mesen reports in a write callback was the address after the writing
  instruction** in every case checked; disassemble from a little earlier and take the store just
  before it. Read the code with `tools/dis65816.py`. Unbounded queues (a VRAM
  upload queue right before the object table) and stacks are the usual victims.
- **Sprite recon**: dump OAM/VRAM/CGRAM + PPU state at `startFrame` (`lua/recon/ppu_dump.lua`); decode
  with `tools/snes_oam.py --list --box` to see who owns which slots, tiles and palettes. Never read PPU
  memory at `endFrame` (games stream tiles in vblank, so it's torn). Survey every stage before deciding
  a tile or palette is free.
- **Long recon with subagents: checkpoint to disk early.** A source game with no disassembly takes a
  recon agent hours and a huge context. Have it write the asset file and game doc incrementally, as
  soon as each piece is known, and hand the rest to a fresh agent with a "what remains" list.
- Test-only cheats (despawning enemies by clearing active bytes) keep recon runs alive. A timer that
  looks like invulnerability may not be the real flag.

## 7. Testing
- `ports/<port>/test_tour.lua` pattern (`lua/template/test_tour.lua`): load the golden state, hand the
  port a scripted pad (`PORT_INPUT`), save screenshots, then `python tools/sheet.py out/tour "t*.png"
  out/sheet.png` and look at the sheet.
- Feature tests (one per weapon / move) plus a debug logger that reads the port's state through a
  global the port exposes.
- **Cold boot test**: run the port from power-on through title/intro into play and through a death.
- **Soak tests**: seeded random input for thousands of frames, cycling features, then flag black frames
  and garbage in RAM. This found two crashes no scripted test hit.
- **Compare against vanilla**: run the same input with the port off; differences you didn't intend are
  bugs. When a long run comes up garbled, **bisect with a savestate**: save at a frame before the
  symptom and continue with the port off. If it still breaks, the cause is earlier or not yours.
- **Mesen swallows Lua errors** (headless shows nothing; even a syntax error just leaves the script
  dead; a callback that errors simply stops partway every frame). Wrap every callback in `kit.guard`
  and read `out/errors.txt` after every run (`tools/run_headless.py` prints new entries).
- Each headless run takes a few seconds. Mesen's stdout is noise (uninitialised-read warnings).
- Lua 5.4: bitwise operators on non-integer floats throw. Floor positions before ROM-style bit math.

## 8. Mesen 2 Lua
See `docs/MESEN_LUA.md`.

## 9. Kit
| File | Use |
|---|---|
| `lua/lib/kit.lua` | bootstrap: repo root, error-logging `guard`, full-pad `setPad`, input plans, memory/file helpers |
| `lua/lib/savestate.lua` | golden-state save/load from Lua |
| `lua/lib/snes_obj.lua` | draw your own sprites through the SNES PPU (lag-frame safe, snapshot/restore) |
| `lua/lib/capture.lua` | capture a screen's VRAM/CGRAM/OAM/PPU state + screenshot for offline tools |
| `lua/lib/bg_patch.lua` | apply a `screen_patch.py` patch to a static screen live, restore afterwards |
| `lua/lib/spc_log.lua` | capture DSP register writes + APU port traffic + sound RAM |
| `lua/lib/spc_clips.lua` | play captured clips on a borrowed host voice |
| `lua/recon/smoke_test.lua` | setup check on any ROM; lists this Mesen build's memTypes/cpuTypes/state keys |
| `lua/recon/ram_trace.lua` | per-frame RAM trace under a scripted plan (for `ramsearch.py`) |
| `lua/recon/ppu_dump.lua` | OAM/VRAM/CGRAM/WRAM/PPU dumps at chosen frames (for `snes_oam.py`) |
| `lua/recon/write_watch.lua` | who writes/reads an address: frame, value, PC, D, DB |
| `lua/template/` | port skeleton: `main.lua`, `host.lua` (host adapter), `test_tour.lua` |
| `tools/run_headless.py` | run a script headless with `--set` globals; reports Lua errors |
| `tools/ramsearch.py` | search RAM traces by behaviour; print addresses over time |
| `tools/snes_oam.py` | decode dumped OAM/VRAM/CGRAM to a sprite-layer image; list entries in a box |
| `tools/snesgfx.py` | SNES tile/palette codecs and a BG renderer (modes 0/1) checked against captures |
| `tools/screen_patch.py` | edit a static screen as a PNG -> live patch |
| `tools/dis65816.py` | disassemble SNES code at bank:address (LoROM/HiROM) |
| `tools/spc_clip.py` | list key-ons in a DSP capture; cut sound-effect clips |
| `tools/sheet.py` | contact sheet of screenshots |
