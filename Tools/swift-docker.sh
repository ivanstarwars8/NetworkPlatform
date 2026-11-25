#!/usr/bin/env bash
# Runs a swift command for the package in the current directory inside a
# memory-capped container. Serialised host-wide with flock: the build host is
# small and two concurrent Swift builds would exhaust its memory.
# Usage: Tools/swift-docker.sh swift test -j 1 --filter RoutingEngineTests
set -euo pipefail
exec flock /tmp/np-swift.lock nice docker run --rm --network none \
  --memory=1300m --memory-swap=1300m --cpus=1.5 \
  -v "$PWD":/work -w /work swift:5.10 "$@"
