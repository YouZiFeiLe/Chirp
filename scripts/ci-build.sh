#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

image=$(sh scripts/ci-image.sh)
: "${DOCKER_NEXUS_PASSWD:?请在 GitLab CI/CD 变量中填写 DOCKER_NEXUS_PASSWD}"

# 使用临时 Docker 登录配置，兼容共享的 Shell Runner，不改写其既有登录信息。
umask 077
chirp_docker_config=$(mktemp -d)
test_image="chirp-release-check:job-${CI_JOB_ID:-$$}"
trap 'docker image rm "$test_image" >/dev/null 2>&1 || :; rm -rf "$chirp_docker_config"' 0
trap 'exit 1' 1 2 15
export DOCKER_CONFIG="$chirp_docker_config"

docker version
printf '%s' "$DOCKER_NEXUS_PASSWD" |
    docker login "$QD_NEXUS_ADDRESS" --username "${DOCKER_NEXUS_USERNAME:-docker}" --password-stdin
docker build --pull --platform linux/amd64 --target test -f deploy/Dockerfile -t "$test_image" .
docker run --rm --platform linux/amd64 "$test_image"
docker build --pull --platform linux/amd64 --target app \
    --build-arg "CHIRP_VERSION=$CI_COMMIT_TAG" \
    -f deploy/Dockerfile -t "$image" .
docker run --rm --platform linux/amd64 "$image" version
docker push "$image"
docker pull --platform linux/amd64 livekit/livekit-server:v1.13.11
# Pass the immutable content addresses to deployment, never resolve a mutable
# release tag again on the target host. This file contains no private keys.
mkdir -p .build
resolve_digest() {
    docker image inspect --format '{{join .RepoDigests "\n"}}' "$1" |
        awk -v prefix="${1%:*}@sha256:" 'index($0,prefix)==1 { print; found++; } END { if (found!=1) exit 1 }'
}
image_digest=$(resolve_digest "$image")
livekit_digest=$(resolve_digest livekit/livekit-server:v1.13.11)
for digest in "$image_digest" "$livekit_digest"; do
    printf '%s\n' "$digest" | LC_ALL=C grep -Eq '^[a-zA-Z0-9.:/_-]+@sha256:[0-9a-f]{64}$' || exit 1
done
printf 'CHIRP_IMAGE=%s\nCHIRP_LIVEKIT_IMAGE=%s\n' "$image_digest" "$livekit_digest" > .build/release-images.env
printf '主服务镜像已推送；部署将使用构建产物中的 sha256 摘要。\n'
