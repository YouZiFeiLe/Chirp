# 从零部署 Chirp

推荐在 **Debian 13（trixie）x86_64 / amd64** 上运行 Chirp 和 LiveKit。已有 Nginx 和可用的 HTTPS 证书，可以直接将已有站点接入这两个后端。首次自建 HTTPS 入口的用户可以让 Compose 同时启动 Nginx，自动申请和续期证书。

## 1. 准备域名，选择 HTTPS 入口

给 Chirp 选一个专用域名，例如 `voice.example.com`。客户端会访问这个域名根目录下的固定路径。在域名管理页面将 **A 记录**指向提供 HTTPS 的 Nginx 的公网 IPv4。如果已有同名记录，核对它的指向即可。本指南按 IPv4 直连配置，选用仅有这条 A 记录的子域名。如果 DNS 服务有代理功能，选择「仅 DNS」。

| HTTPS 入口（三选一） | 适用情况 | 公网入站端口 |
| --- | --- | --- |
| [已有 Nginx 和证书](#使用已有-nginx-和证书) | 现有证书覆盖所选域名，继续由现有 Nginx 管理证书和续期。 | **443/TCP** 到已有 Nginx，**7882/UDP** 到运行 LiveKit 的服务器。80 端口按现有证书的续期方式处理。 |
| [内置 Nginx · HTTP-01](#使用内置-nginx) | 域名已解析到后端服务器，可以开放 80 端口。 | 后端服务器开放 **80/TCP** 用于签发与续期、**443/TCP** 用于 HTTPS/WSS、**7882/UDP** 用于语音。 |
| [内置 Nginx · DNS-01](#使用内置-nginx) | DNS 服务可以通过 API 写入 TXT 记录。 | 后端服务器开放 **443/TCP** 和 **7882/UDP**。证书通过 DNS 验证。 |

在云安全组和已启用的主机防火墙放行所选端口，保留 SSH 管理入口。服务器在路由器后面时，按同一端口和协议转发到服务器。准备能创建通行密钥的浏览器，以及维护者单独分发的 Chirp 客户端。通话验收需要两台设备和两个账号。客户端支持 Apple 芯片 Mac（macOS 27+）、iPhone（iOS 27+）、Android 15+ 和 Windows 11 24H2+（x64）。

## 2. 安装 Docker 并下载 Compose

通过 SSH 登录**运行 Chirp 后端的服务器**。以下命令使用带 `sudo` 权限的账号，已用 root 登录时可省去 `sudo`。新系统可以用 Docker 官方便捷脚本一次安装 Docker Engine 和 Compose 插件，并设为开机启动。已有可用的 Docker 和 Compose 2.26 或更新版本时，直接下载下一段的 Compose 文件。需要为生产服务器固定 Docker 版本时，可按官方 Debian 文档使用 apt 仓库安装。[Docker 官方脚本](https://github.com/docker/docker-install) · [Debian 安装与版本管理](https://docs.docker.com/engine/install/debian/)

```sh
sudo apt update
sudo apt install -y ca-certificates curl nano
curl -fsSL https://get.docker.com -o get-docker.sh &&
  sudo sh ./get-docker.sh &&
  sudo systemctl enable --now docker
sudo docker compose version
```

在新目录下载公开版 Compose。内置 Nginx 的配置已包含在其中。项目首次公开发布后下载地址可用。

```sh
mkdir -p ~/chirp
cd ~/chirp
curl -fL https://raw.githubusercontent.com/YouZiFeiLe/Chirp/main/compose.yaml -o compose.yaml
```

## 3. 配置入口并启动

按第 1 步的选择，完成下面对应的一节。在 `~/chirp` 中用 `nano .env` 创建配置文件，按 Ctrl+O、回车保存，再按 Ctrl+X 退出。

### 使用已有 Nginx 和证书

**启动后端。** 在 Chirp 服务器的 `.env` 写入以下两行。第一行填用户访问 Nginx 的 HTTPS 地址，第二行填客户端能直接到达的 **LiveKit 媒体公网 IPv4**。这种部署使用默认的 Compose 服务，省略 `COMPOSE_PROFILES=https` 和所有证书申请参数。

```dotenv
CHIRP_PUBLIC_ORIGIN=https://voice.example.com
CHIRP_RTC_NODE_IP=203.0.113.10
```

根据现有 Nginx 的位置选定两个上游地址。业务端口和信令端口只需允许 Nginx 访问。

| 现有 Nginx 在哪里 | 业务上游 / 信令上游 | 需要做什么 |
| --- | --- | --- |
| Chirp 同一台机器，Nginx 直接装在宿主机上 | `127.0.0.1:18115` / `127.0.0.1:7880` | 使用上述两行即可。Compose 默认把这两个 TCP 端口绑定到本机回环。 |
| 另一台机器 | 例如 `10.0.0.20:18115` / `10.0.0.20:7880` | 在后端 `.env` 追加 `CHIRP_HTTP_PUBLISH_IP=10.0.0.20`，替换为后端实际的内网或 VPN 接口地址。模板使用 HTTP，跨机连接可走 VPN 加密隧道。在后端只允许 Nginx 的内网地址访问这两个 TCP 端口。 |
| 同机的另一个 Docker 容器 | `app:18115` / `livekit:7880` | 后端启动后执行 `sudo docker network connect chirp_default 现有Nginx容器名`，替换成实际容器名。容器内的 `127.0.0.1` 指向该容器自身。若代理由 Compose 管理，可将 `chirp_default` 声明为外部网络，使重建后仍能连接。[网络配置示例](../docs/server-operations.md#已有-nginx-容器的持久网络配置) |

```sh
sudo docker compose config --services
sudo docker compose up -d --wait app livekit
sudo docker compose ps
```

第一条命令应只列出 `app` 和 `livekit`。启动完成后，两项服务在 `ps` 输出中都应为 `healthy`。

**接入已有站点。** 在 **Nginx 所在服务器**下载配套模板。将 `server_name` 改为 Chirp 域名，`ssl_certificate` 和 `ssl_certificate_key` 沿用现有证书链和私钥的路径。把模板顶部两个 `upstream` 中的地址换成上表所选的一组。同机原生 Nginx 可直接使用模板中的上游地址。[查看站点模板](nginx-upstreams.example.conf)

```sh
curl -fL https://raw.githubusercontent.com/YouZiFeiLe/Chirp/main/deploy/nginx-upstreams.example.conf -o chirp-nginx.conf
nano chirp-nginx.conf
```

模板将 `/rtc` 和 `/rtc/*` 的原始路径、查询参数和 WebSocket 升级头转给 LiveKit。注册、管理台、授权和事件流交给 Chirp，关闭代理缓冲。公网的 `/twirp`、`/internal` 及其子路径返回 404。语音由客户端直连后端的 **7882/UDP**。

- **新建 Chirp 专用站点**时，把编辑好的模板放入当前 Nginx 的 `http` 已包含的配置目录。Debian 默认可执行 `sudo install -m 0644 chirp-nginx.conf /etc/nginx/conf.d/chirp.conf`。
- **已有该域名的 HTTPS 站点**时，把模板的 `upstream`、`map`、`limit_req_zone` 放在 `http` 层各一次。保留原站点的监听和证书，把模板中其余代理指令及 `location` 合并到这个域名的 `server` 中，替换原有的同路径规则。

在原生 Nginx 上执行 `sudo nginx -t && sudo systemctl reload nginx`。对于容器化 Nginx，把站点文件放入它原有的配置挂载目录，再执行以下命令，替换第一行的容器名。证书和私钥始终由现有 Nginx 读取。

```sh
NGINX_CONTAINER=你的Nginx容器名
sudo docker exec "$NGINX_CONTAINER" nginx -t &&
  sudo docker exec "$NGINX_CONTAINER" nginx -s reload
```

接着[检查公网入口](#检查公网入口)。

### 使用内置 Nginx

在 `~/chirp` 运行 `sudo install -d -m 0700 secrets` 创建证书存储目录。将以下内容粘贴进 `.env`，把示例域名、媒体公网 IPv4 和邮箱换成自己的。保留含 `${CHIRP_DOMAIN}` 的那一行，Compose 会自动填入上面的域名。

```dotenv
COMPOSE_PROFILES=https
CHIRP_DOMAIN=voice.example.com
CHIRP_PUBLIC_ORIGIN=https://${CHIRP_DOMAIN}
CHIRP_RTC_NODE_IP=203.0.113.10
CHIRP_ACME_EMAIL=admin@example.com
CHIRP_ACME_METHOD=http
```

**选 HTTP-01** 的用户可以直接执行下方的启动命令。Certbot 会让 Let's Encrypt 通过公网 80/TCP 验证域名，续期时也会使用这个端口。

**选 DNS-01** 的用户在 `.env` 中把最后一行替换为下面三行。此例使用 Cloudflare，其 DNS API 令牌只需授权目标域的 `Zone / DNS / Edit`。若使用阿里云，将 `cloudflare` 改为 `aliyun`，准备有权为该域添加、查询和删除 TXT 记录的 RAM 凭据。HTTP 入口此时只监听服务器本机的 8080 端口。[Cloudflare 插件](https://certbot-dns-cloudflare.readthedocs.io/en/stable/) · [SWAG 支持的 DNS 服务](https://docs.linuxserver.io/images/docker-swag/)

```dotenv
CHIRP_ACME_METHOD=dns
CHIRP_DNS_PLUGIN=cloudflare
CHIRP_NGINX_HTTP_BIND=127.0.0.1:8080
```

DNS 模式还需创建凭据文件。以下命令选择与 `.env` 相同的插件名，将密钥填入编辑器。保留此文件供自动续期使用。

```sh
DNS_PLUGIN=cloudflare
sudo install -d -m 0700 secrets/swag/dns-conf
sudo touch "secrets/swag/dns-conf/$DNS_PLUGIN.ini"
sudo chmod 600 "secrets/swag/dns-conf/$DNS_PLUGIN.ini"
sudo nano "secrets/swag/dns-conf/$DNS_PLUGIN.ini"
```

| 插件 | 凭据文件的完整内容 |
| --- | --- |
| `cloudflare` | 一行 `dns_cloudflare_api_token = 你的令牌` |
| `aliyun` | 第一行 `dns_aliyun_access_key = 你的AccessKeyID`，第二行 `dns_aliyun_access_key_secret = 你的AccessKeySecret` |

**两种方式都用同一条命令启动**。首次拉取镜像、签发证书和等待 DNS 生效可能需要几分钟。

```sh
sudo docker compose up -d --wait --wait-timeout 600
sudo docker compose ps
```

内置入口的 `app`、`livekit`、`nginx` 都应显示 `healthy`。

### 检查公网入口

从能访问公网的电脑执行以下命令，将域名换成自己的。第一条应返回含 `"status":"ok"` 的 JSON。第二条应返回 **401**，表示请求已到达需要入房令牌的 LiveKit 信令接口。

```sh
curl -fsS https://voice.example.com/healthz
curl -sS -o /dev/null -w '%{http_code}\n' https://voice.example.com/rtc/v1/validate
```

用浏览器打开 `https://你的域名/register`，确认显示安全连接和「申请加入」页面。注册前选定长期使用的域名，通行密钥与该域名绑定。

## 4. 建立首位管理员

1. 在刚打开的登记页输入 3–15 位英文字母作为登记名，按系统提示创建通行密钥。点击「复制申请编号」，保存**完整编号**。
2. 回到服务器终端，在 `~/chirp` 内执行下面的命令，将引号里的文字替换为完整编号。每个新数据库只需执行一次。

```sh
sudo docker compose exec app /usr/local/bin/chirp admin bootstrap --request-id '粘贴完整申请编号'
```

3. 在浏览器打开 `https://你的域名/admin/`，用刚才的通行密钥登录。请一位朋友在同一域名的 `/register` 登记，并把自己的编号交给你。打开管理台的「注册申请」，核对编号和登记名后批准。

## 5. 验证第一次通话

两人各自在原生客户端输入同一个 `https://你的域名`，用**各自的账号**登录。首次登录时按提示设置恢复密码、导出并保管好 `.chirpkey` 文件。每个账号同一时间只有一个有效客户端登录。

两人加入同一间大厅，打开待核验的成员。通过当面或另一条可信渠道比较两端显示的三组安全码，双方确认相同后完成核验。等房间显示可以发送，各自打开麦克风，轮流说话。**两边都能听见对方**才完成通话验收。

## 日常使用和排障

后续重新登录后端服务器时，先执行 `cd ~/chirp`。暂停用 `sudo docker compose stop`，恢复用 `sudo docker compose up -d --wait`。账号和附件保存在 Docker 卷内。带 `-v` 的 `down` 会删除数据卷。已有 Nginx 的用户继续在代理服务器备份站点和证书。内置 Nginx 的证书、续期账户和 DNS 凭据在 `~/chirp/secrets/swag/`，一并备份并限制访问。

更新到最新公开版前，先停止服务，在云控制台为**存放部署目录和 Docker 卷的所有磁盘**制作快照。快照完成后，在 `~/chirp` 下载配套 Compose 并更新镜像。保留原来的 `.env`，更新后再验证一次双向通话。

```sh
curl -fL https://raw.githubusercontent.com/YouZiFeiLe/Chirp/main/compose.yaml -o compose.next.yaml &&
  sudo docker compose -f compose.next.yaml config --quiet &&
  mv compose.next.yaml compose.yaml &&
  sudo docker compose pull &&
  sudo docker compose up -d --wait
```

| 遇到的情况 | 先检查什么 |
| --- | --- |
| 下载返回 404 或镜像找不到 | 核对项目是否已在 GitHub 发布根目录的 `compose.yaml`，以及 Docker Hub 是否已有公开的 `youzifeile/chirp-server:latest`。 |
| 已有 Nginx 返回 502，或业务正常但信令检查返回 404 | 从 Nginx 所在机器或容器直访 `http://业务上游/healthz`（应为 200）和 `http://信令上游/rtc/v1/validate`（应为 401）。两项都通时，核对站点的 `/rtc` 转发规则。使用 Docker 服务名时，后端容器重建后重载 Nginx，让它重新解析地址。 |
| 内置 Nginx 长时间未就绪 | 用 `sudo docker compose logs --tail=100 nginx` 查签发结果。HTTP 模式检查域名 A 记录、公网 80/TCP 和端口占用。DNS 模式检查插件名、凭据文件、目标域权限和 TXT 传播。修正后执行 `sudo docker compose up -d --force-recreate --wait nginx`。 |
| 容器健康，但注册或登录失败 | 用浏览器检查 HTTPS 证书，并核对 `~/chirp/.env` 的 `CHIRP_PUBLIC_ORIGIN` 与客户端填写的地址。改好后重新运行 `sudo docker compose up -d --wait`。 |
| 能登录但无法通话 | 确认两端已互认并开麦，检查 `.env` 中的 `CHIRP_RTC_NODE_IP` 与公网 IPv4，以及 **7882/UDP** 的安全组和转发。可用 `sudo docker compose logs --tail=50 livekit` 查看媒体服务日志。 |

标准镜像与配套客户端共用项目公开的授权签名密钥。需要独占签名权的部署，可以更换密钥并分发配套客户端。[自用签名身份](../docs/authorization-keys.md)
