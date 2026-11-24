# 从 GitLab 发布到 Docker Hub 和 GitHub

开源分支为 `push-to-github`。发布使用项目的 GitLab Runner 构建 Linux/amd64 镜像，Docker Hub 仓库为 `youzifeile/chirp-server`，GitHub 目标为 `YouZiFeiLe/Chirp` 的 `main`。浏览器端和管理台资源随服务端镜像交付，原生客户端安装包由各平台的构建流程单独生成。[流水线定义](../.gitlab-ci.yml) · [发布脚本](../scripts/publish-open-source.sh) · [用户部署指南](../deploy/README.md)

## 首次配置

在 Docker Hub 创建或确认公开仓库 `youzifeile/chirp-server`。GitLab Shell Runner 需要 Git、可用的 Linux/amd64 Docker Engine 和 Compose 2.26 或更新版本，用于加载内联 Nginx 配置、隔离测试端口并等待容器健康。Runner 需要能访问 Docker Hub、Go 模块源和目标 GitHub 仓库。目标 GitHub 仓库需可公开读取，且已有 `main` 提交，脚本会读取它作为首个发布快照的父提交。

在 GitLab 项目的 **Settings → CI/CD → Variables** 配置以下变量。令牌设为 Masked。选择 Protected 时，为发布用的 Git 标签配置匹配的保护规则。[GitLab 变量](https://docs.gitlab.com/ci/variables/) · [Docker Hub 访问令牌](https://docs.docker.com/security/access-tokens/)

| 变量 | 值与用途 |
| --- | --- |
| `DOCKERHUB_TOKEN` | 有权向 `youzifeile/chirp-server` 推送镜像的 Docker Hub 访问令牌，授予 Read & Write |
| `DOCKERHUB_USERNAME` | 可选，默认 `youzifeile`。使用其他有写权限的发布账号时填写对应的登录名 |
| `GITHUB_PUSH_TOKEN` | 仅需目标 GitHub 仓库的 Contents 读写权限，`main` 的分支规则须允许该身份直接推送 |

## 发布一个版本

先将要发布的提交推到 GitLab 的 `push-to-github`。随后在 GitLab 新建标签并选取该分支的最新提交，或在已同步的本地分支执行以下示例。将示例版本换成自己的新版本号。

```sh
git switch push-to-github
git pull --ff-only
git tag v1.0.0
git push origin refs/tags/v1.0.0
```

普通提交不会发布。流水线在构建前、上传版本镜像前和更新 GitHub 快照前核对标签与远程分支的最新提交。如果分支已经前进，旧任务跳过后续发布步骤。多个发布任务在同一资源组内串行运行。

1. 从标签的源码构建 `deploy/Dockerfile` 的 `public` 目标。构建执行 Go 测试与 vet，并将原始标签写入 `chirp version`。
2. 使用成品镜像离线核对授权 seed 与客户端公钥。随后分别按 HTTP 和 DNS 配置启动 app、LiveKit 和 Nginx，使用临时证书验证 TLS、路由、管理接口隔离和 Certbot 验证器选择。两次检查各用独立卷和内部网络，实际域名的签发和续期在用户的部署环境完成。[Compose 集成检查](../scripts/test-open-source-compose.sh)
3. 推送 Docker Hub 版本镜像，例如 `youzifeile/chirp-server:v1.0.0`。普通 Docker 标签名与 Git 标签相同。对于 Docker 不支持的名称、`latest` 或以 `git-tag-` 开头的名称，使用 `git-tag-` 加标签文本的 Git blob 哈希。job 日志显示实际镜像名和推送摘要。
4. 将同一提交的文件树作为一个快照追加到 GitHub `main`，唯一父提交来自 GitHub。新快照的提交标题使用推送前的香港时间，例如 `2026-11-24 14:35:09 +0800`。GitLab 的原提交历史和标签留在源仓库。文件树相同时复用已有快照。
5. 将经过检查的同一份镜像发布为 `youzifeile/chirp-server:latest`。因此版本镜像先于 `latest` 可见。若外部推送中断，可以在分支仍指向该提交时重试该标签的 job。

发布后可在干净的部署目录按用户指南启动，并用 `docker compose exec app /usr/local/bin/chirp version` 核对实际版本。[Docker Hub 标签](https://hub.docker.com/r/youzifeile/chirp-server/tags) · [GitHub 源码快照](https://github.com/YouZiFeiLe/Chirp)
