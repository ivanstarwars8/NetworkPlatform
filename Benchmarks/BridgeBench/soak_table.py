#!/usr/bin/env python3
"""Summarises soak-samples-*.jsonl of bridge-tunlab.sh soak: one row per N samples and the plateau.

Usage: soak_table.py samples.jsonl [every=6] [plateau_from_minute=10]
"""
import json
import sys

MiB = 1 << 20


def main():
    path = sys.argv[1]
    every = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    plateau_from = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
    rows = [json.loads(line) for line in open(path) if line.strip()]
    rows = [r for r in rows if r.get("bridge")]
    if not rows:
        print("no bridge samples")
        return
    t0 = rows[0]["timeUnixMs"]
    print("| min | RSS MiB | RssAnon MiB | RssFile MiB | heap live MiB | mapped MiB | stacks MiB | goroutines | flows |")
    print("|---|---|---|---|---|---|---|---|---|")
    for i, r in enumerate(rows):
        if i % every and i != len(rows) - 1:
            continue
        b = r["bridge"]
        m = b["memory"]
        tun = b.get("tun") or {}
        print("| %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %d | %s |" % (
            (r["timeUnixMs"] - t0) / 60000, r["rssBytes"] / MiB, r.get("rssAnonBytes", 0) / MiB,
            r.get("rssFileBytes", 0) / MiB, m["heapLive"] / MiB, m["mapped"] / MiB, m["stacks"] / MiB,
            m["goroutines"], tun.get("flowsActive", "-")))
    plateau = [r for r in rows if (r["timeUnixMs"] - t0) / 60000 >= plateau_from]
    if plateau:
        def rng(f):
            v = [f(r) for r in plateau]
            return "%.1f-%.1f" % (min(v), max(v))
        print()
        print("plateau (>= %.0f min, %d samples): RSS %s MiB, RssAnon %s MiB, heap live %s MiB, goroutines %s" % (
            plateau_from, len(plateau), rng(lambda r: r["rssBytes"] / MiB), rng(lambda r: r.get("rssAnonBytes", 0) / MiB),
            rng(lambda r: r["bridge"]["memory"]["heapLive"] / MiB),
            rng(lambda r: r["bridge"]["memory"]["goroutines"])))
        last = rows[-1]["bridge"]
        print("cpu user+sys %.1f s, gc cycles %d, gc cpu %.1f s" % (
            last["cpuUserSec"] + last["cpuSysSec"], last["memory"]["gcCycles"], last.get("gcCPUSec", 0)))


if __name__ == "__main__":
    main()
