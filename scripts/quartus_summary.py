#!/usr/bin/env python3
"""Concise summary of the last Quartus compile of the Crystal core.

Prints PASS/FAIL, errors from the flow log, fitter resource usage, the worst setup/hold slack per clock from the
TimeQuest summary and the RBF path. Used by scripts/build.ps1; can be run on its own after a GUI compile.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "output_files"
REV = "Crystal"


def read(p):
    try:
        return p.read_text(errors="replace")
    except OSError:
        return ""


def main():
    ok = True
    flow = read(ROOT / "build" / "quartus_flow.log")
    errors = [l for l in flow.splitlines() if l.startswith("Error")]
    if errors:
        ok = False
        print("ERRORS:")
        for l in errors[:20]:
            print("  " + l)

    fit = read(OUT / f"{REV}.fit.summary")
    for key in ("Fitter Status", "Logic utilization", "Total registers", "Total block memory bits",
                "Total RAM Blocks", "Total DSP Blocks", "Total PLLs"):
        m = re.search(rf"^{re.escape(key)}\s*:\s*(.*)$", fit, re.M)
        if m:
            print(f"{key:26s}: {m.group(1).strip()}")
    if "Fitter Status : Successful" not in fit:
        ok = False

    sta = read(OUT / f"{REV}.sta.summary")
    worst = {}
    for block in sta.split("\n\n"):
        t = re.search(r"Type\s*:\s*(.*)", block)
        s = re.search(r"Slack\s*:\s*(-?[\d.]+)", block)
        n = re.search(r"TNS\s*:\s*(-?[\d.]+)", block)
        if t and s:
            kind = t.group(1).strip()
            print(f"  {kind:70s} slack {float(s.group(1)):8.3f} TNS {float(n.group(1)) if n else 0:9.3f}")
            if float(s.group(1)) < 0 and ("Setup" in kind or "Hold" in kind):
                worst[kind] = float(s.group(1))
    if worst:
        print("TIMING: negative slack in", len(worst), "analyses")

    rbf = OUT / f"{REV}.rbf"
    if rbf.exists():
        print(f"RBF: {rbf} ({rbf.stat().st_size} bytes)")
    else:
        ok = False
        print("RBF: missing")
    print("QUARTUS:", "PASS" if ok else "FAIL", "(timing:", "MET)" if not worst else "VIOLATED)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
