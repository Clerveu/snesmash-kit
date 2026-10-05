# Super Ghouls 'n Ghosts (SNES, USA): host-game notes

> From the SNESMASH project, copied as-is (USA ROMs). Paths to scripts, `states/`, `shots/` and assets refer
> to that project's private repo, not this kit; the addresses, findings and methods are what's useful here.
> Verify against your own ROM revision before relying on an address.

ROM: `ROMS/Super Ghouls 'N Ghosts.sfc` (1 MB LoROM, headerless; code runs from banks $01/$02, sometimes
via FastROM mirrors $81/$A1). Addresses are bank $7E WRAM (`emu.memType.snesWorkRam`) unless noted.
Everything here was observed in headless traces unless marked "guess". There's no useful public RAM map
(wiki.superfamicom.org has a handful of ROM notes).

## Modes and getting to gameplay
- **In gameplay = `$032E == 1`** (and Arthur's slot active, `$043C != 0`). Checked in all 7 stages: it turns
  on ~100 frames before the HUD (stage fade-in, after loading) and off a few frames into a death fade; 0
  through boot, title, story, map and loading.
  **But `$032E` is not a mode byte, and it flickers mid-stage.** Writers (write-watch,
  `scripts/recon/sgng_032e_writers.lua`): `$01:AD9C` sets it to 1 at stage start, the RAM wipe at
  `$01:80B9` (STZ `$031E-$1FB1`) clears it, and a screen-flicker effect at `$01:B2B1` writes
  `($0373 & 1)` to it every frame while the timer `$0373` counts down (also toggling bits of `$02F0/$02F1`,
  display shadows, guess). Stage 1's tidal wave starts that effect (`$01:9902`: `$0373 = $4F`), so `$032E`
  alternates 0/1 for ~79 frames while the game runs normally. Use **`($032E == 1 or $0373 != 0)` and Arthur
  active**. More `STZ $032E` sites exist in banks 03/04 (`03:9C3B`, `03:D010`, `04:9343`, `04:94BE`,
  `04:9566`), not identified yet.
- **Stage start / respawn intro (READY GO)**: Arthur's slot byte is `$0C` while he fades in, then his routine
  (`+$03/+$04`, bank `$01`) goes `$CD67` -> `$CD78` (puts the READY GO text, object type `$54`, into
  **weapon slot 1**) -> `$CD8D`, which loops on `LDA $047D / BNE` until slot 1 is empty, then `$CE16` ->
  `$CE83` (normal control). Anything that allocates player-weapon slots during the intro can keep slot 1
  busy (the free stack hands slot 1 out first) and Arthur never gets control.
- **Stage 1 tidal wave**: around X 2480-2650 (after the coffins by the sea) a wave floods the screen and the
  ground breaks into islands. Standing on it, at the stone monolith, or jumping into the gaps all end in
  state `$1D`. `states/sgng_stage1_tide.mss` = walking at X 2381 just before it (natural boot, safe across deaths).
- Traps: `$0018` is 6 in stage 1 play but 0 in stage 2; `$0096` is 1 in play *and in the story* and 2 at
  times in stage 2; `$0009` flips when Arthur walks. A flag found in one stage must be checked in all.
- **Stage select: `$028D` = stage - 1** (from a Pro Action Replay code). Held during boot it starts that
  stage. `$028F` is probably the section/checkpoint (unverified).
- **Warp states are only valid until the first death**: a death in the stage-5 warp respawned into stage 4's
  cave, and the next death garbled the game (vanilla too). `$028F` is 0 in all states; the respawn
  variable is still unknown.
- Golden states: `states/sgng_stage1.mss` ... `sgng_stage7.mss` (150 frames after `$032E` turns on, READY GO
  showing), built by `scripts/recon/sgng_make_stage_states.lua` (`SGNG_STAGE = n-1`). The menu route to
  the official stage-select code (Options > EXIT, pad 2 L+Start, pad 1 Start) didn't work headless.
- After a death, fade + map + reload takes about 300 frames. **Object RAM is reused then; write nothing.**

## Title screen
- **`$02E1` = 5 while the title is up** (fades included; set at `$04:9340`), 4 in the story, attract demo
  and gameplay, 0 between screens. It stays 5 on the OPTION MODE screen too, and blips to 5 for single frames
  during the intro when Start is pressed, so also check the logo is in VRAM. It turns 5 about 2 frames
  **before** the title's PPU setup (BG mode/addresses still 0, forced blank). VRAM outside the logo holds
  leftovers that depend on the route (Start-skip vs no input). No input: story, title at ~frame 2290-2820, then an attract demo of stage 1 (`$032E` = 1 there, so
  the port plays the demo with its guest), then the intro loops. `states/sgng_title.mss` = frame 2400 of a
  no-input boot (title fully up).
- Layout: BG mode 1, **main screen = BG1 + BG3 only (no OBJ)**. BG1 = logo (4bpp, chr word `$2000`, map
  `$0000`, 296 cells, 39 tiles reused, 21 cells flipped; palette 4 everywhere except "Super" = palette 6).
  BG3 = text (2bpp, chr word `$5000`, map `$1800`, all palette 0: outline `#290000`, orange `#f79c00`,
  red `#de2900`). BG lines show on screen one line up (screen y = BG y - 1 at vscroll 0).
- BG3 font tiles: `0-9` = `$00-$09`, `A-Z` = `$0A-$23`, `-` `$24`, `:` `$25`, `,` `$26`, `.` `$27`,
  `!` `$28`, (C) `$49`, TM `$47-$48`, blank `$45`; menu cursor `$4E-$4F` (palette 1). No quote mark.
  Blank BG3 tiles `$50-$5F` are free. ~200 blank, unreferenced BG1 tiles below word `$5000` (e.g. `$100`).
- Text rows: GAME START 17, OPTION MODE 19, copyright 22/24/26. The logo reaches y 132, so there's no
  free row directly under it.

## Sound
- **Sound queue**: 32-entry ring of sound IDs at `$02F8`, write index `$02F7`, read index `$02F6`. `$00:8540`
  sends one ID per pass to APU port `$2140` once the sound CPU has echoed the previous one (`$02F5`
  counts the handshake). Request a sound = `JSL $01:8053` with A = id (177 call sites): store at the write
  index, advance mod 32. `$F0-$F2` and `$F5/$F6` (+ parameter byte to `$2141`) are commands.
- IDs seen: weapon throws lance `$20`, crossbow `$21` (one per arrow), dagger `$22`, scythe `$23`, torch
  `$24`, axe `$67`; `$69` = weapon hits something. Audition any ID: `scripts/contra_sgng/sound_test.lua`
  (`SNESMASH - SGnG sound test.bat`). Found by write-watching `$2140` (`scripts/recon/sgng_sound_ports.lua`).
- **IDs**: music `$01-$16`, effects `$20-$69`; IDs mirror every `$6A` (`$8A` = `$20`). Seen: armor
  pickup `$2E` (`02:BE3C`, next to `INC $14BA`), `$2B` (voice 1, sample #20) every jump.
  `scripts/recon/sgng_sound_census.lua` lists the samples each ID plays.

### Sound CPU (recon for guest sounds as clips; profile `sgng.SOUND`, player `scripts/lib/spc_clips.lua`)
- **Sound RAM is loaded once at boot** and is identical in all 7 stages (`$0300-$FFFF`; `$0000-$02FF` is
  the driver's work RAM). Driver code + all music data `$0300-$57FF`, sample directory `$5800` (DSP DIR
  `$58`), 22 samples `$5940-$FF66`. No echo (EVOL 0, EDL 0: the 4-byte echo buffer at `$0D00` still
  gets written). Master volume `$7F/$7F`, same as Contra III.
- **Voices**: effects on 0-2 (0 = hits `$69`, 1 = Arthur's throws and jump sound, 2 rare), music on 3-7
  (voice 2 too in stages 3, 5, 6, 7). No voice is idle in every stage. The driver keeps effect voices
  keyed off with a loop writing KOF = `$07` every 66 SPC cycles (`$0BF5` is its DSP-write routine).
- **Timer**: timer 0, target 64 = 125 Hz ticks, polled at `$FD` (`$0347`).
- **Free sound RAM** (no SPC or DSP access while every sound ID played, `scripts/recon/sgng_aram_watch.lua`):
  `$0C33-$0CFF` (just after a table read by `$0B72-$0B80`), `$0D04-$0DFF`, `$57CE-$57FF`, `$5900-$593F`,
  `$FF66-$FFFF`, and sample #7 `$7DAC-$7E20` (117 bytes; no sound ID plays it). Directory entries 22-31
  (`$5858-$587F`) are unused.
- **Samples by use** (census + all-stage captures): #6 (2538 B) only armor pickup `$2E` and `$4B`
  (`03:CF2C`); #16 (2637 B) stage 3 music only; #8, #15, #17, #14 other stages' music. These are the
  borrow candidates. #0 and #1 are shared by almost every effect.

## Object pool
One flat table of `$41`-byte slots: **slot k at `$043C + $41*k`**.
- Slot 0 = Arthur. Slots 1-10 = Arthur's weapon objects (and their effects). Slots 11-49 = everything else
  (flying armor pieces, enemies, the stone monolith, coffins); their free stack is at `$13F1` (lists up to 49).
- **Player-weapon allocator** (`$01:D9C7`): free stack of slot addresses at `$142F + Y` (word entries),
  `Y = $1445` (**8-bit** top index; bit 7 set = empty). Pop = read entry, `$1445 -= 2`. The spawner then
  does `INC $1A9A + type` (live count per object type; type = object `+$06` = weapon + 1).
- **Free routine** `$02:80D2`: `DEC $1A9A + (+$06)`, clears fields, `$1445 += 2` (8-bit INCs), pushes the
  slot address (`TDC` = its D) onto the stack. Never take slots without popping: they get pushed twice
  and the stack overruns `$142F+` into `$14BA` (armor), which triggers a garbage graphics reload and an
  overflow of the VRAM upload queue (crash).
- Native lance spawn (`$01:D483`): byte 0 = `$0C`, `+$2B` = damage from `$1F25`, `+$06` = `$14D3+1`,
  `+$0E` from a table, `+$08 |= flags`, direction/facing copied from Arthur.

### Common object fields
| off | size | meaning |
|---|---|---|
| +$00 | 1 | active: 0 free, 1 normal, $0C just spawned / leaving, bit 7 set = was hit this frame |
| +$01 | 1 | also cleared on free |
| +$03 | 3 | routine pointer (long). Lance in flight `$01:E2C6`; deflected by a wall/monolith `$01:E25A`; hit an enemy `$02:8D6E` |
| +$06 | 1 | object type index (counts at `$1A9A + type`) |
| +$08 | 1 | flags. **Bit 3 = draw me** (clear it and the object emits no sprites but still runs and collides). Bit 7 = hurt/hit (skipped by collision) |
| +$09 | 1 | **bit 6 = takes part in weapon collision**: on an enemy = can be hit, on a weapon = can hit (`$02:FCE7`, `$02:FD1D`) |
| +$0E | 1 | **enemy HP / weapon damage**: on a hit, enemy +$0E -= weapon +$0E (`$02:FB83`). Zombies 1 HP. Vulnerable objects with 0 HP are deflecting scenery (monolith type $27, coffins $6F) |
| +$11 | 1 | movement direction (0 right, 1 left) |
| +$12 | 1 | facing (0 right, 1 left) |
| +$16 | 3 | X speed magnitude, 8.8 + high byte (walk $0100, jump $011E, lance $0380) |
| +$19 | 3 | Y velocity, signed 16.8 (jump starts about -$02F2, double jump about -$0390) |
| +$1C | 1 | gravity added to Y velocity per frame (Arthur $20) |
| +$1E | 3 | X: sub, pixel, high (world) |
| +$21 | 3 | Y: sub, pixel, high (world; Arthur stands at $B0 at stage start) |
| +$2B | 1 | per-weapon value from `$1F25` at spawn (lance 6, torch 8/10); NOT the damage, which is +$0E |
| +$3E | 2 | graphics/animation slot pointer (lance $203E, deflected $2046), guess |

### Arthur (slot 0, base `$043C`)
| addr | meaning |
|---|---|
| `$0479` | **state**: 00 walk, 01 neutral jump, 02 directional jump, 03 idle, 04 crouch, 05 neutral double jump, 06 directional double jump, 09 hurt, 0A dead, 1D sunk (fell into a pit / swept off by the tidal wave: drops off screen, `+$08` bit 7 set, then the death fade). No state for walking off a ledge (Y just drops) |
| `$0461` | animation ID: 00 idle, 01 walk, 07 neutral jump, 08 directional jump, 09 crouch, 0A/0B throw, 15 double jump, 1B hurt, 1D dead. `$0462` = ID whose tiles are loaded |
| `$0446-47` | animation script pointer; `$0460` frame timer |
| `$044A` | 1 while armored, 0 after the hit that strips it (not the armor type) |
| `$044B` | $FF while hurt |
| `$0444` (+$08) | flags; bit 7 set while hurt |
| `$046B` | post-hit invulnerability countdown (writing it does NOT prevent hits) |
| `$14BA` | **armor/look**: 0 boxers, 1 steel, 2/3 bronze (green), 4 gold, 5 cursed maiden, 6 cursed creature. When it differs from `$14B8`, `$01:D0C7` reloads Arthur's graphics set |
| `$14D3` | **weapon**: 0/1 lance, 2/3 dagger, 4/5 crossbow, 6/7 scythe, 8/9 torch, 10/11 axe, 12/13 psycho cannon (guess), 14/15 goddess' bracelet. Odd = enchanted (bronze armor) |

## Camera
- Camera X: `$15DD-$15DE` (pixel), `$15DC` sub. Equals BG1 hscroll. Arthur's screen X = X - camX.
- Camera Y: `$15E1-$15E2` (pixel), `$15E0` sub. BG1 vscroll follows a frame later.
- Arthur's feet on screen = `Y - camY + 16`, centre = `X - camX`: verified against his OAM in all 7 stages
  (within 2 px; the jump pose is 2 px shorter).

## Movement model
- **Arthur's speed can be changed by overriding the game's own writes**: a Mesen write callback on
  `$0452-$0453` returning new bytes (e.g. $68/$01 = 1.406 px/f) replaces the walk speed SGnG writes every
  frame, while walls and slopes still work.
- Walking writes speed $0100 (1 px/frame) and the direction byte each frame.
- A jump latches speed ($011E or 0) and direction at takeoff. Vanilla can't steer, only turn.
- **Rewriting `+$16` speed and `+$11` direction every frame (at `inputPolled`) steers Arthur mid-air,**
  and SGnG still applies its own wall/floor collision and gravity.
- Overriding `+$19` Y velocity on the takeoff frame and `+$1C` gravity while airborne changes the jump
  arc (Contra: -4.06 px/f and 0.137 gives a 58-62 px jump). The fall speed cap is SGnG's own.
- Neutral jump peaks about 37 px; the double jump adds about 28 px. Y velocity sits at its cap even
  while standing, so it can't detect falls.

## Rendering
- OBSEL: 8x8 / 16x16 sprites, OBJ name base VRAM word $6000, name select gap $1000.
- Arthur: ~14-16 8x8 sprites, **OBJ palette 0, tiles $000-$012, priority 2 in stage 1 but higher in
  stage 5** (a replacement must copy his priority each frame or it vanishes behind the background). His OAM slot index varies,
  so identify him by palette + tile range. Tiles are streamed per animation frame through the queue below.
- Thrown lance: palette 1, tiles $020-$023. Flying armor pieces: palette 1, tiles $013-$018. Zombies
  palette 5, torch embers palette 7. Unused OAM entries are parked at y = 225.
- Invulnerability blinking leaves Arthur out of OAM on alternate frames.
- **VRAM upload queue**: `$037C + 8*n` records (VRAM address `$6000 + tile*16`, source, size, bank, flag
  $80), count at `$037B`. Filled by `$01:8E90`. **No bounds check:** the 33rd entry overwrites the object
  table at `$047C`.
- **OAM buffer**: about `$0200-$041F`, right before the object table.

## Collision quirks worth knowing
- The stone monolith (an object near X 232 in stage 1) and closed coffins deflect weapons: they set the
  weapon's active byte to `$8C` and its routine switches to the deflect routine.
- Lances hitting enemies switch to `$02:8D6E`. Enemies die with SGnG's own effects and score.

- **OBJ tiles used by game sprites, union over all 7 stages** (`scripts/recon/sgng_tilesurvey.lua`, vanilla
  play): $000-$018, $020-$023, $02A, $02D-$02E, $030, $038, $03B, $042, $080-$0B7 (minus $093), $0D0-$0EF
  (partly), $0F0-$0F3, and the whole second table. Free: $050-$07F, $0C0-$0CF and scattered others. But
  "never referenced by OAM during play" doesn't mean unused: restore borrowed tiles when gameplay ends.
- **OBJ palettes used by game sprites per stage** (1500 frames each): 1: 0,1,2,3,5,7; 2: 0,1,3,6; 3: 0,1;
  4: 0,1,3,6; 5: 0,1,3,4,5,6,7 (only 2 free); 6: 0,1,3,4,5,7; 7: 0,1,3. Pick per frame.
- SGnG slows down heavily; on lag frames it skips the OAM upload, so injected sprites from the previous
  frame are still in OAM.
- OBJ palettes 4 and 6 were never used by game sprites in 2000 frames of stage 1 play (others: 0 Arthur,
  1 lance/armor bits, 2, 3, 5 zombies, 7 embers). Other stages not surveyed, so pick per frame.

## Open questions
- `$028F` meaning; psycho cannon/bracelet naming; gold-armor magic charge (needs the attack button, which
  the port takes over); boss HP layout; palette usage outside stage 1.
