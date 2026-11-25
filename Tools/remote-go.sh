#!/usr/bin/env bash
# Syncs the current checkout to the Go build host and runs a command there.
# Usage: NP_REMOTE=host NP_KEY=bridge Tools/remote-go.sh 'cd Cores/Bridge && go test ./...'
# Builds are serialised with flock and niced; Go caches live under the build
# root so the host's own Go setup is untouched.
set -euo pipefail
: "${NP_REMOTE:?set NP_REMOTE to the ssh host}"; : "${NP_KEY:?set NP_KEY to a short workspace name}"
ROOT=/root/np-build
ssh -o BatchMode=yes "$NP_REMOTE" "mkdir -p $ROOT/$NP_KEY $ROOT/cache"
rsync -az --delete --exclude .git --exclude .build --exclude Logs --exclude '*.prof' ./ "$NP_REMOTE:$ROOT/$NP_KEY/"
ssh -o BatchMode=yes "$NP_REMOTE" "cd $ROOT/$NP_KEY && export GOPATH=$ROOT/cache/gopath GOCACHE=$ROOT/cache/gocache GOTOOLCHAIN=auto GOFLAGS=-p=2 && flock $ROOT/.lock nice -n 10 bash -lc $(printf '%q' "$*")"
