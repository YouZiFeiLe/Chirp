#!/bin/sh
set -eu
CHIRP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export GOMODCACHE="${GOMODCACHE:-$CHIRP_ROOT/.build/go-mod}"
export GOCACHE="${GOCACHE:-$CHIRP_ROOT/.build/go-cache}"
exec go "$@"
