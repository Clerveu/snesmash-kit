"""Cut sound-effect clips out of an SPC/DSP capture (any SNES game).

Input: a capture from lua/lib/spc_log.lua (DSP register writes with SPC cycle stamps, APU port writes,
markers, a start snapshot of the 128 DSP registers) plus a dump of the 64 KB sound RAM taken in the same
run (the samples are read from it).

A clip is one voice from a key-on (KON) until it falls silent:
  - the voice's 8 registers at key-on (volume L/R, pitch, sample number, ADSR1/2, GAIN),
  - every later write to those registers, plus the voice's later key-ons/key-offs, stamped in DSP output
    samples (32 kHz) since the first key-on,
  - the samples (BRR) it plays, each trimmed to the part actually heard, with loop points.
To find "silent" and "heard", the voice is simulated: the ADSR/GAIN envelope (the DSP's rate table) and
the BRR read position (pitch $1000 = one source sample per output sample). A clip ends at the voice's next
key-on (or, for re-keyed effects, after the last key-on before `until_frame`), at envelope 0, or at the end
of a non-looping sample.

CLI:
  python tools/spc_clip.py list <capture.txt> [--voice N] [--from F] [--to F]   key-ons with their settings
Library: load_capture(), Capture.konlist(), Capture.extract(), clips_to_lua().
"""
import argparse
import sys

SPC_CYCLES_PER_SAMPLE = 64  # Mesen's spc.cycle runs at 2.048 MHz (34,036 per frame); DSP output is 32 kHz
# S-DSP envelope rate table: samples between steps for rate 0..31 (rate 0 = never)
RATES = [0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80, 64, 48, 40, 32,
         24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1]
REG_NAMES = ["VOLL", "VOLR", "PITCHL", "PITCHH", "SRCN", "ADSR1", "ADSR2", "GAIN"]
KON, KOF = 0x4C, 0x5C


class Capture:
    def __init__(self, path, aram_path):
        self.events = []  # (kind, frame, cycle, a, b)
        self.snapshot = [0] * 128
        for line in open(path):
            p = line.split()
            if not p:
                continue
            if p[0] == "S":
                h = p[3]
                self.snapshot = [int(h[i:i + 2], 16) for i in range(0, 256, 2)]
            elif p[0] == "D":
                self.events.append(("D", int(p[1]), int(p[2]), int(p[3], 16), int(p[4], 16)))
            elif p[0] == "P":
                self.events.append(("P", int(p[1]), None, int(p[2], 16), int(p[3], 16)))
            elif p[0] == "M":
                self.events.append(("M", int(p[1]), None, " ".join(p[2:]), None))
        self.aram = open(aram_path, "rb").read()

    def marks(self):
        return [(e[1], e[3]) for e in self.events if e[0] == "M"]

    def mark_frame(self, text):
        for f, t in self.marks():
            if t == text:
                return f
        raise KeyError(text)

    def konlist(self, voice=None, f0=0, f1=1 << 30):
        """Every key-on in [f0, f1): dicts with frame, cycle, voice, the voice's regs at KON, DIR, flags."""
        out = []
        regs = list(self.snapshot)
        for i, e in enumerate(self.events):
            if e[0] != "D":
                continue
            _, f, c, r, v = e
            regs[r] = v
            if r == KON and f0 <= f < f1:
                for vv in range(8):
                    if v >> vv & 1 and (voice is None or vv == voice):
                        out.append({"frame": f, "cycle": c, "voice": vv, "index": i,
                                    "regs": regs[vv * 16:vv * 16 + 8], "dir": regs[0x5D] << 8,
                                    "eon": regs[0x4D] >> vv & 1, "non": regs[0x3D] >> vv & 1,
                                    "pmon": regs[0x2D] >> vv & 1})
        return out

    def dir_entry(self, dirbase, srcn):
        a, o = self.aram, dirbase + srcn * 4
        return a[o] | a[o + 1] << 8, a[o + 2] | a[o + 3] << 8

    def brr(self, start):
        """Blocks of a BRR sample from start through the end-flag block: list of 9-byte bytes."""
        blocks, p = [], start
        while p + 9 <= 0x10000:
            b = self.aram[p:p + 9]
            blocks.append(b)
            p += 9
            if b[0] & 1:
                break
        return blocks

    def extract(self, kon, until_frame=None, max_samples=32000 * 8):
        """Cut the clip that starts at key-on `kon` (an entry of konlist).

        until_frame=None: one key-on; the clip ends at the voice's next key-on or when it falls silent.
        until_frame=F: later key-ons of the voice up to frame F belong to the clip (a re-keyed effect,
        e.g. a burst); it ends when the voice is silent after the last of them."""
        v = kon["voice"]
        base = v * 16
        regs0 = list(kon["regs"])

        # later writes to this voice (registers 0-7) plus its key-ons and key-offs
        writes = []
        for e in self.events[kon["index"] + 1:]:
            if e[0] != "D":
                continue
            _, f, c, r, val = e
            t = (c - kon["cycle"]) // SPC_CYCLES_PER_SAMPLE
            if t > max_samples:
                break
            if r == KON and val >> v & 1:
                if until_frame is None or f > until_frame:
                    break
                writes.append((t, KON, 1))
            elif r == KOF and val >> v & 1:
                writes.append((t, KOF, 1))
            elif base <= r < base + 8:
                writes.append((t, r - base, val))
        last_key = max([i for i, w in enumerate(writes) if w[1] == KON], default=-1)

        samples = {}  # srcn -> sample info, with the furthest block read

        def sample(srcn):
            if srcn not in samples:
                start, loop = self.dir_entry(kon["dir"], srcn)
                blocks = self.brr(start)
                loops = bool(blocks[-1][0] & 2)
                samples[srcn] = {"start": start, "loop": loop, "blocks": blocks, "loops": loops,
                                 "loop_block": (loop - start) // 9 if loops else None, "max_block": 0}
            return samples[srcn]

        regs = list(regs0)
        cur = sample(regs[4])
        wi, env, mode, pos, blk = 0, 0, "attack", 0, 0
        kon_delay, playing = 5, True
        end_t, ended_by = None, "limit"
        for t in range(max_samples):
            while wi < len(writes) and writes[wi][0] <= t:
                _, r, val = writes[wi]
                wi += 1
                if r == KON:  # re-key: restart envelope and sample
                    cur = sample(regs[4])
                    env, mode, pos, blk, kon_delay, playing = 0, "attack", 0, 0, 5, True
                elif r == KOF:
                    mode = "release"
                else:
                    regs[r] = val
            more_keys = wi <= last_key
            if not playing:
                if not more_keys:
                    end_t = t
                    break
                continue
            if kon_delay:
                kon_delay -= 1
                continue
            env, mode = _env_step(env, mode, regs, t)
            pos += (regs[2] | regs[3] << 8) & 0x3FFF
            while pos >= 16 * 4096:  # one BRR block = 16 source samples
                pos -= 16 * 4096
                if cur["blocks"][blk][0] & 1:  # end flag
                    if cur["loops"]:
                        blk = cur["loop_block"]
                    else:
                        playing, ended_by = False, "sample end"
                        break
                else:
                    blk += 1
                cur["max_block"] = max(cur["max_block"], blk)
            if playing and env == 0 and mode in ("release", "decay", "sustain", "gain"):
                playing, ended_by = False, "silent"
            if not playing and not more_keys:
                end_t = t
                break
        if end_t is None:
            end_t = max_samples

        out_samples = {}
        for srcn, sm in samples.items():
            blocks = sm["blocks"]
            whole = sm["loops"] and sm["max_block"] >= sm["loop_block"]
            # keep one block past the last one read (the DSP decodes ahead for interpolation)
            keep = blocks if whole else blocks[:min(len(blocks), sm["max_block"] + 2)]
            data = bytearray(b"".join(keep))
            if whole:
                loop_off = sm["loop"] - sm["start"]
            else:
                data[len(data) - 9] = (data[len(data) - 9] | 1) & ~2  # end flag, no loop
                loop_off = None
            out_samples[srcn] = {"brr": bytes(data), "loop": loop_off, "full": len(blocks) * 9}
        # drop writes that don't change the register (drivers refresh volume/pitch every tick)
        events, cur_regs = [], list(regs0)
        for w in writes:
            if w[0] > end_t:
                break
            if w[1] < 8:
                if cur_regs[w[1]] == w[2]:
                    continue
                cur_regs[w[1]] = w[2]
            events.append(w)
        kofs = [w[0] for w in events if w[1] == KOF]
        return {
            "voice": v, "frame": kon["frame"], "regs": regs0, "srcn": regs0[4],
            "samples": out_samples, "events": events,
            "kof": kofs[0] if kofs else None, "keys": 1 + sum(1 for w in events if w[1] == KON),
            "length": end_t, "ended_by": ended_by,
            "eon": kon["eon"], "non": kon["non"], "pmon": kon["pmon"],
        }


def _env_step(env, mode, regs, t):
    """One output sample of the S-DSP envelope. Counter phase is ignored (step on t % period)."""
    def tick(rate):
        p = RATES[rate]
        return p and t % p == 0

    if mode == "release":
        return max(0, env - 8), mode
    adsr1, adsr2, gain = regs[5], regs[6], regs[7]
    if adsr1 & 0x80:
        if mode == "gain":
            mode = "attack"
        sl = (adsr2 >> 5) + 1
        if mode == "attack":
            rate = (adsr1 & 0x0F) * 2 + 1
            if tick(rate):
                env += 1024 if rate == 31 else 32
            if env >= 0x7FF:
                env, mode = 0x7FF, "decay"
        elif mode == "decay":
            if tick(((adsr1 >> 4) & 7) * 2 + 16):
                env -= ((env - 1) >> 8) + 1
            if (env >> 8) < sl:
                mode = "sustain"
        else:
            if tick(adsr2 & 0x1F):
                env -= ((env - 1) >> 8) + 1
        return max(0, env), mode
    mode = "gain"
    if not gain & 0x80:
        return (gain & 0x7F) * 16, mode
    if tick(gain & 0x1F):
        kind = (gain >> 5) & 3
        if kind == 0:
            env -= 32
        elif kind == 1:
            env -= ((env - 1) >> 8) + 1
        elif kind == 2:
            env += 32
        else:
            env += 32 if env < 0x600 else 8
    return max(0, min(0x7FF, env)), mode


def load_capture(path, aram_path):
    return Capture(path, aram_path)


def clips_to_lua(clips, header):
    """clips: list of (name, clip). Lua source returning {clips = {name = clip}, samples = {srcn = ...}}.
    Samples are keyed by source sample number; if clips trim the same sample differently, the longest
    cut wins (it contains the shorter ones)."""
    samples = {}
    for _, c in clips:
        for srcn, sm in c["samples"].items():
            if srcn not in samples or len(sm["brr"]) > len(samples[srcn]["brr"]):
                samples[srcn] = sm
    out = [header.rstrip() + "\n", "return {\n", "  clips = {\n"]
    for name, c in clips:
        r = c["regs"]
        sizes = ", ".join(f"#{k:02X} {len(v['brr'])}/{v['full']} bytes" for k, v in sorted(c["samples"].items()))
        out.append(f"    [\"{name}\"] = {{\n")
        out.append(f"      -- source: voice {c['voice']}, frame {c['frame']}, {c['keys']} key-on(s), samples {sizes};\n"
                   f"      -- {c['length']} samples ({c['length'] / 32000:.3f} s, ends: {c['ended_by']})\n")
        out.append("      regs = { " + ", ".join(f"0x{x:02X}" for x in r) + " }, -- " + " ".join(REG_NAMES) + "\n")
        out.append(f"      length = {c['length']},\n")
        out.append("      -- {samples since the first key-on, register 0-7 (or 0x4C key-on, 0x5C key-off), value}\n")
        out.append("      events = {\n")
        ev = c["events"]
        for i in range(0, len(ev), 6):
            out.append("        " + " ".join(f"{{{t}, 0x{rr:02X}, 0x{v:02X}}}," for t, rr, v in ev[i:i + 6]) + "\n")
        out.append("      },\n    },\n")
    out.append("  },\n")
    out.append("  samples = { -- source sample number -> BRR (9-byte blocks) as hex, loop offset in bytes or nil\n")
    for srcn, sm in sorted(samples.items()):
        loop = sm["loop"] if sm["loop"] is not None else "nil"
        out.append(f"    [0x{srcn:02X}] = {{ loop = {loop}, -- {len(sm['brr'])} of {sm['full']} bytes\n")
        hx = sm["brr"].hex().upper()
        for i in range(0, len(hx), 144):
            out.append(f"      {'brr = ' if i == 0 else '   .. '}\"{hx[i:i + 144]}\"\n")
        out.append("    },\n")
    out.append("  },\n}\n")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list")
    ls.add_argument("capture")
    ls.add_argument("--aram")
    ls.add_argument("--voice", type=int)
    ls.add_argument("--from", dest="f0", type=int, default=0)
    ls.add_argument("--to", dest="f1", type=int, default=1 << 30)
    a = ap.parse_args()
    aram = a.aram or a.capture.replace("_capture.txt", "_aram.bin")
    cap = Capture(a.capture, aram)
    marks = cap.marks()
    for k in cap.konlist(a.voice, a.f0, a.f1):
        m = [t for f, t in marks if f <= k["frame"]]
        c = cap.extract(k)
        r = k["regs"]
        sm = c["samples"][r[4]]
        print(f"f{k['frame']:5d} v{k['voice']} srcn {r[4]:02X} pitch {r[3] << 8 | r[2]:04X} vol {r[0]:02X}/{r[1]:02X} "
              f"adsr {r[5]:02X}{r[6]:02X} gain {r[7]:02X}  len {c['length']:6d} ({c['ended_by']}) "
              f"brr {len(sm['brr'])}/{sm['full']} ev {len(c['events'])} kof {c['kof']}  [{m[-1] if m else ''}]")


if __name__ == "__main__":
    sys.exit(main())
