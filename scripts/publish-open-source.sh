#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export GIT_TERMINAL_PROMPT=0 LC_ALL=C

require_current_tag() {
    git fetch --quiet --no-tags --depth=1 origin refs/heads/push-to-github
    branch_tip=$(git rev-parse --verify FETCH_HEAD)
    if [ "$branch_tip" != "$CI_COMMIT_SHA" ]; then
        echo 'Skipping release: the tag is not at the tip of push-to-github.'
        exit 0
    fi
}

: "${CI_COMMIT_TAG:?a GitLab tag is required}"
require_current_tag
: "${DOCKERHUB_TOKEN:?configure a Docker Hub write token in GitLab}"
repo=docker.io/youzifeile/chirp-server
github_url=https://github.com/YouZiFeiLe/Chirp.git
version=$CI_COMMIT_TAG
# Keep ordinary Git tag names. Encode names reserved here or unsupported by Docker.
case "$version" in
    latest|git-tag-*|[!a-zA-Z0-9_]*|*[!a-zA-Z0-9_.-]*) version='' ;;
esac
if [ -z "$version" ] || [ "${#version}" -gt 128 ]; then
    tag_hash=$(printf '%s' "$CI_COMMIT_TAG" | git hash-object --stdin)
    version="git-tag-$tag_hash"
fi

umask 077
work=$(mktemp -d)
local_image="chirp-release-check:${CI_JOB_ID:?}"
cleanup() {
    docker image rm "$local_image" >/dev/null 2>&1 || :
    rm -rf "$work"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

docker build --pull --platform linux/amd64 --target public --build-arg "CHIRP_VERSION=$CI_COMMIT_TAG" \
    -f deploy/Dockerfile -t "$local_image" .
docker run --rm -i --network none --read-only "$local_image" authorization \
    -key-file /usr/share/chirp/authorization-key.default -verify-trust /dev/stdin \
    < Client/apple/Shared/Resources/AuthorizationTrust.json

sh scripts/test-open-source-compose.sh "$local_image"

require_current_tag
git fetch --quiet --no-tags --depth=1 "$github_url" refs/heads/main
github_tip=$(git rev-parse --verify FETCH_HEAD)
tree=$(git rev-parse --verify "${CI_COMMIT_SHA}^{tree}")
github_tree=$(git rev-parse --verify "${github_tip}^{tree}")
if [ "$tree" != "$github_tree" ]; then
    : "${GITHUB_PUSH_TOKEN:?configure GITHUB_PUSH_TOKEN in GitLab}"
fi

# Limit registry credentials to this job. Keep the runner's existing Docker configuration intact.
mkdir "$work/docker"
printf '%s\n' "$DOCKERHUB_TOKEN" | docker --config "$work/docker" login \
    --username "${DOCKERHUB_USERNAME:-youzifeile}" --password-stdin
docker tag "$local_image" "$repo:$version"
docker --config "$work/docker" push "$repo:$version"

require_current_tag
if [ "$tree" != "$github_tree" ]; then
    publish_time=$(TZ=Asia/Hong_Kong date '+%Y-%m-%d %H:%M:%S %z')
    snapshot=$(git -c user.name='Chirp Release' -c user.email='release@chirp.invalid' \
        commit-tree "$tree" -p "$github_tip" -m "$publish_time")
    github_credential='!credentials() {
        if [ "$1" = get ]; then
            printf "username=x-access-token\npassword=%s\n" "$GITHUB_PUSH_TOKEN"
        fi
    }; credentials'
    git -c credential.helper= -c "credential.helper=$github_credential" \
        push --no-follow-tags "$github_url" "$snapshot:refs/heads/main"
fi

docker tag "$local_image" "$repo:latest"
docker --config "$work/docker" push "$repo:latest"
printf 'Published %s:%s and %s:latest\n' "$repo" "$version" "$repo"
