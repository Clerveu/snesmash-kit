# Super C (NES, US) — Bill as a portable character

> From the SNESMASH project, copied as-is (USA ROMs). Paths to scripts, `states/`, `shots/` and assets refer
> to that project's private repo, not this kit; the addresses, findings and methods are what's useful here.
> Verify against your own ROM revision before relying on an address.

ROM: `ROMS/Super C.nes` (iNES, mapper 4 / MMC3, 128 KiB PRG in 16 × 8 KiB banks, 128 KiB CHR).
Primary reference: the annotated disassembly **github.com/vermiceli/nes-super-c** (labels below
are from it, mostly `src/bank-0.asm`, `bank-6.asm`, `ram.asm`). It matched every RAM value I
measured, so trust it before re-deriving anything. It also ships Mesen 2 Lua scripts
(`docs/lua_scripts/mesen2`) and PNGs of every sprite (`docs/sprite_library`).

## Assets (rebuild with `python scripts/superc/build_bill.py`, needs only the ROM)

| File | What |
|---|---|
| `assets/superc/bill_frames.lua` | `dofile()` → one table: palette, frames, bullets, anims, physics, aim, weapons, ram |
| `assets/superc/bill_atlas.png` / `.json` | contact sheet of every frame for review (anchor cross-hair drawn) |
| `scripts/superc/test_atlas.lua` | headless proof: draws the asset Bill 48 px beside the real one in Super C |

The frames come straight from the ROM metasprite tables (not screen captures), so every pose
exists even if a capture run never reached it. CHR = level 1 sprite banks $44-$47
(`rom offset = 0x20010 + bank*0x400`); player, bullet and pickup tiles live in $44-$46, which
most levels share.

### Anchor convention (all frames)
- `ax` = Bill's X (`PLAYER_SPRITE_X_POS` $054C, the X he's drawn around).
- `ay` = **ground line**: the first row below his feet = `PLAYER_SPRITE_Y_POS` ($0532) + 19.
  Standing/running/prone frames all have their last pixel row at `ay - 1`.
- Pixel `(col, row)` of a frame goes to screen `(ax - ox + col, ay - oy + row)`.
- Facing left (NES flips each tile and mirrors X as `-x-8`): screen x = `ax + ox - 1 - col`.
  For a run `{x, y, len, c}`: left edge = `ax + ox - x - len`.
- Jump/death frames stay in the same frame of reference, so a simulated Bill only tracks `(ax, ay)`;
  the spin ball is drawn ~22-41 px above `ay`, exactly as the game does.
- Bullets/items: anchor = the object's own position (`PLAYER_BULLET_X/Y_POS`); same formula.

### Lua data format
```lua
local B = dofile(".../bill_frames.lua")
B.palette[i]            -- "RRGGBB" for pixel value i = 1..12 (0 = transparent)
B.frames.stand          -- {w, h, ox, oy, code, rows = {"0064..",...}, runs = {x,y,len,c, x,y,len,c, ...}}
B.bullets.bullet_spray  -- same shape; also lasers, flame balls, hit puff, pickups (item_M ...)
B.anims.run             -- { {"run_0",6}, {"run_1",6}, ... }  duration in frames, 0 = hold
B.physics, B.weapons    -- constants below
B.aim[id + 1]           -- PLAYER_AIM_DIR id 0..12 → {name, dx, dy (from ax/ay), dir32, flip}
```
`rows` are hex digit strings (one char per pixel); `runs` is the flat run-length list to feed
`emu.drawRectangle(x, y, len, 1, color, true)` per run. Palette values: 1-3 = sprite palette 0
(Bill's legs: skin $37, teal $1C, black $0F), 4-6 = palette 1 (torso: skin, red $16, black; also
pickups), 7-9 = palette 2 (bullets: white $20, salmon $26, red $16). RGB = Mesen 2's default NES
palette (verified: 292/293 of Bill's pixels in a Mesen screenshot match exactly).

### Frame list
run_0..run_5 (gun lowered), runshoot_* (gun level, while recoil timer runs), stand, stand_shoot,
runup_* / rundown_* (diagonal aim while running), up, up_shoot, prone, prone_shoot,
crouch / crouch_shoot (inclines), jump_0..3 (spin), death_0..3, dead, water* (level 3/5 water).
Run cycle uses 5 distinct drawings: index sequence 0,1,2,3,1,5 (frame 4 reuses 1).
Bullets: bullet_regular (default gun), bullet_flame (M and F's first 4 frames), bullet_spray (S),
laser_h / laser_v / laser_diag_up / laser_diag_down, flame_ball, flame_ball_big, bullet_hit,
item_capsule, item_M/S/L/F/R/B, item_falcon.

## RAM map (player 1; player 2 is +1 for zero-page pairs)

| Addr | Name | Notes |
|---|---|---|
| $A0 | PLAYER_STATE | 2 alive, 3 hit, 4 falling back, 5 dead on ground, 6/7 level 1 heli drop |
| $A2/$A4 | Y/X fractional accumulators | |
| $A6/$A8 | Y velocity fract / int | signed 8.8, + = down |
| $AA/$AC | X velocity fract / int | |
| $AE | PLAYER_JUMP_STATUS | 0 ground, $40 walked off edge, $80 jumping / knocked back |
| $B0 | JUMP_INPUT | latched left/right used for air X velocity |
| $B2 | PLAYER_SURFACE | 0 air, 1 drop-through platform, 2 solid, 4 water, 6-$B inclines |
| $B4/$B6 | anim frame index / timer | |
| $B8 | PLAYER_CURRENT_WEAPON | 0 regular, 1 M, 2 S, 3 L, 4 F; bit 7 = rapid (R). **Write to force a weapon.** |
| $BA | PLAYER_AIM_DIR | 0 up(R) 1 up-right 2 right 3 down-right 4 crouch-incline 5 prone(R) 6 air-down 7 prone(L) 8 9 down-left 10 left 11 up-left 12 up(L) |
| $BC | PLAYER_RECOIL_TIMER | 5 after a standing shot, $11 walking; drives *_shoot poses |
| $BE | M fire timer | |
| $C0 | state timer | death: lie $60 frames |
| $C4 | NEW_LIFE_INVINCIBILITY_TIMER | respawn invulnerability; Bill **blinks** (sprite 0 on odd frames) |
| $C6 | PLAYER_ACTION_STATE | $FF normal, $1F jumping, $3F prone, $5F incline crouch, $7F water |
| $C8 | F_WEAPON_CHARGE | counts to $20 |
| $CC/$CE | PLAYER_X_POS / Y_POS | copies; `$CE` = sprite Y |
| $D4 | INVINCIBILITY_TIMER | B barrier (−1 per 8 frames). **Write $FF for invincibility** (palette flashes, no blink) |
| $0518 | PLAYER_SPRITE | metasprite code → `player_sprite_ptr_tbl`; matches `frames.*.code` |
| $0532 / $054C | PLAYER_SPRITE_Y_POS / X_POS | the anchor source |
| $0566 | PLAYER_SPRITE_ATTR | bit 6 = facing left, bits 0-1 palette |
| $0568-$0577 | bullet sprite code (8 slots P1, 8 P2) | bullet tables are 16 bytes each: Y $0578, X $0588, attr $0598, state $05A8 (0 free 1 flying 2 hit 3 laser waiting), weapon $05B8, timer $0628, vel X $0608/$0618, vel Y $05E8/$0658 |
| $53 | lives P1 | |
| $1B | FRAME_COUNTER | |
| $FD / $FC | X / Y scroll | |

Gotcha: the general sprite buffer $0500-$0567 is refilled with only half of the bullets each
frame (flicker by design), so read bullets from the $0568+ tables, not $0500.

## Physics (bank-0 `player_handle_movement`; all measured values agreed)
- Run: exactly **1.0 px/frame**, no acceleration or skid (0.875 on inclines). Facing = last L/R.
- Jump: initial vy **−4.0625** ($FBF0), gravity **+0x23/256 = 0.1367 px/f²** applied the same frame
  (first frame rises 3.93), max fall **5.0**. Height **58 px**, airtime **57 frames** on flat ground.
  **Fixed height** (holding A changes nothing). Spin ball the whole way.
- Air control: X velocity is ±1.0 from `JUMP_INPUT`, set at takeoff from the d-pad and overwritten
  whenever left/right is held in the air. A neutral jump goes straight up until you press a
  direction; releasing keeps drifting; pressing the other way reverses instantly (full turnaround,
  no inertia). Facing follows.
- Walk off a ledge: `JUMP_STATUS=$40`, pose run_0, same latched air control, same gravity.
- Drop through: down + A on a floating platform (`SURFACE=1`): Y += 16, then fall like walking off.
- Up/down alone stop you (aim up / prone). Diagonals keep running at 1.0.
- Death: vy −2.25, gravity 0.125, max fall 4, vx 1.25 away from facing; frames every 6; lie $60.
- Screen: can't go left of x $14 or right of $EC; screen scrolls once Bill passes x $80.
- Hurtbox vs a point-sized enemy (bank-3 `collision_box_tbl` row 0), relative to `(ax, ay)`:
  normal x −9..12, y −39..3; jumping x −11..14, y −30..−5; prone x −19..22, y −18..3.
  (Bigger enemies use other rows; this is the "Bill is small" baseline.)

## Weapons (bank-0 `handle_weapon_fire`, `init_player_bullet`, `handle_player_bullet`)
Bullet velocity tables are 32-direction (11.25° steps): `v = speed·(cos a, sin a)`, a = dir32·11.25°
clockwise from right. Speeds: code 0 = 4.0, code 1 = 5.5, code 2 = 7.0 px/frame. R adds +1 code
(max 2), lasers ignore it. All bullets do 1 damage (charged F: 5). On side-view stages bullets have
no range limit; they die off screen, on walls, or on hit (6-frame `bullet_hit` puff). Bullet vs
point enemy hitbox ≈ ±12 px. Spawn points come from `bullet_pos_dir_tbl` (in `B.aim`, from the
ground-line anchor): right (8, −21), up-right (6, −32), up (2, −35), down-right (8, −16),
prone (8, −8), air-down (0, −15); left side mirrored.

| Weapon | Speed | Max on screen | Trigger | Shape |
|---|---|---|---|---|
| Regular | 4.0 | 4 | press | single |
| M | 4.0 | 6 | **hold**: fires at once, then every 7 frames | single |
| S | 4.0 | 10 | press | 5 bullets at 0, ±11.25°, ±22.5° |
| L | 4.0 | 5 (one beam) | press (holding refires once the beam is gone) | 5 segments released after 1,3,5,7,9 frames → ~40 px beam; a new shot erases the old beam |
| F | 5.5 | 2 | press; hold 32 f and release = charged | fireball (bullet_flame 4 f, then flame_ball); on hitting an enemy/wall it splits into 4 child flames (diagonals) living 10 frames at 4.0. Charged: speed 7, damage 5, grows to flame_ball_big after 12 f, splits into 8 |
| R | — | — | pickup | bullet speed +1 code |
| B | — | — | pickup | barrier timer $D4: invincible, touching kills, palette flashes |

Firing sets the recoil timer (5 standing / $11 walking) which selects the *_shoot pose.
Note: Super C's F is **not** Contra's corkscrew flame; it's the splitting fireball.
Fire sounds: `sound_0b` regular, `0c` M, `0e` S, `0d` L, `0f` F (`player_bullet_fire_sound_tbl`).

## Measuring / capture harness (Super C specifics)
- Boot: mash Start from frame 100-400; Bill drops from the helicopter and lands ~frame 650;
  `rec.lua` starts plans at frame 700. Level 1 has soldiers spawning constantly: hold `$D4=$FF`
  (barrier) or `$C4` (respawn timer, blinks) and `$53` (lives) every frame.
- `scripts/superc/rec.lua` + `s_*.lua`: input plans, per-frame dump of RAM (2 KiB) + OAM + palette
  RAM + 8 KiB PPU pattern memory to `shots/superc/<name>.bin`; `sc.py` loads it into numpy.

## Uncertain / not done
- Water and incline poses/aim spawn offsets are exported but unverified in-game (level 1 has none).
- Hurtbox numbers are hand-decoded from `collision_box_tbl` row 0 (off-by-one possible).
- Pickup palettes assumed = sprite palette 1 (looks right in the atlas; not checked on screen).
- Overhead-stage (levels 2/6) sprites and physics deliberately skipped.
