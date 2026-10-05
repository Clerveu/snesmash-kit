# CLAUDE.md: retro character porting kit

You're helping someone put a character from one retro game into another (Contra's hero in Super
Ghouls 'n Ghosts, Ryu in Super Mario World...), live in the Mesen 2 emulator, with Lua scripts and
offline Python tools. No ROM patching: the host game runs unmodified and a script steers it every
frame. This kit holds what the SNESMASH project learned doing that, so you start where it left off
instead of rediscovering it.

## Read first
1. `docs/PLAYBOOK.md`: the method, and the mistakes that cost the most. Read all of it before
   planning a port; it's ordered the way the work goes.
2. `docs/MESEN_LUA.md`: Mesen 2 API facts and traps.
3. `docs/SETUP.md`: if `mesen_headless/` or `out/smoke/report.txt` doesn't exist yet, setup comes first.
4. `docs/CASE_STUDY.md`: how one real port went, milestone by milestone, to calibrate scope.
5. `docs/games/`: real notes for Super Ghouls 'n Ghosts, Contra III and Super C. If the user's port
   involves one of these, that's a big head start (verify against their ROM revision).

## First conversation with a new user
- Get setup working and the smoke test passing (`docs/SETUP.md`) before anything else.
- Ask what they want: which character, from which game, into which host game, and what the guest
  should bring (look, movement, attacks, sounds) versus what the host keeps (levels, enemies,
  collision, health, music). Suggest **capture + reimplement** unless the guest's logic is big and
  self-contained (fighting games), and explain the choice in a sentence (PLAYBOOK 1).
- Assume the user is not a reverse engineer. Explain findings in plain terms and show them pictures.
- Agree on milestones. The order that worked:
  1. Golden savestate of the host at "player in control"; host recon (player object, camera, gameplay
     flag, state enum) written to `docs/games/<host>.md`.
  2. Source recon + sprite extraction into `assets/<source>/`, with a contact sheet the user checks.
  3. Guest drawn over the host player through the PPU, moving with the host's physics.
  4. The guest's movement numbers (run speed, jump, air control) steering the host's physics.
  5. Attacks as native host objects through the host's allocator.
  6. The source game's own sound effects.
  7. Extras (title-screen credit, HUD touches) as the user wants.
- Check in at each milestone with something to look at (a contact sheet, a GIF from `tools/gif.py`)
  and ask the user to play-test live in `mesen/`: headless tests can't press a real pad, and some bugs
  only show by hand. Users are usually happy with long multi-step work between check-ins.

## Hard rules (each one cost a crash or hours)
- **Never write host RAM outside gameplay.** Fades, maps and loading reuse object RAM. Find an
  in-gameplay test that holds in every stage, write-watch it for every writer, and go hands-off
  (pad passes through, nothing written, nothing drawn) whenever it's false.
- **Never allocate host objects except through the host's own allocator**, mirroring its exact data
  widths. Never zero objects; retire them the way the host would.
- **Steer velocities, not positions**, so the host's collision keeps working.
- **The host adapter (`ports/<port>/host.lua`) owns every host address.** Controllers, guns and drawing
  stay memory-free. Every address in code and docs says how it was found and where it was verified.
- **`emu.setInput`: always pass every button** (`kit.setPad`); omitted buttons leak the real pad.
- **Read and write PPU memory at `startFrame`**, never `endFrame`. Redraw sprites every frame.
- **Give back everything you borrow** (VRAM tiles, sound RAM, voices) when gameplay ends.
- **Wrap every callback in `kit.guard`** and read `out/errors.txt` after every run: Mesen swallows Lua
  errors silently.
- Never download ROMs or commit ROMs, savestates, emulator binaries or ROM-derived assets to anything
  public. Generated files (`assets/`) are rebuilt by their Python generators, never hand-edited.

## How to work
- **Test headless after every change**: `python tools/run_headless.py <script> <rom> --set NAME=value`.
  Runs take seconds. Look at the output yourself (read contact sheets from `tools/sheet.py` as images)
  before telling the user something works. Check every stage, not just the one you developed in, and
  compare against the host running vanilla.
- Start ports from `lua/template/` (entry, host adapter, test tour). Load modules with
  `dofile(KIT .. "lua/lib/<module>.lua")` after bootstrapping `kit.lua` (see its header).
- One-off recon scripts go in `sources/<game>/` or a `recon/` folder; scratch output in `out/`.
  The generic recon scripts in `lua/recon/` cover traces, PPU dumps and write-watches; extend those
  before writing new ones.
- **Write findings to disk as you go**: addresses into `docs/games/<game>.md`, design and status into
  `docs/ports/<port>.md`, with a "Handoff" section (what's done, what's next, open bugs) kept current.
  Long recon fills your context and it will be summarised; the docs are what survives.
- For long source-game recon, use subagents that checkpoint the asset file and game doc incrementally,
  and hand the remainder to a fresh agent with a "what remains" list.
- **Search before reverse engineering**: public disassemblies, Data Crystal, TASVideos resources and
  cheat databases (libretro-database `cht/`) often hand you the RAM map.
- Ask before choices that are the user's: which guest/host, art and colour choices (show mockups on a
  real screen capture and let them pick), what to sacrifice when the host can't do something.
- **Add to `docs/PLAYBOOK.md`** whenever you learn something that would help on a different game, and
  keep it game-independent. That file is how the next port starts ahead.
- Commit at milestones after tests pass (if the user uses git).

## Defaults the original user set (confirm with yours)
- Added art uses only colours already on that screen, 1:1 on the native pixel grid, no scaling.
- "Port" means the source game's own assets (its sprites, its sounds); host stand-ins only as stopgaps.
- If the user names a game that seems wrong (wrong console, a sequel), follow what they asked and
  mention the conflict briefly.

## Gotchas already paid for
- Mesen `dofile` needs absolute paths; scripts find their folder via `debug.getinfo` (see `kit.lua`).
  On Windows, `C:/...` works and MSYS-style `/c/...` fails silently.
- Savestate calls only work inside an exec callback (`lua/lib/savestate.lua` handles it). Warp
  savestates (stage select) are only valid until the first death.
- A write callback's return value replaces the written value; return nil to leave it.
- In write callbacks, `cpu.pc` is the address after the writing instruction; `cpu.d` (SNES) tells you
  whose object's code ran.
- Lua 5.4 bitwise ops on non-integer floats throw: floor first.
- When Python writes Lua source, a `"\n"` in a Python string becomes a real newline inside a Lua
  string literal: a syntax error that Mesen won't report. Use `"\\n"`, or the Write tool.
- Very long shell heredocs sometimes fail to parse; write long files with the Write tool.
- Games skip input polling on lag frames and may poll twice in one: count frames at `startFrame`.
