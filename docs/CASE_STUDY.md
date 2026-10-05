# Case study: Contra heroes in Super Ghouls 'n Ghosts

How the SNESMASH project went, in order, so you can calibrate scope and see where the time went. All
of it was done by Claude Code with the project owner play-testing and making the calls, over about
two days (October 2026). Detailed notes: `docs/games/sgng.md`, `contra3.md`, `super_c.md`.

## 0. Proof of concept: Ryu in Super Mario World (live drive)
Two Mesen windows. SSF2 drove itself into a match (scripted input), with Ryu's opponent pinned and
the timer frozen, and streamed Ryu's state over UDP; SMW's window steered Mario's X speed from Ryu's
movement and drew Ryu with `emu.drawRectangle`/HUD drawing. It worked, and taught two lessons: overlay
drawing is the wrong layer (no priority, an 8-line HUD offset, doesn't show in recordings), and a
platformer character can't run live in his own game without wandering off or dying. Both shaped the
next architecture.

## 1. Bill Rizer (Super C, NES) in SGnG: capture + reimplement
- **Source recon was fast** because Super C has a labelled public disassembly: RAM map, physics
  constants, weapon tables and the metasprite format. Sprites were decoded from ROM tables, converted
  to SNES 4bpp, anchored on Bill's feet, and proven against the real game side by side.
- **Host recon** (no public RAM map for SGnG): golden savestate, per-frame WRAM traces under scripted
  input + `ramsearch.py` for position/speed/state, then the object table (slot stride, free stack).
  A Pro Action Replay stage-select code gave a golden state per stage, which is what caught per-stage
  differences (sprite priority, camera, free palettes).
- **Drawing**: Bill drawn through the PPU in Arthur's own tiles/palette/OAM slots, only when Arthur's
  sprites were in OAM (blinking and death for free).
- **Physics**: Arthur's own velocity fields rewritten every frame; SGnG's collision kept.
- **Guns**: Contra bullets as SGnG lance objects. This is where the crashes were: hand-picked "empty"
  slots corrupted the allocator's free stack (crash seconds later, elsewhere); a 16-bit write to an
  8-bit stack index made the stack look permanently empty; teleporting bullets offscreen to retire
  them corrupted RAM. Each was found with write-watches logging PC + D and read with the disassembler.
  Rules 1-4 in PLAYBOOK 5 came from here.
- **Gameplay gate**: the first two "in gameplay" bytes held only in stage 1. The fix was labelling
  snapshots across boot, every stage, deaths and reloads, and searching for a byte matching the
  labels everywhere.

## 2. Jimbo (Contra III) in SGnG: no disassembly
- Contra III has no public disassembly; the libretro cheat database gave the first RAM addresses.
  Jimbo's tiles are streamed into VRAM every frame, so instead of decoding tables, a recorder dumped
  OAM/VRAM/CGRAM at `startFrame` across scripted capture scenarios, and a generator composed every
  pose offline, keyed by the game's metasprite pointer. Long recon ran in subagents that wrote the
  asset file and game doc incrementally.
- Run speed was a field SGnG rewrites every frame: solved with a write callback that replaces the
  written value.
- Guns: all Contra III weapons. The homing missile was made **bit-exact** by porting the ROM's
  steering routine and its table-based atan2 and replaying it against a recording (94.5% -> 98.5% of
  steps matching, once logic frames were separated from lag frames). Smart bomb: invisible native weapons parked on
  every target for a frame so SGnG's own collision deals the damage.
- Lag frames: SGnG slows down a lot, and on frames where it skipped its OAM upload the injected sprites
  piled up. `snes_obj` now reclaims its own leftovers.
- Borrowed VRAM tiles that "nobody used" held the GAME OVER screen's graphics: snapshot + restore.

## 3. The bugs only play-testing found
- **Run-and-gun**: Arthur stopped to throw while running and shooting. `emu.setInput` had been given
  only some buttons; the real Y reached SGnG. Headless tests can't see this (no physical pad).
- **Tidal wave**: in stage 1, the gameplay flag flickered 0/1 every frame during a wave effect (it
  doubled as a screen-flicker toggle). The port rebuilt its controller on each "0" frame, which then
  took the airborne Arthur for a fresh takeoff and relaunched the jump every other frame. Fixes: learn
  every writer of the flag (write-watch), and make controllers safe to rebuild mid-air.
- **Frozen respawn**: Arthur's intro waits for weapon slot 1 (it holds the READY GO text) to empty; the
  port's shots kept taking slot 1. Fix: no allocations until the player is in control.

## 4. Polish
- **Title card**: "STARRING JOHN "SUPER" CONTRA" painted into the title logo's BG layer. The owner
  picked a style from mockups rendered on a real capture, then touched up pixels in a PNG; the
  `screen_patch.py` pipeline turned the PNG into tiles + map edits applied live. First version garbled
  the logo because the title flag came on 2 frames before the PPU was set up: now it checks registers,
  map words and tile hashes before painting.
- **Sound**: first a stopgap (SGnG's own effects via its sound queue), then the real thing: Contra
  III's own gun and bomb sounds captured as DSP clips and played on a borrowed SGnG voice, with SGnG's
  samples borrowed only while silent and every byte restored afterwards. Verified by comparing pitch on
  every driver tick against the Contra III capture.

## What the test suite ended up as
Tour (run, jump, mid-air reverse, aim, prone, fire), one test per gun, run-and-gun with a held fire
button, smart bomb, cold boot through title -> play -> death -> reload, seeded random soaks in several
stages, title-card checks on every path off the title screen, sound clips (right voice, right pitch per
tick) and sound-RAM restore (byte-identical). Every run checks the error log.

## Takeaways
- Most of the time went into host recon and into the host's lifecycle (allocator, gameplay gate,
  intros, lag frames), not into the guest. Budget for it.
- Every stage is different. Golden states per stage early pays for itself.
- The user's play-testing found the bugs that mattered most. Ask early and often.
