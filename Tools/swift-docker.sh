#!/usr/bin/env bash
# Runs a swift command for the package in the current directory inside a
# memory-capped container. Serialised host-wide with flock: the build host is
# small and two concurrent Swift builds would exhaust its memory.
# Usage: Tools/swift-docker.sh swift test -j 1 --filter RoutingEngineTests
# NP_EXPORT_DIR, NP_EXPORT_LINK, NP_EXPORT_DNS and NP_UPDATE_FIXTURES are passed through when set (export tests write files
# for the Linux end-to-end run; the directory must be under the package, which is mounted at /work).
set -euo pipefail
exec flock /tmp/np-swift.lock nice docker run --rm --network none \
  --memory=1300m --memory-swap=1300m --cpus=1.5 \
  -e NP_EXPORT_DIR -e NP_EXPORT_LINK -e NP_EXPORT_DNS -e NP_UPDATE_FIXTURES \
  -v "$PWD":/work -w /work swift:5.10 "$@"
