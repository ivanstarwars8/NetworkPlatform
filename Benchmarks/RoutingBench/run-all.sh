#!/usr/bin/env bash
# Runs the RoutingBench series inside the build container (one process per
# table size) and stores the reports under Benchmarks/results/<label>/.
# Run from the repository root:
#   Tools/swift-docker.sh bash Benchmarks/RoutingBench/run-all.sh <label> [repeats]
# The executable must have been built first:
#   Tools/swift-docker.sh swift build -c release -j 1 --product RoutingBench
# BENCH=<path> runs another build of the executable (used for before/after).
set -uo pipefail
label="${1:?label}"
repeats="${2:-3}"
out="Benchmarks/results/$label"
mkdir -p "$out" Logs
bench="${BENCH:-.build/release/RoutingBench}"
run() { # rules queries suffix extra...
  local rules="$1" queries="$2" suffix="$3"; shift 3
  for i in $(seq 1 "$repeats"); do
    "$bench" --rules "$rules" --queries "$queries" --seed 1 "$@" \
      --json "$out/routing-bench-$rules$suffix-run$i.json" >/dev/null 2>>"Logs/bench-$label.err"
    echo "rules=$rules$suffix run=$i exit=$?" | tee -a "Logs/bench-$label.err"
  done
}
run 1000 200000 ""
run 10000 100000 ""
run 100000 20000 ""
run 1000000 1000 ""
run 100000 20000 "-noregex" --without-regex
run 1000000 1000 "-noregex" --without-regex
