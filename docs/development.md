# 开发与验证

从 GitHub 的 `main` 取得发布快照后，在仓库根目录执行本页命令。Go 模块沿用 `gitlab.youzifeile.cn/chirp/chirp-go` 作为导入路径，模块内的包从本地源码解析。按要改的组件准备下表中的工具链。[公开源码](https://github.com/YouZiFeiLe/Chirp) · [架构指南](architecture.md) · [成品服务部署](../deploy/README.md)

## 工具链与依赖来源

| 要改的组件 | 开发环境与依赖入口 |
| --- | --- |
| Go 后端、管理台、Passkey 页 | Go 1.27.4，Node.js 用于网页测试。业务、群组和测试夹具属于同一个 Go 模块，LiveKit / Pion 的替换项也在其中。[go.mod](../go.mod) · [Go 校验脚本](../scripts/test-sqlite.sh) |
| 四端共用的加密库 | Rust 1.100.0、OpenMLS 0.9.2。Apple、Android 的构建目标在根工具链中，Windows 使用 MSVC 目标。升级原生依赖要更新锁文件、重建相应平台库及第三方声明。[工具链](../rust-toolchain.toml) · [Windows 目标](../Client/windows/rust-toolchain.toml) · [Cargo.toml](../Client/apple/MLS/native/Cargo.toml) · [锁文件](../Client/apple/MLS/native/Cargo.lock) |
| macOS / iOS | Apple Silicon Mac、Xcode 27、Swift tools 6.4。准备脚本下载锁定的 LiveKit SDK、应用仓库补丁，并准备 RNNoise 与 MLS XCFramework。[Apple 构建手册](../Client/apple/README.md) · [Swift 包](../Client/apple/Package.swift) · [SDK 准备脚本](../scripts/prepare-livekit-swift.py) |
| Android | JDK、Android SDK / NDK、CMake 与 Rust。精确版本及 ABI 在项目清单中，Gradle Wrapper 随仓库提供。[Android 构建手册](../Client/android/README.md) · [应用清单](../Client/android/app/build.gradle.kts) · [依赖版本](../Client/android/gradle/libs.versions.toml) |
| Windows | Windows 11 x64、.NET、Windows App SDK、MSVC、Go、Rust。原生构建脚本组装协议子进程、媒体与密码库。[Windows 开发手册](../Client/windows/doc/README.md) · [NuGet 清单](../Client/windows/Directory.Packages.props) · [构建入口](../Client/windows/Chirp/Chirp.csproj) |
| 容器 | 支持 `linux/amd64` 的 Docker 引擎和 Compose。公开镜像来自 `public` 目标，依赖及运行用户在 Dockerfile 中声明。[Dockerfile](../deploy/Dockerfile) · [公开 Compose](../compose.yaml) |

## 本机启动与发现

在 Linux 或 macOS 运行以下命令可得到独立的开发实例。Go 服务在回环地址启动，签名密钥、数据库、临时媒体凭据和日志均放入新目录。此例可验证 Web、数据库和发现接口，完整媒体测试另需 LiveKit。

```sh
mkdir -p .build
sh scripts/go.sh build -o .build/chirp ./cmd/chirp
chirp_bin="$PWD/.build/chirp"
chirp_run="$(mktemp -d "${TMPDIR:-/tmp}/chirp-dev.XXXXXXXX")"
install -m 600 deploy/authorization-key.default "$chirp_run/authorization-key"
(
  cd "$chirp_run" || exit 1
  exec env -i PATH="$PATH" \
    CHIRP_DATABASE_PATH=chirp.db CHIRP_PUBLIC_ORIGIN=http://localhost:18115 \
    LIVEKIT_HTTP_URL=http://127.0.0.1:7880 LIVEKIT_API_KEY=chirp \
    CHIRP_LIVEKIT_KEYS_FILE="$PWD/livekit-keys.json" "$chirp_bin" serve
)
```

在第二个终端检查，依次应得到 `status=ok` 的 JSON、HTTP 204、含 `protocol_version: 5` 的配置。最后一个请求示范使用当前 Windows 客户端上报的三项版本头，日后以实际平台的构建值为准。用 Ctrl+C 结束开发实例。[版本头来源](../Client/windows/engine/network_windows.go) · [发现处理器](../internal/httpapi/client_config.go)

```sh
curl --fail http://localhost:18115/healthz
curl --fail --include http://localhost:18115/authorization/healthz
curl --fail -H 'X-Chirp-Platform: windows' -H 'X-Chirp-Version: 2026.11.23' \
  -H 'X-Chirp-Build: 1' http://localhost:18115/v1/client-config
```

## 后端与网页检查

在 Linux 或 macOS 安装 C 编译器并启用 cgo 后，运行竞态检测、所有 Go 包测试和 vet。脚本使用隔离的 SQLite 文件，Go 缓存默认置于 `.build`，可通过 `GOCACHE` 和 `GOMODCACHE` 覆盖。[测试脚本](../scripts/test-sqlite.sh) · [Go 包装脚本](../scripts/go.sh)

```sh
sh scripts/test-sqlite.sh local
node --test internal/webui/i18n_test.mjs internal/webui/client-version_test.mjs internal/passkeyhttp/native-login_test.mjs
```

原生 Windows 可直接验证路由、准入、数据库及网页。签名 seed 要求 POSIX 的 `0400` 或 `0600` 权限，运行包含权限用例的完整套件请使用 Linux 文件系统或 Linux 容器。`sh scripts/test-sqlite.sh docker` 会构建 `test` 目标并运行 Go 竞态测试、vet 以及仓库保留的旧部署脚本回归。[密钥校验](../internal/authorization/key.go) · [Docker 测试目标](../deploy/Dockerfile)

```powershell
go run ./cmd/chirp version
go test ./internal/httpapi ./internal/passkeyhttp ./internal/adminhttp ./internal/group ./internal/store
go vet ./...
node --test internal/webui/i18n_test.mjs internal/webui/client-version_test.mjs internal/passkeyhttp/native-login_test.mjs
```

## 客户端与共享库验证

| 改动 | 从哪里验证 |
| --- | --- |
| Windows 协议与桌面 | 在 Windows x64 运行 `pwsh -NoProfile -File Client/windows/scripts/Build-Native.ps1 -Test`、`dotnet run --project Client/windows/tests/DesktopBehavior.csproj -c Release`。双客户端媒体测试需要本机 LiveKit 可执行程序。[Windows 开发手册](../Client/windows/doc/README.md) |
| Android 界面、业务与媒体 | 在 `Client/android` 下运行 `./gradlew :app:assembleDebug testDebugUnitTest :app:lintDebug`，Windows 改用 `gradlew.bat`。安装 Debug APK 及测试 APK 后可从根目录运行 `python3 scripts/test-android-protocol.py --serial SERIAL`。双模拟器、真实 JNI、蓝牙及硬件测试分别有独立入口。[Android 测试手册](../Client/android/docs/testing.md) |
| 跨端签名与恢复文件 | Go 与 Swift 测试读取共同格式的 V5 身份和恢复文件向量，Apple 工程检查验证两份副本。Rust 测试覆盖 SAS、恢复容器及 MLS 边界。修改字节格式时同步运行三个语言实现的测试。[共享向量](../internal/identity/testdata) · [Rust 源码与测试](../Client/apple/MLS/native/src) · [工程检查](../Client/apple/Scripts/check-project.py) |

```sh
cargo test --locked --manifest-path Client/apple/MLS/native/Cargo.toml
```

### Apple 构建与单元测试

先在 macOS 按 [Apple 构建手册](../Client/apple/README.md) 准备 SDK、RNNoise 和三平台的 MLS XCFramework。共享 Swift 套件验证登录、通话状态、群组、聊天和附件，MediaChecks 使用应用同版 LiveKit 与 WebRTC 检查媒体适配。Xcode 中 `Chirp-macOS` 与 `Chirp-iOS` Scheme 另有真实 App 宿主测试，`Chirp-iOS-AudioUI` 用于界面与真机交互。

```sh
python3 -X utf8 Client/apple/Scripts/check-localizations.py
python3 Client/apple/Scripts/check-project.py
swift test --package-path Client/apple --scratch-path .build/swift-core
swift test --package-path Client/apple/MLS --scratch-path .build/swift-mls
swift test -c release --package-path Client/apple/Audio --scratch-path .build/rnnoise-tests
swift test --package-path Client/apple/MediaChecks --scratch-path .build/media-checks
```

调试真实硬件时按目标启用检查。提示音冷启动使用 `CHIRP_ROOM_SOUND_PLAYBACK_CHECK=1` 配合 `RoomPresencePlaybackHardwareTests`。实际麦克风测试使用 `TEST_RUNNER_CHIRP_AUDIO_HARDWARE_CHECK=1` 与 App 的 `LocalMicrophoneHardwareTests`。真机身份设置可用 `scripts/test-identity-device.py` 配合独立包标识和开发签名。多人听感、后台、切网及蓝牙需要实机记录。[Apple 手册](../Client/apple/README.md) · [真机身份测试脚本](../scripts/test-identity-device.py) · [人工验收清单](manual-testing.md)

## 隔离联调与容器验证

在已准备 Swift 和原生库的 Mac 上，从根目录用 `python3` 运行所选脚本。这些测试会创建临时账号、进程或容器，共用构建路径的 Swift 联调宜依次运行。

| 测试范围 | 入口 |
| --- | --- |
| 房间准入、群组、恢复 | [test-client-admission.py](../scripts/test-client-admission.py) 检查密码预校验、切房和旧 entry 隔离。[test-group.py](../scripts/test-group.py) 联调 Go、Swift、Rust，覆盖名单、重连、轮换及租约。 |
| 身份与授权时限 | [test-v5-authorization.py](../scripts/test-v5-authorization.py) 用临时 seed 与 SQLite 验证快照及撤销。[test-v5-key-age.py](../scripts/test-v5-key-age.py) 验证到龄主动换钥，加 `--candidate` 验证候选轮超时。 |
| 数据传输与语音 | [test-attachments.py](../scripts/test-attachments.py) 覆盖密文传输、重试、回执和回收。[test-chat.py](../scripts/test-chat.py) 通过实际 LiveKit 转发合成音源和可靠数据，可指定 `--ios-simulator UDID`，宿主需能访问测试容器的 bridge 地址。 |

本地核验开源镜像时，构建与 CI 相同的 `public` 目标，离线对照包内授权私钥和各端公钥。构建阶段也会运行 `go test ./...` 和 `go vet ./...`。Compose 集成检查分别启用 HTTP 和 DNS 验证配置，通过临时证书访问 Nginx、业务和通话信令。测试容器使用内部网络。[构建定义](../deploy/Dockerfile) · [集成检查](../scripts/test-open-source-compose.sh) · [发布流程](publishing.md)

```sh
docker build --platform linux/amd64 --target public -f deploy/Dockerfile -t chirp-server:local-check .
docker run --rm -i --network none --read-only chirp-server:local-check authorization \
  -key-file /usr/share/chirp/authorization-key.default -verify-trust /dev/stdin \
  < Client/apple/Shared/Resources/AuthorizationTrust.json
sh scripts/test-open-source-compose.sh chirp-server:local-check
```

仓库还保留了旧部署的测试。`test-ci.py` 用替身验证原构建与 SSH 部署脚本。`test-v5-docker.py` 使用 `deploy/compose.yaml`、`chirp-server:v5-local` 和固定的辅助镜像。`smoke-server.py`、`test-logging.py` 都会在 app 容器内执行 `date`，当前 `scratch` 镜像仅提供 `chirp` 可执行文件，直接套用这两项检查会失败。公开镜像的 Compose 验收步骤在本分支的发布脚本内。[旧部署测试](../scripts/test-ci.py) · [V5 容器用例](../scripts/test-v5-docker.py) · [开源发布脚本](../scripts/publish-open-source.sh)

## 设计、图标与离线预览

在 macOS 运行 `./scripts/build_and_run.sh --design-preview` 查看界面示例，`--identity-setup-preview` 和 `--attachment-transfer-preview` 展示对应流程。网页预览可独立运行 `python3 design-system/chirp-together/preview-web.py`，回环端口 18761 提供 Passkey 页，18762 的 `/admin/` 提供管理台，数据来自本地样例。视觉与交互改动按平台核对真实窗口、深浅色及中英文。[设计索引](../design-system/chirp-together/README.md) · [跨端交接](../design-system/chirp-together/HANDOFF.md) · [Apple 图标导出](../scripts/export-apple-icons.py)

## 文案与文档维护

网页词典与主题在 `internal/webui`，网页测试会检查两种语言的词条、参数和错误映射。Apple 共享界面的新错误码要同步 Swift 枚举、资源与错误码表，运行 `check-localizations.py` 后可核对覆盖。测试报告记录提交、环境、实际执行的用例及跳过项，便于区分协议回归、模拟器与真机结果。[网页资源](../internal/webui) · [Apple 错误码](../Client/apple/ERROR_CODES.md) · [人工记录格式](manual-testing.md#结果记录)

用户的整套安装流程维护在[快速部署指南](../deploy/README.md)。改动外部配置或卷布局时同步[服务运维](server-operations.md)，改路由、协议或数据格式时从[架构指南](architecture.md)找到对应专题，改发布顺序或所需变量时同步[发布说明](publishing.md)。
