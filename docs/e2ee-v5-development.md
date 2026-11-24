# Chirp V5 端到端加密协议

macOS、iOS、Windows 和 Android 使用同一套 V5 身份、授权快照和 MLS 名单验证规则。三个客户端工程分别桥接共享 Rust 库。Go 服务负责保存登记状态和签署快照，客户端决定哪些设备可以收到内容密钥。[项目架构](architecture.md) · [安全边界](security.md)

## 安全目标与接受的风险

业务 API、信令、SFU 和网络可能恶意替换、重放、隐瞒或延迟数据。内容密钥仅由经过设备核验的客户端持有；服务器签发的登录凭据或媒体 JWT 不授予内容解密能力。SAS、设备签名、精确名单及密钥确认决定谁能参与建钥。

**主服务持有授权签名密钥和授权数据库，可以长期隐瞒客户端尚未知晓的撤销。** 仓库默认私钥为公开材料，任何持有者都可给旧的有效历史签发新挑战响应。60 秒期限只限制已获取快照的本地使用时长。若攻击者同时持有一台旧可信设备的私钥，可能继续与尚未获知撤销的客户端建钥，持续换钥也会继续包含名单上仍被接纳的设备。[自用密钥的替换步骤](authorization-keys.md)

客户端继续逐条验证设备签名、证书链、事件顺序、当时权限、历史前缀和本地撤销。仅获得服务端签名密钥不能伪造用户设备签名或得出 MLS 秘密。终端或内容密钥泄漏、恶意参与者录音、错误确认 SAS、恶意客户端更新仍可破坏内容安全；当前对称媒体加密也不提供对恶意群成员的逐帧独占签名认证。已交付明文和旧密钥无法撤回。

## 服务端集成

Go 主进程持有业务库、独立的授权 SQLite 和 Ed25519 签名密钥。以下端点与其他业务共用 HTTP 监听地址，公开 Compose 的容器端口为 18115。[服务组装](../internal/application/application.go) · [授权处理器](../internal/authorization/server.go)

| 路由 | 行为 |
| --- | --- |
| `POST /authorization/v5/append` | 验证设备签名与当前日志状态，追加登记、撤销或社交事件 |
| `POST /authorization/v5/snapshot` | 返回绑定 origin、随机挑战及原始载荷摘要的签名快照 |
| `GET /authorization/healthz` | 单独检查授权 SQLite，正常时返回 204 |
| `GET /healthz` | 同时检查业务及授权 SQLite |

授权操作不以浏览器 Cookie 或业务 Bearer 代替设备签名。模块不持有 MLS、媒体、附件或文字解密秘密。关闭服务时等待后台任务并关闭授权库。缺失、错误或权限不符的签名密钥导致启动失败，不自动生成替代密钥。

四端打包同一份授权公钥。开源发布流水线在本地构建镜像，用镜像内置的公开 seed 核对标签源码的公钥，再用根目录 Compose 验证授权端点。私有部署可在运行时挂载自己的 seed，并向用户分发使用配套公钥构建的客户端。[更换授权密钥](authorization-keys.md) · [开源发布](publishing.md)

## 身份核验与准入

1. 未核验设备只交换公开身份、证书、SAS 和状态控制消息，禁止临时语音、文字、附件及 MLS Welcome。
2. 双方当面或通过独立认证渠道核对完整三组 SAS，不能用待核验通话完成核验。
3. 信任绑定 origin、账号根和具体设备公钥；有效证书、好友名称、账号 ID 和服务端 ready 均不能代替信任。
4. 客户端批准精确名单，绑定本次 entry、设备、MLS 公钥与授权状态；Rust 在 Create/Join 前再次检查名单，Welcome 内成员集合也必须完全一致。
5. 建钥前批准名单，建钥后全员签署相同名单和确认值，最后开放内容。成员改变先停止内容、退役旧密钥，再重新建钥。
6. 四个平台均从构建资源固定授权公钥。Windows 的原生构建脚本复制 Apple 共享资源，Android 的 Gradle 任务验证并打包同一公钥。授权地址由当前已确认的 Passkey origin 派生为 `/authorization/v5/`，更换服务器后重新派生。同公钥部署可共用预编译客户端。更换密钥需要重新构建并分发使用新公钥的客户端。[公钥资源](../Client/apple/Shared/Resources/AuthorizationTrust.json) · [Windows 打包](../Client/windows/scripts/Build-Native.ps1) · [Android 打包](../Client/android/app/build.gradle.kts)

各端的快照和群组检查可分别从 [Apple RoomIdentity](../Client/apple/Shared/RoomIdentity.swift)、[Apple GroupSession](../Client/apple/Shared/GroupSession.swift)、[Windows 授权检查](../Client/windows/engine/authority_windows.go)、[Windows 房间状态机](../Client/windows/engine/room_windows.go)、[Android 账号身份](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/data/AccountIdentity.kt)及[Android 群组协调](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/media/SecureGroup.kt)追踪。建钥和本地密钥材料的时限由[共享 Rust MLS](../Client/apple/MLS/native/src/lib.rs)再次检查。

## 授权日志、撤销与新鲜度

每条事件使用 V5 签名域、严格递增版本及前一记录摘要。验证顺序是之前已验证状态、签名者当时权限、操作签名及新状态。授权库以 CAS 防止并发写入覆盖已提交撤销。根签名证书启动账号，后续设备须由仍有效且有登记权限的设备授权；撤销设备永久留作墓碑，已登记的其他设备保留独立状态，恢复不能复活原撤销设备。

每份快照请求提交规范 origin、32 字节随机 nonce 和 1–2 个不同账号根。响应为 Base64 载荷和签名，载荷包含各根完整有序的历史。客户端独立派生链头并检查已保存前缀。自己的完整社交正文需要有效本人设备读证明，其他读者取得签名绑定的摘要。读取证明接受与服务端时间相差最多 60 秒的签名时间，每次仍重新校验设备权限。[签名请求与快照格式](../internal/authorization/server.go)

追加相同版本、相同事件摘要可幂等重试。竞争写入导致链头冲突时，客户端重取快照再签名。每个账号最多登记 128 台设备。事件总数最多 8192，普通登记与社交事件只能使用前 4096 个版本。服务端还对序列化文档大小设限，为撤销保留容量。[日志状态机](../internal/authorization/protocol.go)

每 20 秒刷新挑战，响应最多有效 60 秒，从发出请求的连续时钟开始，包含延迟与休眠；分批快照取最早截止。旧挑战、HTTP 200、短分页或不完整历史不能续期。无法获得有效快照则停止内容。本机撤销意图立即持久化，已知撤销和检查点不能被旧响应清除；服务器确认前不能显示全局提交完成。

主服务被攻陷后能重新签名尚未被本机识别为过期前缀的旧历史，因此上述机制仍保护本地已见历史及传输重放，不能保证未知撤销传播。业务黑名单只能缩减权限，不能增加信任或代替有效授权快照。

## 客户端强制换钥与媒体

默认服务端每 60 秒例行换钥。客户端从首次创建或解出本轮密钥起计时，90 秒主动重建，120 秒硬期限。候选轮最多准备或切换 15 秒。Apple 旧接收槽最多再保留 1 秒，且受原租约和原密钥截止时间约束。心跳、lease、相同 epoch、重新安装、重连及休眠不能重置密钥年龄。

Apple 客户端在安全暂停时先撤销内容授权并清理当前和候选 MLS 轮，再等待音频设备暂停。已订阅的音轨保留订阅，恢复播放需要本机验完全员就绪签名并取得当前轮的有效租约。平滑换钥时，迟到的旧轮租约不能开启新接收槽。

Apple 在 WebRTC 解码前校验 Opus 帧的 AES-GCM 标签，并按发送成员和实际密钥记录已接收的 96 位 IV。同一密钥下的重复帧跨订阅丢弃，首次收到的乱序帧可正常解密。每个成员每把密钥最多接收 65,536 个不同 IV，达到上限后丢弃其余帧，直至换钥。发送帧格式保持兼容。

内容可用的截止时间取媒体 lease、登录／设备期限、授权快照和密钥期限的最小值。共享 Rust 库拒绝导出超龄材料。Apple 的 PCM 采集逐帧检查连续时钟，独立线程约每 20 毫秒作废到期原生提供器，排队的可靠消息在实际出队前重新验证授权。Android、Windows 分别在各自的媒体和数据路径执行门控。[Android 媒体密钥](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/media/VoiceKeys.kt) · [Windows 媒体处理](../Client/windows/engine/media_windows.go)

没有改写 WebRTC C++ 加密器实现每个编码帧的绝对硬期限。已进入编码器、网络和播放队列的内容无法追回；轮询、调度及内存清理都不构成硬实时或取证级擦除保证。媒体使用 MLS exporter 派生的发送者材料，内容不通过服务端分发解密密钥。换钥需要全新秘密与经过核验的成员集合。

## 验证入口与边界

| 检查 | 证明范围 |
| --- | --- |
| 在支持 race 的 Linux／macOS 上运行 `go test -race ./...`、`go vet ./...` | 统一路由、签名挑战、事件权限、撤销、并发 CAS、持久化、缺钥拒绝启动及健康检查。读取签名 seed 的用例要能表达 POSIX 0400／0600 文件权限 |
| GitLab 标签作业中的镜像校验和 Compose 冒烟 | 使用成品镜像验证 seed 与公钥匹配，启动 app 和 LiveKit 并检查授权端点。[执行脚本](../scripts/publish-open-source.sh) |
| 在 macOS 运行 `swift test --package-path Client/apple --scratch-path .build/swift-core` | Apple 共享授权、身份、群组、发送门控及本地撤销等状态机 |
| 在 macOS 运行 `python3 scripts/test-v5-authorization.py` | Swift 客户端经统一 Go 主服务完成登记、私密及公开视图、多根读证明、撤销和挑战验证 |
| 在 macOS 分别运行 `python3 scripts/test-v5-key-age.py` 和 `python3 scripts/test-v5-key-age.py --candidate` | 验证长服务端轮换周期下的客户端主动换钥，以及候选轮超时后的旧钥退役 |
| Apple 工程检查与两个 App 构建 | 检查共享代码、资源归属及 iOS、macOS 平台编译。[Apple 开发指南](../Client/apple/README.md) |
| Windows 原生协议回归 | 使用真实 MLS DLL 验证协议引擎，部分用例需要本机 SFU。[Windows 验证](../Client/windows/doc/README.md) |
| Android 的 `python3 scripts/test-android-protocol.py --serial SERIAL` | 在已准备的模拟器或设备上验证真实 Go 接口。双模拟器及本地 SFU 模式的准备与参数见 [Android 测试](../Client/android/docs/testing.md) |

`scripts/test-ci.py` 覆盖旧的构建及 SSH 部署脚本，`scripts/test-v5-docker.py` 使用 `deploy/compose.yaml` 的源码构建环境。2026-11-17 的 Go、Apple 和 Docker 验证记录属于当时版本。真实设备上的 Passkey、双向通话、锁屏、切网及上线后的 TLS/WSS/UDP 需在目标环境复测。[开发与验证](development.md) · [人工验收清单](manual-testing.md)
