# Contra III: The Alien Wars (SNES, USA): Jimbo as a portable character

> From the SNESMASH project, copied as-is (USA ROMs). Paths to scripts, `states/`, `shots/` and assets refer
> to that project's private repo, not this kit; the addresses, findings and methods are what's useful here.
> Verify against your own ROM revision before relying on an address.

ROM: `ROMS/Contra III - The Alien Wars.sfc` (1 MB LoROM, headerless, internal name "CONTRA3 THE ALIEN WAR").
No public disassembly exists (SA-1 Root by VitorVilela7 patches it but documents no RAM; Data Crystal has
a few ROM ranges; libretro's cheat database gave the first RAM addresses). Everything below was
traced in Mesen headless and read with `tools/dis65816.py`. Code runs with **data bank $05**, so
`LDA $8E1A,Y` in bank $00 code reads `$05:8E1A`, and low-RAM reads show up in Mesen as `$05xxxx`.

## Assets (rebuild: `bash scripts/contra3/rebuild.sh`, about 1 minute headless)

| File | What |
|---|---|
| `assets/contra3/jimbo_frames.lua` | `dofile()` -> palettes, frames, bullets, sprite_words, anims, physics, aim, weapons, bomb, controls, ram, dir_table, atan_table, flame_step |
| `assets/contra3/jimbo_atlas.png` / `.json` | contact sheet of every frame (anchor cross-hair) |
| `scripts/contra3/build_jimbo.py` | the generator: cuts frames from recordings, reads ROM tables |
| `scripts/contra3/rec.lua` + `s_*.lua` | headless recorder + capture scenarios (`c3rec.py` reads the dumps) |
| `scripts/contra3/homing_ref.py` | bit-exact Python reference of homing steering + the ROM atan2 |
| `scripts/contra3/homing_check.py` | validates the reference against a recorded stage 1 run |
| `states/contra3_stage1.mss` | golden state: stage 1, Jimbo in control (`scripts/contra3/make_state.lua`) |
| `assets/contra3/sounds.lua` | gun + smart bomb sounds as DSP clips (`scripts/contra3/build_sounds.py` from the `s_sounds.lua` capture; see "Sound") |

**Sprites are captured, not decoded from ROM tables.** Contra III streams the player's tiles into VRAM
every frame (OBJ tiles `$000-$01F`), so the recorder dumps OAM + VRAM + CGRAM at `startFrame` and the
generator composes the player's 16x16 sprites (5-6 of them, OBJ palette 5) pixel-exact. Frames are
keyed by the metasprite pointer at `$0200`. Bullets are single OAM sprites; their sprite word
(slot `+$02`) is decoded straight from VRAM.

### Format (same top-level shape as `assets/superc/bill_frames.lua`)
- Player frames: anchor `ax` = player X (`$0206`), `ay` = ground line = player Y (`$020E`), in screenshot
  rows (feet on row Y-1). Pixel `(col,row)` -> `(ax - ox + col, ay - oy + row)`; "stand" has `oy == h`.
  Verified by `scripts/contra3/test_atlas.py`: the stand frame matches a Mesen screenshot 100% at this
  anchor; stationary poses score 92-100% (the rest is bullets/muzzle flash drawn over Jimbo). Facing left:
  `x = ax + ox - 1 - col` (the ROM has separate left-facing drawings; flipping the right ones is close).
- Rows are one hex digit per pixel (0 transparent, 1-15 = colour in the frame's palette group).
- `palettes` = named groups of 15 RGB colours: `player` (OBJ 5), `obj0`, `obj1`, `obj6`, `obj7` (weapons/effects).
  Every frame/bullet has `pal = "<group>"`. `palette` = `palettes.player` (compat).
- Bullets/effects: anchor = object (X, Y) (`+$0A/+$0E`). 16x16 sprites draw from (X, Y); 8x8 ones from (X+4, Y+4) (OAM writer `$00:E2D7`). Visual centre (X+8, Y+8).
- `sprite_words["3F2C"] = {frame=..., hflip=, vflip=}` maps every sprite word the weapon code writes to a frame + flips.

## RAM map (P1; P2 object is +$40, P2 arrays at `$1DC0+`)

| Addr | Meaning |
|---|---|
| `$0200` | P1 object ($40 bytes). `+$00` metasprite pointer (pose ID) |
| `$0204` | facing: bit 1 = left |
| `$0205/06` | X sub / pixel (screen coordinates) |
| `$020D/0E` | Y sub / pixel (ground = 200 in stage 1) |
| `$0212` | action: 0 ground, 3 jumping, 4 respawn drop, 7 dying, 8 dead |
| `$0219-1B` | X velocity (signed, 8 fractional bits): run `$0168` |
| `$021D-1F` | Y velocity: jump starts `-$05C0` (-5.75) |
| `$0220` | animation id (run index*2: 00..0A; 1A up; 1C diag-up; 2A prone; 2C diag-down; DF down; 3A-3D spin; E8-ED death; D3/DB respawn) |
| `$0222/23` | controller (low/high byte) |
| `$0224` | `$20` = untouchable by enemy contact (turns the player white) |
| `$0226` | d-pad direction bits |
| `$022A` | player hitbox top (Y-35 standing, Y-14 prone) |
| `$1F80` | selected weapon slot (X switches) |
| `$1F84/$1F86` | weapon in slot I / II: 0 default, 1 S, 2 C, 3 H, 4 F, 5 L (6+ crash) |
| `$1F88` | invincibility timer (`$FF` = invincible; draws the barrier bubble) |
| `$1F8A` / `$1F8C` | lives / bombs |
| `$1380` | camera X |
| `$00BC` | frame toggle 0/1 (alternate-frame work: homing steering, bomb damage, flicker) |
| `$0AC0-$0BFF` | P1 bullet slots (10 x $20). `$0C00-$0D3F` P1 slot-II pool, `$0D40+` P2 |
| `$0280-$0A80` | enemy objects, $40 apart: `+$06` HP (negative = dying), `+$0A` X, `+$0E` Y, `+$16` flags (bit 4 shootable/targetable, bit 5 immune), `+$28` width, `+$2A` height (negative) |
| `$1646` | homing missiles' shared round-robin enemy pointer |
| `$1510` | P1 smart bomb radius (0 = none), speed `$151A.$1518`, centre `$151C/$151E` |
| `$15A0+` | active enemy pointer list (bomb damage loop) |

## Physics (measured)
- Run 1.40625 px/f right (`$0168`), 1.41015625 left (`-$0169`), no acceleration.
- Jump -5.75, gravity 0.25 from the first frame: 69 px high, 47 frames airborne, fixed height.
- Air control identical to Super C: the last left/right pressed latches (±1.406), release keeps drifting,
  opposite reverses instantly, neutral jump goes straight up until steered.
- R = lock in place and aim 8 ways. Down = prone; down + left/right = run aiming down-diagonal.
- Death: knocked back with vy -4.125, vx 1.406 away from facing.

## Weapons (`$00:D6DC` dispatch, handlers via table `$00:D717`, behaviours via long table `$05:A0B4` by slot `+$10`)
- All bullets move `pos += vel` each frame (`$00:E1B8` loop over `$0AC0-$0FBF`, despawn at X >= $F8 or
  Y outside -$40..$EF). Velocities come from the 64-direction table (`$05:8D5A/8D7A/8DFA/8E1A`,
  16.16, 7.4 px/f, index 0 = up, clockwise).
- Cooldowns (`$05:A008`): default 3, S 4, C 5, H 4, F 1, L 1 frames; fire autorepeats while held.
- Damage (`+$06`): default 2, S 2, C 4 (+ debris 4), H 2, L 3 per segment, F 1 per segment.
- On hit: velocity reversed, damage 0, becomes spark type `$15` for 7 frames.
- Spread: 5 bullets at -22.5..+22.5 (11.25 steps); balls grow (3 sprites); needs 5 consecutive free slots.
- Crush: 3-slot groups (max 3), flies 16 frames or until it hits, then explodes in place 32 frames,
  spraying debris (±15 px random, 10-frame life, damage 4) into its 2 reserved slots.
- Flame: one 10-slot stream; head trails the muzzle (max 5 px/axis/frame); the aim angle is delayed
  along the chain so the stream bends; links ~15 px apart (`$05:8E9A/8F1A`).
- Laser: 9 segments laid out behind the head (16 px apart), appearing after 4..18 frames, all flying at 7.4.
- **Homing (the favourite):** see `weapons.H.pseudocode` in the asset and `homing_ref.py`. Key facts:
  max 5 (even slots, order 4,2,6,0,8), launch fan 0/±5.6/±11.25 degrees by slot, constant 7.4 px/f,
  steers every other frame by 16.9 degrees toward the target's hitbox centre via the ROM atan2,
  round-robin target selection (shared `$1646` pointer walks the enemy table: each steer takes the
  NEXT shootable enemy), keeps heading with no target, no lifetime, weaves ±1 step around a locked target.
  Validated: 1274/1294 recorded steering steps bit-exact.

## Smart bomb
A uses one (`$1F8C`). Centre = player position at use (~X+2, Y-20). Radius starts at 1, grows by a
speed that starts at 1.0 and gains 1/32 per frame, ends at 255 (~112 logic frames). Every other frame
it deals 1 damage to every shootable enemy overlapping the square centre ± radius. Visual: expanding
translucent yellow/red dome (colour math) plus fireballs.

## Sound (`scripts/contra3/s_sounds.lua` capture, `python tools/spc_clip.py list shots/contra3/sounds_capture.txt`)
- Konami driver, timer 0 target 32 = 250 Hz ticks (polled at SPC `$0959`). Sample directory `$5000`.
  Echo on (EDL 5, ESA `$D8`) for music voices only (EON `$07`/`$2F`); master volume `$7F/$7F`.
  No noise or pitch modulation. (The main CPU's APU-port writes didn't show up on a `$2140-$2143`
  write callback; not needed, the capture works from the DSP side.)
- **Gun sounds: voice 6, one key-on per shot**, two frames after the trigger, ADSR `$FFE0` (instant
  attack, held), GAIN `$B8`; the driver then sweeps pitch/volume each tick until a key-off. Autofire
  re-keys at the gun's rate (default every 3 frames). The flame sounds only while held, one key-on per
  16 frames. Samples (SRCN): default `$12` (2349 B, loops), S/C/F `$05` (117 B; different pitches),
  H `$03`, L `$07`. Lengths of a single shot: default 0.46 s, S 0.73, C 0.92, H 0.95, L 1.33, F 0.27.
- **Smart bomb: voices 6 + 7.** Voice 6 re-keyed every ~1.5 frames with rising pitch (sample `$0F`)
  for 2.1 s while voice 7 holds a tone (sample `$06`); then both play 8 booms ~18 frames apart
  (voice 6 sample `$01`, voice 7 `$0F`). About 4.3 s in all.

## Controls (defaults)
Y fire, B jump, A bomb, X switch weapon slot, R lock/aim. L+R spin not tested.

## Homing pseudocode (bit-exact; Python reference `scripts/contra3/homing_ref.py`)
```
spawn ($00:D97A): slot = first free of even slots 4,2,6,0,8 of $0AC0-$0BFF ($00:E134), else no shot
  dir2 = (aim*2 + ((($0C00 - slot) >> 5) - 6)) & $7E      ; launch fan 0, +2, -2, +4, -4 (half-steps)
  vel = dir_table[dir2/2] (7.4 px/f); pos = player + muzzle offset; type 4, damage 2, sprite $305E
every frame ($00:DE9C, called from the bullet loop $00:E1B8 in slot order):
  if hit flag (+$16): reverse vel, damage 0, type $15 spark 7 frames; return
  if $BC != 0: return                                     ; P1 steers on alternate frames
  y = $1646; repeat 34: if enemy[y]+$16 & $10 and enemy[y]+$06 >= 0 -> found
                         y += $40; if y >= $0AC0: y = $0280
  not found: $1646 = y; keep dir2
  found: $1646 = next(y); dx = ex + (w>>1) + (w&1) - mx - 1; dy = ey + (h>>1) + (h&1) - my   (16-bit, h < 0)
         target = (atan2_rom(dx, dy) >> 1) & $FE
         diff = (dir2 - target) signed 16: diff>=0 ? (diff<$40 ? -6 : +6) : (diff<-$40 ? -6 : +6)
         dir2 = (dir2 + step) & $7E
  vel = dir_table[dir2/2]; sprite = $05:A074[((dir2+8)&$7E)>>3 & $FE]
then pos += vel (16.16), despawn off screen
atan2_rom ($1D:ABA0, table $05:F694 = asset atan_table): see weapons.H.atan2 in the asset
```

## Verification status
- Homing: `homing_check.py` 1274/1294 steering steps bit-exact on a recorded stage 1 run (98.5%).
- Sprites: `test_atlas.py` (asset vs screenshot), see the format section.

## Remaining work (for whoever picks this up)
1. Flame (type 5/6, `$00:DA08-$DC3C`, `$00:DF62/$DF73`) and laser (types $0B/$0C/8, `$00:DC88`, `$00:E060-$E09F`) are
   described as behaviour notes, not line-by-line pseudocode. Read those routines if exact streams are wanted.
2. Spread/crush behaviours are from code reading, not checked against recordings like homing was.
3. Max fall speed, player hurtbox width, L / L+R behaviour: unmeasured.
4. Left-facing drawings (`$98xx/$9Cxx/$A1xx`) not exported; mirror the right-facing ones.
5. `test_atlas.lua` logs state every 3 frames; to verify moving poses, log state for the exact rendered frame.
6. Bomb dome visual (colour math) not captured; bomb fireball sprites not exported separately (crush explosion sprites are close).

## Caveats
- Left-facing poses are separate drawings; only right-facing ones are exported.
- Max fall speed not measured (no ledges in stage 1). Hurtbox width not measured.
- Bomb dome visuals are a screen effect and aren't in the atlas.
- Wall/ceiling climbing and top-down poses were ignored.
