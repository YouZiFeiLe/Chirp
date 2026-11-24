# 服务端配置与运维

这份参考面向维护已有实例的管理员。首次安装、HTTPS 和首次通话见[从零部署 Chirp](../deploy/README.md)。以下命令在公开版 `compose.yaml` 所在目录执行，运行账号需要 Docker 权限。

## 配置入口

推荐宿主机为 Debian 13 x86_64。根目录的 Compose 固定使用 Linux/amd64，从同目录的 `.env` 或运行环境读取下列变量。修改后运行 `docker compose up -d --wait` 应用配置。[公开 Compose](../compose.yaml) · [服务端配置校验](../internal/config/config.go)

| 变量 | Compose 默认值 | 使用时机 |
| --- | --- | --- |
| `COMPOSE_PROFILES` | 空 | 公网一体部署设为 `https`，启动带 Certbot 的 Nginx。留空可继续使用已有代理或在本机调试。 |
| `CHIRP_DOMAIN`、`CHIRP_ACME_EMAIL` | 空 | 公网 profile 使用的证书域名和 ACME 联系邮箱。域名只写主机名，`CHIRP_PUBLIC_ORIGIN` 设为 `https://${CHIRP_DOMAIN}`。 |
| `CHIRP_ACME_METHOD`、`CHIRP_DNS_PLUGIN` | `http`、`cloudflare` | 方法可选 `http` 或 `dns`。DNS 模式的凭据文件由所选插件决定，如 `dns-conf/cloudflare.ini`、`dns-conf/aliyun.ini`。 |
| `CHIRP_NGINX_HTTP_BIND` | `0.0.0.0:80` | 宿主机的 HTTP 监听地址和端口。DNS 模式可设为 `127.0.0.1:8080` 以释放公网 80。HTTPS 固定发布 443/TCP。 |
| `CHIRP_IMAGE` | `docker.io/youzifeile/chirp-server:latest` | 固定版本时改为已发布的标签，或 `docker.io/youzifeile/chirp-server@sha256:…`。 |
| `CHIRP_PUBLIC_ORIGIN` | `http://localhost:18115` | 公网填完整 HTTPS Origin，可含端口。API、Passkey、管理台与 WSS 共用主机名。HTTP 仅用于 localhost 开发。 |
| `CHIRP_RTC_NODE_IP` | 空 | 公网填客户端可达的媒体主机 IP。经过 NAT 时将 UDP 7882 原端口转发到媒体主机。 |
| `CHIRP_HTTP_PUBLISH_IP` | `127.0.0.1` | 控制宿主机上 18115/TCP、7880/TCP 的监听接口。异机反代可选专用接口，仅向反代开放。 |
| `CHIRP_LOG_LEVEL` | `info` | 应用日志级别，可选 `debug`、`info`、`warn`、`error`。 |
| `CHIRP_LOG_SERVER_ENABLED`、`CHIRP_LOG_SERVER_URL` | `false`、空 | 启用后直送指定的 VictoriaLogs HTTP(S) 基地址，本地日期日志仅用于默认模式。 |
| `CHIRP_TOKEN_TTL` | `5m` | 入房媒体令牌的有效期，范围 `1s` 至 `15m`。 |
| `CHIRP_GROUP_ROTATION` | `60s` | 房间密钥的计划轮换间隔，范围 `30s` 至 `30m`。 |

镜像内置与开源客户端配套的公开授权 seed。自有签名身份需要挂载自用 seed，并把配套的 `AuthorizationTrust.json` 编进各端。LiveKit 则使用每套部署首次启动时随机生成的媒体凭据。[授权密钥与客户端信任](authorization-keys.md)

## 反代与就绪状态

| 流量 | 目的地与约束 |
| --- | --- |
| `/rtc` 与 `/rtc/*` | LiveKit 7880/TCP。保留路径、查询和 WebSocket Upgrade，允许长连接。 |
| `/authorization/v5/*` | app 18115/TCP。保留原路径，限速并关闭缓存。 |
| `/twirp/*`、`/internal/*` | 公网入口返回 404。app 从 Compose 网络访问 LiveKit 管理接口。 |
| 其余 HTTP，包括管理台、注册、API、SSE | app 18115/TCP。保留 Host 和原始协议，关闭代理缓冲以便及时投递事件。 |
| 媒体 | 客户端直达媒体主机 7882/UDP。配置关闭 TURN、媒体 TCP 监听与回退。 |

内置 Nginx 使用 Docker DNS 解析 `app:18115` 和 `livekit:7880`，后端容器重建后会重新解析地址。健康检查使用配置的域名和受信任的证书，通过本机 443 请求 `/healthz`。证书有误、业务服务不可用或签发尚未完成时，`nginx` 会显示未就绪。[容器站点配置](../compose.yaml)

### 已有 Nginx 容器的持久网络配置

已有 Nginx 的上游地址、证书配置及公网验收命令见[快速部署指南](../deploy/README.md#使用已有-nginx-和证书)。同机运行两个 Compose 项目时，先启动 Chirp 后端，在**原有 Nginx 的 Compose 文件**中追加 Chirp 网络。以下示例假设代理服务名为 `nginx`、原先使用 `default` 网络，实际配置应保留代理已有的全部网络。[Compose 跨项目网络](https://docs.docker.com/compose/how-tos/networking/)

```yaml
services:
  nginx:
    networks: [default, chirp_backend]
networks:
  chirp_backend:
    external: true
    name: chirp_default
```

在 Nginx 项目目录执行 `docker compose up -d nginx` 应用网络配置，模板中的两个上游即可使用 `app:18115` 和 `livekit:7880`。自定义过 Chirp 项目名时，将 `chirp_default` 换为实际网络名。模板使用的上游服务名在 Nginx 加载配置时解析，升级或重建后端后可在 Nginx 项目中执行 `docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload`。

### 证书签发、续期与迁移

Nginx 使用固定版本的 LinuxServer SWAG 镜像，Certbot 在同一容器内完成首次签发、定期检查和续期。HTTP-01 使用独立的 80 端口监听，续期验证时可能短暂重启 Nginx。DNS-01 通过服务商 API 更新 TXT 记录，续期后重新加载 Nginx。排障可运行 `docker compose logs --tail=100 nginx` 和 `docker compose exec nginx certbot certificates --config-dir /config/etc/letsencrypt`。[SWAG 文档](https://docs.linuxserver.io/images/docker-swag/) · [ACME 验证类型](https://letsencrypt.org/docs/challenge-types/)

TLS 状态保存在部署目录的 `secrets/swag/`，其中 `etc/letsencrypt/` 保存账户、证书及续期配置，`dns-conf/` 保存 DNS 插件凭据。父目录 `secrets/` 只向运维账号开放。变更证书域名或切换验证方式前先备份整个状态目录，SWAG 会按新参数重新签发，并可能撤销旧证书。DNS 插件与密钥格式见[部署指南](../deploy/README.md)。

从内置 Nginx 切换到现有代理时，保留原公开域名和数据卷。在 Chirp 目录执行 `docker compose --profile https stop nginx` 释放端口，从 `.env` 移除 `COMPOSE_PROFILES=https`，再按快速部署指南接入代理。反向迁移到内置入口时，为容器留出 443/TCP 以及 HTTP 验证所需的 80/TCP。启用 `https` profile 后验证证书、注册页面和双向通话，再停用旧站点的续期任务。[外置 Nginx 模板](../deploy/nginx-upstreams.example.conf)

### 检查服务与日志

```sh
docker compose ps
docker compose exec app /usr/local/bin/chirp version
curl -fsS http://127.0.0.1:18115/healthz
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18115/authorization/healthz
docker compose logs --tail=100 livekit
docker compose cp app:/app/log/. ./chirp-logs
```

`/livez` 返回 200 表示应用能够响应。`/healthz` 检查业务库和授权库，成功返回 200。授权服务单独的 `/authorization/healthz` 成功返回 204。Compose 另行检查 LiveKit 的 HTTP 入口。涉及网络、TLS 或媒体改动时，用两个真实客户端验证双向声音。[应用路由](../internal/application/application.go) · [人工验收](manual-testing.md)

## 管理员维护

管理台为公开 Origin 的 `/admin/`。角色变更需要主机权限。在部署目录执行 `docker compose exec app /usr/local/bin/chirp` 后接下列参数。[CLI 实现](../cmd/chirp/main.go) · [角色和首次初始化](../internal/store/administrators.go)

| 参数 | 作用 |
| --- | --- |
| `admin bootstrap --request-id 完整申请编号` | 批准待审批申请并创建首位管理员，每个业务库一次。 |
| `member list` | 查询成员 ID。 |
| `admin grant --id 成员ID` 或 `admin revoke --id 成员ID` | 授予或撤销管理员角色。 |
| `admin grant --request-id 完整申请编号` | 将待审批申请批准为管理员。管理员丢失 Passkey 时可用新登记恢复管理入口。 |
| `admin reopen-registration` | 恢复新成员登记。暂停登记期间已有申请仍可处理。 |
| `member disable --id 成员ID` | 永久停用账号。先核对目标 ID。 |

网页可以审批普通成员、管理房间和密码、编辑房间描述、结束入房或登录、设置客户端版本策略、撤销设备。改变房间密码影响后续入房，立即结束现有通话需执行移出成员或结束房间通话。默认大厅可改名。

停用、删除成员及管理员降权会保护最后一位有效管理员。管理员撤销成员最后一台有效设备会永久封禁对应账号，此操作也适用于管理员账号。黑名单保留已封禁身份与用户名。[设备撤销逻辑](../internal/store/devices.go)

## 备份、恢复与迁移

| 卷（默认项目名 `chirp`） | 容器路径 | 内容 |
| --- | --- | --- |
| `chirp_data` | `/data` | `chirp.db`、`authorization.db`、各自的 WAL/SHM 和 `attachments/` 附件密文。 |
| `chirp_media-keys` | `/var/lib/chirp-media` | `keys.json`。app 写入，LiveKit 只读挂载。 |
| `chirp_logs` | `/app/log` | 默认保存当天及此前六天的 JSON Lines 日志。 |

1. 备份前执行 `docker compose stop`，同时保存完整的 `data` 与 `media-keys` 卷、Compose、`.env` 及自用授权 seed（如有）。使用内置入口时备份 `secrets/swag/`，已有代理则备份该代理的站点配置和证书。保留证书目录的权限与符号链接。有留存要求时一并备份日志卷。在原生 Linux Docker 主机上，`docker volume inspect chirp_data chirp_media-keys` 可定位两个卷。备份完成后执行 `docker compose up -d --wait`。
2. 恢复到空目标时，选取与备份匹配的服务端版本和授权签名身份，先用 `docker compose create` 创建容器和卷。把同一备份中的文件恢复到对应卷，保留 UID/GID 65532 和 `keys.json` 的 0600 权限，再启动并检查健康接口。恢复较早的授权库可能丢失后续撤销记录，已保存较新检查点的客户端会拒绝倒退的历史。[授权连续性](security.md)
3. 从 `deploy/compose.yaml` 的绑定目录迁移时，先停止旧实例并备份。在新实例的 `data` 卷内还原原 `data/` 的业务库与附件，将原 `authorization-data/` 中的授权库及其 WAL/SHM 放到同一卷根部。沿用现有客户端时保留其匹配的授权 seed，并继续使用原 Passkey 域名。[源码构建 Compose](../deploy/compose.yaml) · [挂载自用密钥](authorization-keys.md)

## 开发数据重建

当前业务库接受空库或同一 schema 的库，版本可用 `chirp version` 核对。测试初始化流程时，先停止同端口的旧实例，在根目录运行 `docker compose -p chirp-dev up -d --wait`，独立的项目名会使用单独的卷。新库需重新登记并初始化管理员。旧库由原项目保留。[数据库初始化](../internal/store/store.go) · [本地开发与验证](development.md)
