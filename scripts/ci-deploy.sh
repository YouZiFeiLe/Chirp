#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/deployment
rm -f .build/deployment/status.txt

image=$(sh scripts/ci-image.sh)
registry_password=${DOCKER_NEXUS_PULL_PASSWD:-${DOCKER_NEXUS_PASSWD:?缺少部署机临时仓库登录所需 Nexus 凭据}}
registry_user=${DOCKER_NEXUS_PULL_USERNAME:-${DOCKER_NEXUS_USERNAME:-docker}}
case "$registry_user" in ''|*[!a-zA-Z0-9_.-]*) echo '仓库用户名格式不正确。' >&2; exit 1 ;; esac
if [ ! -s .build/release-images.env ] || ! awk '
    /^(CHIRP_IMAGE|CHIRP_LIVEKIT_IMAGE)=[a-zA-Z0-9.:\/_-]+@sha256:[0-9a-f]+$/ {
        split($0,a,"@sha256:"); split($0,k,"="); if (length(a[2]) != 64 || seen[k[1]]++) exit 1; count++; next
    }
    { exit 1 }
    END { if (count != 2) exit 1 }
' .build/release-images.env; then
    echo '缺少构建阶段生成的两份固定镜像摘要。' >&2; exit 1
fi
: "${CI_JOB_ID:?缺少 GitLab CI_JOB_ID}"
deploy_host=${CHIRP_DEPLOY_HOST:-192.168.50.26}
deploy_user=${CHIRP_DEPLOY_USER:-root}
deploy_port=${CHIRP_DEPLOY_PORT:-22}
# 远端发布文件、配置和临时发布目录统一放在此处；SQLite 数据保存在 data 子目录。
deploy_dir=/data/chirp
health_url=${CHIRP_HEALTHCHECK_URL:-http://127.0.0.1:18115/healthz}

# 这些值用于 SSH 连接或作为远端参数；限定为常规主机、端口和无空格路径。
case "$deploy_host" in -*|*[!a-zA-Z0-9.:-]*) echo '部署主机格式不正确。' >&2; exit 1 ;; esac
case "$deploy_user" in -*|*[!a-zA-Z0-9_-]*) echo '部署用户名格式不正确。' >&2; exit 1 ;; esac
case "$deploy_port" in *[!0-9]*) echo 'SSH 端口必须是数字。' >&2; exit 1 ;; esac
if [ "$deploy_port" -lt 1 ] || [ "$deploy_port" -gt 65535 ]; then
    echo 'SSH 端口必须在 1 到 65535 之间。' >&2
    exit 1
fi
for check_url in "$health_url"; do
    case "$check_url" in http://*|https://*) ;; *) echo '健康检查地址必须是 HTTP/HTTPS URL。' >&2; exit 1 ;; esac
    case "$check_url" in *[!a-zA-Z0-9.:/_-]*) echo '健康检查地址请使用不含参数或空格的普通 URL。' >&2; exit 1 ;; esac
done
case "$CI_JOB_ID" in *[!0-9]*) echo 'CI_JOB_ID 必须是数字。' >&2; exit 1 ;; esac

for config in deploy/.env deploy/livekit.yaml; do
    if [ ! -s "$config" ]; then
        echo "项目缺少非空配置文件 $config，请按对应 .example 模板填写后再发布。" >&2
        exit 1
    fi
done

umask 077
trust=Client/apple/Shared/Resources/AuthorizationTrust.json
[ -s "$trust" ] || { echo '缺少 Apple 授权公钥配置文件。' >&2; exit 1; }
authorization_key_source=${CHIRP_AUTHORIZATION_KEY_SOURCE:-deploy/authorization-key.default}
[ -f "$authorization_key_source" ] && [ ! -L "$authorization_key_source" ] || { echo '缺少发布授权密钥文件。' >&2; exit 1; }
request_id=${CHIRP_BOOTSTRAP_REQUEST_ID:-}
case "$request_id" in *[!a-zA-Z0-9_-]*) echo '管理员申请编号格式不正确。' >&2; exit 1 ;; esac
chirp_release_work=$(mktemp -d)
trap 'rm -rf "$chirp_release_work"' 0
trap 'exit 1' 1 2 15
# 发布包包含配置、授权签名 seed 和客户端公钥；通过 SSH 传输，不作为 CI 制品保存。
mkdir "$chirp_release_work/bundle"
cp deploy/compose.yaml deploy/apply-release.sh deploy/livekit.yaml "$chirp_release_work/bundle/"
# Media credentials stay on the target and cannot be overwritten by a repository value.
awk '!/^[[:space:]]*(export[[:space:]]+)?LIVEKIT_API_SECRET[[:space:]]*=/' deploy/.env > "$chirp_release_work/bundle/.env"
cp "$trust" "$chirp_release_work/bundle/expected-trust.json"
cp "$authorization_key_source" "$chirp_release_work/bundle/authorization-key"
chmod 0600 "$chirp_release_work/bundle/authorization-key"
printf '%s' "$request_id" > "$chirp_release_work/bundle/bootstrap-request-id"
chmod 600 "$chirp_release_work/bundle/.env" "$chirp_release_work/bundle/livekit.yaml"
cp .build/release-images.env "$chirp_release_work/bundle/image.env"
# 本机 macOS 验证时也不附带 AppleDouble 元数据文件；Linux tar 会忽略此环境变量。
COPYFILE_DISABLE=1 tar -C "$chirp_release_work/bundle" -cf "$chirp_release_work/release.tar" compose.yaml apply-release.sh image.env .env livekit.yaml expected-trust.json authorization-key bootstrap-request-id
incoming="$deploy_dir/.ci-$CI_JOB_ID"
# 直接沿用 Runner 已有的免密 SSH 配置，不创建或导入私钥、known_hosts 或临时 SSH 配置。
ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$deploy_port" "$deploy_user@$deploy_host" "umask 077 && mkdir -p '$deploy_dir' '$incoming' && tar -xf - -C '$incoming'" < "$chirp_release_work/release.tar"
status=0
printf '%s' "$registry_password" |
    ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$deploy_port" "$deploy_user@$deploy_host" \
        "sh '$incoming/apply-release.sh' '$deploy_dir' '$incoming' '$health_url' '$QD_NEXUS_ADDRESS' '$registry_user'" || status=$?
printf 'tag=%s\njob=%s\nexit_status=%s\n' "$CI_COMMIT_TAG" "$CI_JOB_ID" "$status" > .build/deployment/status.txt
exit "$status"
