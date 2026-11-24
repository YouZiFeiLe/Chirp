# Apple 客户端开发手册

macOS 和 iOS 共用 SwiftUI、身份与房间协议代码。`Chirp-macOS` 与 `Chirp-iOS` 分别管理入口、权限和签名。两个目标要求系统 27.0 及以上，当前 MLS XCFramework 提供 Apple Silicon Mac、arm64 iPhone 和 arm64 iOS 模拟器切片。[Xcode 工程](Chirp.xcodeproj/project.pbxproj) · [系统架构](../../docs/architecture.md)

## 准备与构建

在 Apple Silicon Mac 上准备 Xcode 27、Swift tools 6.4、Python 3.12+、`patch` 及 rustup。以下命令均在仓库根目录运行。首次构建需连网获取锁定的依赖。[Swift 包](Package.swift) · [Rust 工具链](../../rust-toolchain.toml)

```sh
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
python3 scripts/prepare-livekit-swift.py
python3 scripts/prepare-rnnoise.py
sh scripts/prepare-mls.sh
open Client/apple/Chirp.xcodeproj
```

在 Xcode 中选择相应 Scheme 和设备。只需运行 macOS 版时可直接执行 `./scripts/build_and_run.sh`，它会停止已运行的 Chirp、准备依赖、构建并打开 `Client/apple/dist/macos/Chirp.app`。默认使用 ad-hoc 签名。要验证设备钥匙串与本地清理，请指定拥有有效 Apple Development 证书的团队 ID。`--verify` 检查目标进程持续运行十秒。[本地运行脚本](../../scripts/build_and_run.sh)

```sh
CHIRP_MACOS_TEAM_ID='你的团队 ID' ./scripts/build_and_run.sh --verify
```

## 模块与 SDK 补丁

| 模块 | 职责与源码 |
| --- | --- |
| `Shared/`、`Shared/Views/` | 服务发现、系统认证、房间状态与 SwiftUI 界面。平台差异在两个 App 目标处理。[API](Shared/APIClient.swift) · [界面](Shared/Views/) |
| `MLS/` | Swift 通过 C 调用共享 Rust OpenMLS，管理本机群组、互认及身份恢复。四个平台共用 Rust 源码。[Swift 接口](MLS/Sources/ChirpMLS/MLSClient.swift) · [原生实现](MLS/native/src/lib.rs) |
| `Audio/`、`Voice/` | 采集后处理、RNNoise、语音帧认证与防重放。[采集流水线](Audio/Sources/ChirpAudio/CaptureAudioPipeline.swift) · [接收变换](Voice/) |
| `Shared/GroupSession.swift`、`Shared/LiveKitCallMedia.swift` | 协调群组状态、候选密钥轮换、短时媒体许可，将状态应用于实际 LiveKit 音轨与数据通道。[群组](Shared/GroupSession.swift) · [媒体](Shared/LiveKitCallMedia.swift) |
| `Tests/`、`MediaChecks/` | 共享模型、协议与替身测试，以及使用配套 SDK 和 WebRTC 的真实媒体回归。Xcode 两个 App Scheme 还运行宿主测试。[共享测试](Tests/) · [媒体测试](MediaChecks/) |

`prepare-livekit-swift.py` 校验上游 SDK 和 WebRTC 头文件归档，再将仓内补丁应用到生成的 `Vendor/`。补丁约束 ICE 来源、本地开麦意图、发送者与密钥槽的绑定、候选轮切换、接收端认证和聊天队列的最终许可。依赖升级时在应用和 `MediaChecks` 同步验证锁定的原生二进制。[SDK 准备脚本](../../scripts/prepare-livekit-swift.py) · [补丁集](Patches/) · [Xcode 锁文件](Chirp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) · [媒体测试锁文件](MediaChecks/Package.resolved)

`prepare-mls.sh` 按 Cargo.lock 构建各切片并生成 `MLS/Artifacts/ChirpMLSNative.xcframework`。`--host-only` 适用于仅测 Mac；构建 iOS 前重跑完整命令。依赖变更时重新生成随包附带的第三方许可声明。[MLS 构建脚本](../../scripts/prepare-mls.sh) · [声明生成器](../../scripts/prepare-mls-notices.py) · [声明清单](MLS/Sources/ChirpMLS/Resources/ThirdPartyNotices.txt)

## 设备、好友与身份恢复

1. 用户确认部署地址后，应用通过系统认证窗口进行 Passkey 登录，使用 PKCE 并经 `cn.youzifeile.chirp://auth/callback` 返回。macOS 也支持由手机扫描登录二维码。[登录交换](Shared/ClientLogin.swift) · [扫码登录](Shared/DeviceLogin.swift)
2. 首台设备创建账号根和设备身份，导出密码加密的 `.chirpkey` 并确认后完成绑定。已有账号可导入恢复文件或由另一台已授权设备核对三组安全码后批准配对。本机设备密钥保存在按服务来源和账号 ID 隔离的 Keychain 中。[首次设置](Shared/IdentitySetup.swift) · [本机身份](Shared/DeviceIdentityStore.swift) · [设备配对](Shared/DevicePairingSession.swift) · [恢复文件格式](../../docs/chirpkey.md)
3. 客户端使用打包在 App 内的授权公钥验证 `passkey_origin` 下授权服务的签名历史。房间检查在场设备的入房绑定和互信，等待全员完成核验与群组确认后开放内容传输。更换部署授权密钥时，重新构建并签名使用新公钥的客户端。[设备授权](Shared/AuthorizationAuthority.swift) · [房间互认](Shared/RoomIdentity.swift) · [授权密钥](../../docs/authorization-keys.md) · [V5 协议](../../docs/e2ee-v5-development.md)

## 音频处理

采集先完成回声消除、自动增益和所选降噪，再通过可选语音激活门控、Opus 编码和端到端加密。错误或撤销许可时，发送方停止交付语音。三种预设的实际生效状态由运行中的音轨回读。[应用与回读](Shared/AudioPreset+LiveKit.swift)

| 预设 | 处理方式 |
| --- | --- |
| Apple 系统处理＋RNNoise（默认） | Apple 回声消除、增益、系统降噪，之后执行 RNNoise |
| Apple 系统处理 | 全部使用 Apple 语音处理 |
| WebRTC 回声消除＋RNNoise | 使用 WebRTC 软件回声消除和增益，降噪交给 RNNoise |

语音激活默认关闭，初始阈值 −45 dBFS，可在 −80 至 −10 dBFS 间设置。声音设置里的测试与通话互斥，最长采集约十秒，最近三秒的试听样本保存在内存。真实音轨、系统中断、iPhone 输出路由和多设备通话另在真机验收。[语音激活](Shared/VoiceActivation.swift) · [本机测试](Shared/LiveKitAudioHardware.swift) · [人工验收](../../docs/manual-testing.md)

## 测试

先完成依赖准备，再按改动选择运行。涉及共享源码、资源或错误码的变更同时运行两项 Python 检查。`Chirp-iOS-AudioUI` 用于在指定设备上验证声音设置、入房信息和身份设置等交互。[工程检查](Scripts/check-project.py) · [错误码索引](ERROR_CODES.md) · [UI 测试](iOS/UITests/) · [跨端开发与验证](../../docs/development.md)

```sh
python3 Client/apple/Scripts/check-project.py
python3 -X utf8 Client/apple/Scripts/check-localizations.py
swift test --package-path Client/apple --scratch-path .build/swift-core
swift test --package-path Client/apple/MLS --scratch-path .build/swift-mls
swift test -c release --package-path Client/apple/Audio --scratch-path .build/rnnoise-tests
swift test --package-path Client/apple/MediaChecks --scratch-path .build/media-checks
```

## 签名、权限与真机安装

Xcode 工程由构建机提供团队身份。连接、配对并解锁 iPhone，开启开发者模式，使用 `xcrun devicectl list devices` 取得设备标识。已配置开发证书的 Mac 可按以下命令构建并安装。[iOS 工程配置](iOS/Info.plist) · [macOS 权限](macOS/Chirp.entitlements) · [共享隐私清单](Shared/Resources/PrivacyInfo.xcprivacy)

```sh
CHIRP_IOS_TEAM_ID='你的签名团队 ID'
CHIRP_IOS_DEVICE_ID='已连接 iPhone 的设备标识'
xcodebuild -project Client/apple/Chirp.xcodeproj -scheme Chirp-iOS \
  -configuration Release -destination "platform=iOS,id=$CHIRP_IOS_DEVICE_ID" \
  -derivedDataPath .build/DerivedData-ios-device -clonedSourcePackagesDirPath .build/apple-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$CHIRP_IOS_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build
codesign --verify --deep --strict .build/DerivedData-ios-device/Build/Products/Release-iphoneos/Chirp.app
xcrun devicectl device install app --device "$CHIRP_IOS_DEVICE_ID" \
  .build/DerivedData-ios-device/Build/Products/Release-iphoneos/Chirp.app
```

macOS 证书签名的构建保留 Hardened Runtime，应用和嵌入框架由同一团队签名。`Prepare codeless resource bundles` 阶段检查并处理 ChirpAudio、ChirpMLS 和 LiveKit 的纯资源包，由外层 App 签名保护这些文件。商店分发使用 Xcode archive / exportArchive，最终导出包须另作签名与设备验证。[资源包处理](Scripts/prepare-macos-resource-bundles.py)
