# Android 客户端开发手册

Android 版使用 Kotlin、Jetpack Compose 和 Core-Telecom，支持 Android 15（API 35）及以上的 arm64-v8a、x86_64 设备。客户端从用户确认的服务地址发现 API，通过系统浏览器完成 Passkey 登录，使用本机设备身份加入加密语音房间。部署自己的服务端请从[快速部署指南](../../deploy/README.md)开始。

## 构建和安装

在 Android Studio 打开 `Client/android`。准备 JDK 27.0.1、Android SDK Platform 37.2、Build Tools 37.0.0、NDK 30.0.16248370、CMake 4.1.2 以及 Rust 1.100.0。命令行还需要 Git、`patch`、Python 3.12+ 和 Android Platform Tools。设置 `JAVA_HOME` 与 `ANDROID_HOME`，让 `adb`、`cargo` 和 `patch` 可在终端中运行。[JDK 版本](.java-version) · [应用构建配置](app/build.gradle.kts) · [Rust 工具链](../../rust-toolchain.toml)

在 `Client/android` 下运行以下命令。Windows PowerShell 把 `./gradlew` 换成 `.\gradlew.bat`。

```sh
rustup target add aarch64-linux-android x86_64-linux-android
./gradlew :app:assembleDebug testDebugUnitTest :app:lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Release 使用 `./gradlew :app:assembleRelease`，产物是 `app/build/outputs/apk/release/app-release.apk`。此分支随源码分发 **Chirp Open Source** 的 APK 签名私钥与口令。APK 的来源还需要通过可信的分发渠道确认。正式包的证书指纹、构建配置和校验命令见[开源版签名说明](signing/README.md)。

应用 ID、`versionName`、`versionCode`、服务端收到的 `CLIENT_BUILD` 和目标 API 均在应用模块定义。Gradle 包装器及版本目录分别固定 Gradle、AGP、Kotlin 与库依赖。[应用模块](app/build.gradle.kts) · [Gradle 包装器](gradle/wrapper/gradle-wrapper.properties) · [依赖版本](gradle/libs.versions.toml)

## 实现

| 要查的行为 | 实现入口 |
| --- | --- |
| 服务发现与登录 | 接收完整 HTTPS 地址，在该地址请求 `v1/client-config`。浏览器 Passkey 登录回到 `cn.youzifeile.chirp.android://auth/callback`，应用用 PKCE 兑换授权码。[服务请求](app/src/main/kotlin/cn/youzifeile/chirp/data/ServerRepository.kt) · [回调注册](app/src/main/AndroidManifest.xml) |
| 身份建立、换机与授权 | Android Keystore 保护设备材料，首次绑定或恢复使用 `.chirpkey`，已有设备可通过二维码配对。客户端使用 APK 内的 `AuthorizationTrust.json` 校验授权服务的签名历史，Gradle 从四端共享的资源生成该文件。[本机身份](app/src/main/kotlin/cn/youzifeile/chirp/data/DeviceIdentity.kt) · [配对](app/src/main/kotlin/cn/youzifeile/chirp/data/DevicePairing.kt) · [授权密钥说明](../../docs/authorization-keys.md) |
| 入房、互认与轮换 | Kotlin 协调当前名单、设备核验及短时发送许可，JNI 调用与其他客户端共用的 Rust OpenMLS。若有未核验设备，房间须先完成互认和配钥。[群组协议](app/src/main/kotlin/cn/youzifeile/chirp/media/GroupTransport.kt) · [共享原生库](../apple/MLS/native/) · [媒体许可](app/src/main/kotlin/cn/youzifeile/chirp/media/MediaPermit.kt) |
| 语音与后台通话 | Core-Telecom 处理系统通话和路由，前台服务维持进行中的通话。LiveKit/WebRTC 处理媒体，发送和接收都受当前媒体许可约束，接收端先验证帧再解码。[通话服务](app/src/main/kotlin/cn/youzifeile/chirp/media/CallService.kt) · [房间媒体](app/src/main/kotlin/cn/youzifeile/chirp/media/RoomMedia.kt) · [语音密钥](app/src/main/kotlin/cn/youzifeile/chirp/media/VoiceKeys.kt) |
| 聊天、附件与界面 | 文字和附件描述经加密房间数据通道交换。附件分块加密后单独传输，文件密钥仅在本次入房有效。界面负责设备核验、音量、附件预览及本机缓存管理。[房间聊天](app/src/main/kotlin/cn/youzifeile/chirp/media/RoomChat.kt) · [附件合同](../../docs/attachments.md) · [主导航](app/src/main/kotlin/cn/youzifeile/chirp/ui/ChirpApp.kt) · [Android 设计](../../design-system/chirp-together/pages/android.md) |

Gradle 校验 LiveKit Android 源码再应用 Chirp 补丁。CMake 为两个 ABI 构建 MLS、语音及 RNNoise 原生库。更新 SDK、NDK 或 WebRTC 时，两种 ABI 都需要验证真实的加解密音轨。[LiveKit 构建](livekit/build.gradle.kts) · [原生构建](app/src/main/cpp/CMakeLists.txt) · [RNNoise 准备脚本](../../scripts/prepare-rnnoise.py)

默认采集使用 WebRTC 回声消除和 RNNoise。可在声音设置切换到 WebRTC 内置降噪或仅回声消除，再使用本机麦克风测试试听。语音激活默认关闭，初始阈值 −45 dBFS。诊断记录由用户在本机启用，可导出最近 24 小时的 `.chirplog`。[采集预设和门控](app/src/main/kotlin/cn/youzifeile/chirp/media/CaptureSettings.kt) · [日志格式](../../docs/chirplog.md)

## 联调与验证

1. 首次登录时在应用中输入部署的 HTTPS 地址。若时间校验阻止登录，检查手机的自动时间和 UDP 123 的连通性。Debug 包也允许环回 HTTP。`adb reverse` 可转发本机 HTTP 和信令端口，媒体仍需到达 LiveKit 的 UDP 端口。[时间校验](app/src/main/kotlin/cn/youzifeile/chirp/data/NetworkClock.kt)
2. 两个已审批账号登录、保存恢复文件、进入同一房间，双方通过可信渠道核对三组数字。待房间就绪后解除静音、双向收听、发送文件，再验证离房清理。Android 17 访问局域网服务时可在「我的 → 使用偏好」授予局域网权限。[人工测试](../../docs/manual-testing.md)
3. 单元测试、设备测试 APK 的安装、双模拟器及临时 Go/LiveKit 联调命令集中在[Android 测试手册](docs/testing.md)。蓝牙、锁屏、扬声器路由和后台通话需在真机验收。

## 历史记录

基线提交、当时的实现差异和实测数据随报告保存。开源版签名与当前依赖请使用上面的构建入口核对。



