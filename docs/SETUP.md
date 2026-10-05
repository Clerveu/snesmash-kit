# Setup (for the agent doing it)

Do these in order and confirm each with the user where they have to act. Work on the user's OS: the
original project ran on Windows; everything here is plain Python + Mesen and should work on Linux and
macOS too, but that path is less trodden, so verify with the smoke test rather than assuming.

## 1. Python
Python 3.10+ with Pillow and numpy: `pip install -r requirements.txt`. There's no standalone Lua
interpreter in this workflow; all Lua runs inside Mesen.

## 2. Mesen 2 (two copies)
Mesen 2 is a free multi-system emulator (NES, SNES, Game Boy/GBA, PC Engine, SMS/Game Gear,
WonderSwan) with a Lua API and a headless test runner. Official site: https://www.mesen.ca (source and
releases: https://github.com/SourMesen/Mesen2). SNESMASH used 2.1.1; newer should be fine, and the
smoke test will tell you. Follow the download page's requirements for the user's OS.

The user (or you, with permission) unzips it **twice** into the repo:
- `mesen/` is the copy the user plays with. In its Script Window settings, enable **"Allow access to
  I/O and OS functions"** (needed for `dofile`/`io.open`) and, for two-emulator ports, network access.
  Make sure a controller is mapped on port 1. For live-drive ports, turn off "single instance".
- `mesen_headless/` is for tests. Copy `config/mesen_headless_settings.json` to
  `mesen_headless/settings.json`; a `settings.json` next to the executable makes that copy portable
  (its own settings), with script I/O + network on, two SNES controllers and all-zero RAM at power-on
  (deterministic runs).

Both folders are git-ignored. `tools/run_headless.py` finds `mesen_headless/Mesen(.exe)` on its own;
otherwise set `MESEN_HEADLESS` or pass `--mesen`.

## 3. ROMs
The user's own dumps go in `ROMS/` (git-ignored). **Never download ROMs, never ask the user where to
get them, never commit them** (or savestates or extracted game assets) to a public repo. Note each
ROM's exact file name, region and revision in its game doc: addresses differ between revisions.

## 4. Smoke test
```
python tools/run_headless.py lua/recon/smoke_test.lua "ROMS/<any game>"
```
Then read `out/smoke/report.txt` (every check says OK) and look at `out/smoke/screen.png`. The report
also lists this Mesen build's memTypes, cpuTypes and `getState()` keys: use those names. If the run
times out with no output, the usual causes are the headless copy missing `settings.json` (no script
I/O) or a wrong path; `out/mesen_stdout.txt` has Mesen's own output.

Optional, for an SNES ROM: `python tools/screen_patch.py kit out/smoke/capture out/smoke/kit` proves
the Python graphics tools can read a capture.

## 5. Project layout
Create these as they're needed:
```
ROMS/                      user's ROM dumps (git-ignored)
mesen/  mesen_headless/    emulator copies (git-ignored)
out/                       scratch output: traces, screenshots, error log (git-ignored)
states/                    golden savestates (git-ignored by default; game RAM inside)
sources/<game>/            source-game recon + extraction scripts, build_*.py generators
assets/<game>/             generated from the ROM by build_*.py (never hand-edited)
art/<game>/<screen>/       hand-edited source art (the user's PNGs)
ports/<port>/              main.lua, host.lua (host adapter), guest controller, test_*.lua
docs/games/<game>.md       per-game facts (template: docs/templates/game.md)
docs/ports/<port>.md       per-port design, controls, status (template: docs/templates/port.md)
```
Start each new port by copying `lua/template/*.lua` into `ports/<port>/`.

## 6. Golden state
Write a boot script for the host game (scripted input from power-on until the player is in control,
then `savestate.save`), save to `states/<game>_stage1.mss`, and screenshot it so the user can confirm
it's the right place. Make one per stage once you know a stage-select code (PLAYBOOK 6).

## 7. Git
Initialise a repo for the user's project (or keep working in their clone of this kit). The
`.gitignore` already excludes ROMs, emulators, `out/` and `states/`. Commit at milestones, after tests
pass. If the user wants to share their work publicly, keep ROM-derived files (`assets/`, `states/`,
captures under `art/*/ref/`) out of it unless they decide otherwise.
