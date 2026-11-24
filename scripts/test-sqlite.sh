#!/bin/sh
# SQLite integration tests use isolated local files; never reads deploy/.env.
set -eu
cd "$(dirname "$0")/.."
case "${1:-local}" in
    local)
        sh scripts/go.sh test -race -count=1 ./...
        sh scripts/go.sh vet ./...
        ;;
    docker)
        docker build --platform linux/amd64 --target test -f deploy/Dockerfile -t chirp-go-sqlite-test .
        docker run --rm --platform linux/amd64 chirp-go-sqlite-test
        ;;
    *) echo '用法：test-sqlite.sh [local|docker]' >&2; exit 1 ;;
esac
