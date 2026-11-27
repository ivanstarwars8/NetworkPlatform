#!/usr/bin/env python3
"""Summarises the JSON lines written by Cores/BuildScripts/bridge-tunlab.sh (bench, batch, profile).

Usage: summarize.py results.jsonl [more.jsonl ...] > summary.md

For every (label, test) group it reports median, p95 (nearest rank), min, max, standard deviation and the
coefficient of variation of each metric over the repeated runs, then the ratio of the bridge to stock xray.
Warm-up runs (label ending in -warmup) are ignored.
"""
import json
import math
import statistics
import sys
from collections import defaultdict


def pct(xs, p):
    xs = sorted(xs)
    i = max(0, math.ceil(p * len(xs)) - 1)
    return xs[i]


def describe(xs):
    m = statistics.median(xs)
    sd = statistics.stdev(xs) if len(xs) > 1 else 0.0
    return {
        "n": len(xs), "median": m, "p95": pct(xs, 0.95), "min": min(xs), "max": max(xs),
        "sd": sd, "cv": (sd / statistics.mean(xs) * 100) if statistics.mean(xs) else 0.0,
    }


def metrics_of(r):
    v, out = r.get("values", {}), {}
    if "mbps" in v:
        out["Mbit/s"] = v["mbps"]
    for k in ("p50us", "p95us", "p99us"):
        if k in v:
            out[k] = v[k]
    if "lost" in v:
        out["lost"] = v["lost"]
    p = r.get("proc")
    nbytes = v.get("bytes")
    if p:
        out["cpu s"] = p["cpuSec"]
        out["RSS peak MiB"] = p["rssPeak"] / 2**20
        if nbytes:
            out["cpu s/GiB"] = p["cpuSec"] / (nbytes / 2**30)
    b = r.get("bridge")
    if b:
        out["goroutines after"] = b["goroutinesAfter"]
        out["heap live MiB"] = b["heapLiveAfter"] / 2**20
        out["GC cycles"] = b["gcCycles"]
        if b["cpuSec"] > 0:
            out["GC cpu %"] = b["gcCPUSec"] / b["cpuSec"] * 100
        if b["tunPackets"]:
            out["allocs/packet"] = b["allocObjects"] / b["tunPackets"]
            out["alloc B/packet"] = b["allocBytes"] / b["tunPackets"]
            out["cpu us/packet"] = b["cpuSec"] / b["tunPackets"] * 1e6
        if nbytes:
            out["alloc KiB/MiB"] = b["allocBytes"] / 1024 / (nbytes / 2**20)
        pu = b.get("pump")
        if pu and pu["inBatches"]:
            out["pkts/write batch"] = pu["inPackets"] / pu["inBatches"]
        if pu and pu["outBatches"]:
            out["pkts/read batch"] = pu["outPackets"] / pu["outBatches"]
    return out


def fmt(x):
    if isinstance(x, float):
        if abs(x) >= 100:
            return f"{x:.0f}"
        if abs(x) >= 10:
            return f"{x:.1f}"
        return f"{x:.2f}"
    return str(x)


def main(paths):
    groups = defaultdict(lambda: defaultdict(list))
    failures = defaultdict(int)
    for path in paths:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                r = json.loads(line)
                label, test = r.get("label", ""), r.get("test", "")
                if label.endswith("-warmup") or "values" not in r or test in ("loadavg",):
                    continue
                if not r.get("ok", True):
                    failures[(label, test)] += 1
                    continue
                for k, x in metrics_of(r).items():
                    groups[(label, test)][k].append(float(x))
    print("| label | test | metric | n | median | p95 | min | max | sd | CV % |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    summary = {}
    for (label, test) in sorted(groups):
        for k, xs in groups[(label, test)].items():
            d = describe(xs)
            summary[(label, test, k)] = d
            print(f"| {label} | {test} | {k} | {d['n']} | {fmt(d['median'])} | {fmt(d['p95'])} | {fmt(d['min'])} "
                  f"| {fmt(d['max'])} | {fmt(d['sd'])} | {d['cv']:.1f} |")
    if failures:
        print("\nFailed runs (excluded):")
        for (label, test), n in sorted(failures.items()):
            print(f"- {label} {test}: {n}")
    # bridge vs stock, medians
    rows = []
    for (label, test, k), d in summary.items():
        for kind in ("reality", "ss"):
            for mode in ("flow", "fd"):
                if label.startswith(f"{kind}-{mode}"):
                    ref = (label.replace(f"{kind}-{mode}", f"{kind}-stock", 1), test, k)
                    if ref in summary and summary[ref]["median"]:
                        rows.append((label, test, k, d["median"] / summary[ref]["median"] * 100))
    if rows:
        print("\n| bridge label | test | metric | median, % of stock |")
        print("|---|---|---|---|")
        for label, test, k, ratio in sorted(rows):
            if k in ("Mbit/s", "p50us", "p95us", "p99us", "cpu s/GiB", "RSS peak MiB"):
                print(f"| {label} | {test} | {k} | {ratio:.1f} |")


if __name__ == "__main__":
    main(sys.argv[1:])
