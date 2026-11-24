#!/bin/sh
# Run on the deployment host. Registry credentials arrive only on stdin.
set -eu
[ "$#" -eq 5 ] || { echo '用法：apply-release.sh 部署目录 临时目录 健康URL 仓库 用户' >&2; exit 1; }
deploy_dir=$1
incoming=$2
health_url=$3
registry=$4
registry_user=$5
# Compose gives inherited shell variables precedence over every --env-file.
# Only the validated release files may select images and runtime settings.
unset CHIRP_IMAGE CHIRP_LIVEKIT_IMAGE \
    CHIRP_PUBLIC_ORIGIN CHIRP_LOG_LEVEL CHIRP_LOG_SERVER_ENABLED \
    CHIRP_LOG_SERVER_URL CHIRP_TOKEN_TTL CHIRP_GROUP_ROTATION \
    CHIRP_HTTP_PUBLISH_IP LIVEKIT_API_KEY LIVEKIT_API_SECRET
case "$incoming" in "$deploy_dir"/.ci-[0-9]*) ;; *) echo '临时发布目录不正确。' >&2; exit 1 ;; esac
job_id=${incoming##*/.ci-}
case "$job_id" in *[!0-9]*|'') exit 1 ;; esac
umask 077
cleanup() {
    rm -f "$incoming/compose.yaml" "$incoming/image.env" "$incoming/apply-release.sh" "$incoming/.env" "$incoming/livekit.yaml" "$incoming/expected-trust.json" "$incoming/bootstrap-request-id"
    rm -rf "$incoming/docker-config"
    chmod 0700 "$incoming"
    rm -f "$incoming/authorization-key"
    rmdir "$incoming" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 15
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || { echo '部署目标必须是 Linux x86_64。' >&2; exit 1; }
for command in curl flock od; do command -v "$command" >/dev/null || { echo "部署主机缺少 $command。" >&2; exit 1; }; done
exec 9>"$deploy_dir/.deploy.lock"
flock -w 120 9 || { echo '另一个发布仍在执行。' >&2; exit 1; }
docker compose version
for config in "$incoming/.env" "$incoming/livekit.yaml"; do
    [ -s "$config" ] || { echo '发布配置缺失。' >&2; exit 1; }
    if awk '!/^[[:space:]]*#/ && /REPLACE_WITH_|example[.]com/ { found=1 } END { exit !found }' "$config"; then
        echo '请填写公开域名及媒体公网 IPv4；配置仍有示例占位值。' >&2; exit 1
    fi
done
if ! awk '
    /^(CHIRP_IMAGE|CHIRP_LIVEKIT_IMAGE)=[a-zA-Z0-9.:\/_-]+@sha256:[0-9a-f]+$/ {
        split($0,a,"@sha256:"); split($0,k,"="); if(length(a[2])!=64 || seen[k[1]]++) exit 1; count++; next
    } { exit 1 } END { if(count!=2) exit 1 }
' "$incoming/image.env"; then echo '发布必须包含两份唯一的固定镜像摘要。' >&2; exit 1; fi
app_image=$(sed -n 's/^CHIRP_IMAGE=//p' "$incoming/image.env")
origin=$(sed -n 's/^CHIRP_PUBLIC_ORIGIN=//p' "$incoming/.env")
[ -n "$origin" ] || { echo '缺少 CHIRP_PUBLIC_ORIGIN。' >&2; exit 1; }
for path in secrets authorization-data data log .livekit.env; do
    [ ! -L "$deploy_dir/$path" ] || { echo '持久化路径不得为符号链接。' >&2; exit 1; }
done
# A temporary registry login is scoped to this release and deleted on all exits.
export DOCKER_CONFIG="$incoming/docker-config"
mkdir -p "$DOCKER_CONFIG"
docker login "$registry" --username "$registry_user" --password-stdin
# Media token credentials are generated on the target and never enter release artifacts.
if [ ! -e "$deploy_dir/.livekit.env" ]; then
    secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    [ "${#secret}" -eq 64 ] || { echo '媒体凭据生成失败。' >&2; exit 1; }
    printf 'LIVEKIT_API_SECRET=%s\n' "$secret" > "$deploy_dir/.livekit.env"
    unset secret
fi
chmod 0600 "$deploy_dir/.livekit.env"
candidate_compose() {
    docker compose --project-name chirp --project-directory "$deploy_dir" \
        --env-file "$incoming/.env" --env-file "$deploy_dir/.livekit.env" --env-file "$incoming/image.env" -f "$incoming/compose.yaml" "$@"
}
candidate_compose config --quiet
candidate_compose pull app livekit
# The repository supplies a public default seed; private deployments may upload
# their own seed instead. Check it against the client pin without a manual gate.
[ -f "$incoming/authorization-key" ] && [ ! -L "$incoming/authorization-key" ] || { echo '缺少发布授权密钥文件。' >&2; exit 1; }
chmod 0711 "$incoming"
chown 65532:65532 "$incoming/authorization-key"
chmod 0400 "$incoming/authorization-key"
chmod 0444 "$incoming/expected-trust.json"
if ! docker run --rm --platform linux/amd64 --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --mount "type=bind,src=$incoming,dst=/release,readonly" \
    "$app_image" authorization -key-file /release/authorization-key -verify-trust /release/expected-trust.json; then
    echo '发布授权密钥与客户端公钥不匹配，请同步修改配置后重新发布。' >&2
    exit 1
fi
chmod 0700 "$incoming"
restart_livekit=0
if [ -f "$deploy_dir/livekit.yaml" ] && ! cmp -s "$incoming/livekit.yaml" "$deploy_dir/livekit.yaml"; then restart_livekit=1; fi
if [ -f "$deploy_dir/.env" ]; then
    previous_media=$(awk '/^(LIVEKIT_API_KEY|CHIRP_HTTP_PUBLISH_IP)=/' "$deploy_dir/.env")
    candidate_media=$(awk '/^(LIVEKIT_API_KEY|CHIRP_HTTP_PUBLISH_IP)=/' "$incoming/.env")
    if [ "$previous_media" != "$candidate_media" ]; then restart_livekit=1; fi
fi
install -d -m 0700 -o 65532 -g 65532 "$deploy_dir/data"
install -d -m 0700 -o 65532 -g 65532 "$deploy_dir/log"
install -d -m 0700 -o 65532 -g 65532 "$deploy_dir/secrets"
key="$deploy_dir/secrets/authorization-key"
[ ! -L "$key" ] || { echo '授权密钥路径不得为符号链接。' >&2; exit 1; }
restart_app=0
if [ -f "$deploy_dir/compose.yaml" ] && ! cmp -s "$incoming/authorization-key" "$key"; then restart_app=1; fi
install -m 0400 -o 65532 -g 65532 "$incoming/authorization-key" "$key"
install -d -m 0700 -o 65532 -g 65532 "$deploy_dir/authorization-data"
cp "$incoming/.env" "$deploy_dir/.env"
cp -f "$incoming/livekit.yaml" "$deploy_dir/livekit.yaml"
chmod 0600 "$deploy_dir/.env"
chown 65534:65534 "$deploy_dir/livekit.yaml"
chmod 0400 "$deploy_dir/livekit.yaml"
cp "$incoming/compose.yaml" "$deploy_dir/compose.yaml"
cp "$incoming/image.env" "$deploy_dir/.image.env"
current_compose() {
    docker compose --project-name chirp --project-directory "$deploy_dir" \
        --env-file "$deploy_dir/.env" --env-file "$deploy_dir/.livekit.env" --env-file "$deploy_dir/.image.env" -f "$deploy_dir/compose.yaml" "$@"
}
if [ "$restart_livekit" = 1 ]; then current_compose up -d --no-build --force-recreate --wait --wait-timeout 90 livekit; fi
if [ "$restart_app" = 1 ]; then current_compose up -d --no-build --force-recreate --wait --wait-timeout 90 app; fi
current_compose up -d --no-build --remove-orphans --wait --wait-timeout 90
curl --fail --silent --show-error --noproxy '*' --retry 10 --retry-connrefused --retry-delay 2 --max-time 5 "$health_url"
curl --fail --silent --show-error --noproxy '*' --max-time 5 http://127.0.0.1:18115/authorization/healthz
if [ -s "$incoming/bootstrap-request-id" ]; then
    request_id=$(cat "$incoming/bootstrap-request-id")
    case "$request_id" in *[!a-zA-Z0-9_-]*|'') echo '管理员申请编号格式错误。' >&2; exit 1 ;; esac
    current_compose exec -T app /usr/local/bin/chirp admin bootstrap --request-id "$request_id"
fi
printf '\n主服务及授权状态健康检查通过；固定公钥匹配。\n'
current_compose ps
