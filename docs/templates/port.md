# Port: <Guest> (<source game>) in <host game>

| Entry script | Host notes | Source notes | Assets |
|---|---|---|---|
| `ports/<port>/main.lua` | `docs/games/<host>.md` | `docs/games/<source>.md` | `assets/<source>/...` (rebuild: `python sources/<source>/build_*.py`) |

## What the guest brings, what the host keeps
| From <source> | Kept from <host> |
|---|---|
| sprite + poses | level collision |
| run speed, jump, air control | health / lives / score |
| attacks | enemies, bosses, drops |
| sounds | music |

## Controls
- ...

## How it works
- `host.lua`: host adapter (every address).
- `<guest>.lua`: controller (pad + host state -> pose, physics numbers, attacks).
- `main.lua`: inputPolled (controller, filtered pad, physics overrides); startFrame (drawing).
- What happens outside gameplay, during intros, during host transformations.

## Tuning knobs
- Constants and where they live.

## Tests
| Script | Checks |
|---|---|
| `test_tour.lua` | ... |

## Handoff (keep current: this is where the next session starts)
- Done and verified (how):
- In progress:
- Next, in the user's priority order:
- Known bugs / open questions:
