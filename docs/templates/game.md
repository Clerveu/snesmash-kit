# <Game title> (<console>, <region>): <host | source> notes

ROM: `ROMS/<file name>` (<size>, LoROM/HiROM, header yes/no, revision). Addresses are <memType>
(`emu.memType.<name>`) unless noted. Sources: <disassembly / cheat codes / own traces>. Mark anything
unverified as "guess".

## Getting to gameplay
- Boot route and frame counts to "player in control"; golden states (`states/...`) and how they're made.
- Stage select (code / RAM byte) and its caveats (warp states valid until the first death?).
- **In-gameplay test**: <expression>. Writers (write-watch): <PC list>. Checked in: <stages, deaths,
  reloads, intro, demo>. Traps: <bytes that looked right but weren't>.
- Player in control (intro / READY / cutscene detection): <how>.

## Player
| Field | Address | Width | How found | Verified |
|---|---|---|---|---|
| X / Y | | | | |
| speed / direction | | | | |
| state enum | | | | |

State enum values (from transition logging): ...

## Camera and drawing
- Camera X/Y; screen position formula; verified against OAM in stages: ...
- Player sprites: OBJ palette, tile range, OAM slots, priority per stage, OBSEL (base/offset/mode).
- Free OBJ tiles / palettes (survey of every stage).

## Objects
- Table base, slot stride, slot count, field offsets (+$00 active, +$03 routine pointer, ...).
- Allocator: routine address, free stack / index (exact width), per-type counts, free routine.
- Draw flag, damage, HP, vulnerable bit, despawn lines.

## Sound (if needed)
- Sound request routine/queue; APU port protocol; driver timer + period; voices used by effects;
  free sound RAM (proven by watch); spare sample-directory entries.

## Quirks
- Anything that broke an assumption, with the date found.
