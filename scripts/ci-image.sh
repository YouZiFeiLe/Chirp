#!/bin/sh
# 构造本次 tag 对应的 Nexus 镜像名，供构建与部署共用。
set -eu
export LC_ALL=C

: "${QD_NEXUS_ADDRESS:?请在 GitLab CI/CD 变量中填写 QD_NEXUS_ADDRESS}"
: "${CI_COMMIT_TAG:?只允许从 Git tag 发布}"

if [ "$#" -ne 0 ]; then
    echo '用法：ci-image.sh' >&2
    exit 1
fi
image_name=${DOCKER_IMAGE_NAME:-chirp-server}

case "$QD_NEXUS_ADDRESS" in
    *[!a-zA-Z0-9.:-]*|.*|-*|:*)
        echo 'QD_NEXUS_ADDRESS 只填写仓库主机名/IP 和可选端口，不带 http://、路径或空格。' >&2
        exit 1 ;;
esac
case "$image_name" in
    /*|*/|*//*|*[!a-z0-9._/-]*)
        echo 'DOCKER_IMAGE_NAME 使用小写 Docker 仓库名，可包含命名空间。' >&2
        exit 1 ;;
esac
case "$CI_COMMIT_TAG" in
    [!a-zA-Z0-9_]*|*[!a-zA-Z0-9_.-]*)
        echo 'Git tag 必须兼容 Docker 标签，例如 v0.1.0；不能包含斜线、空格或加号。' >&2
        exit 1 ;;
esac
if [ "${#CI_COMMIT_TAG}" -gt 128 ]; then
    echo 'Git tag 不能超过 Docker 标签的 128 字符限制。' >&2
    exit 1
fi

printf '%s/%s:%s\n' "$QD_NEXUS_ADDRESS" "$image_name" "$CI_COMMIT_TAG"
