# Android 测试

当前使用 JUnit4、kotlinx-coroutines-test、Compose 设备测试和真实 JNI 检查。测试以状态和实际行为为断言；不以构建成功代替运行验证，也不把模拟器结果当作蓝牙、锁屏或多人通话听感验收。

## 协议覆盖

Android 使用与 iOS 相同的 V5 身份向量及 Rust MLS 库。单元测试校验证书、入房绑定、配对签名和 Opus 重放边界。设备测试覆盖原生音频、身份设置与真实 Go 接口。

## 构建与本地测试

使用 JDK 27.0.1，配置 ANDROID_HOME，工具链见 [Android 说明](../README.md)。在 Client/android 执行：

```sh
./gradlew testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest :app:lintDebug :app:assembleRelease
```

单元测试覆盖租约双时钟、延迟轮换激活期间续租、媒体对象保留、AES-GCM 合同及缩略图域分离、下载前缀损坏／截断、每方向带宽和取消、语音激活迟滞／保留／无效采样、三秒缓冲及成员提示事件。

LiveKit 模块的单元测试覆盖加密聊天包内外的发送者身份匹配，以及订阅端仍在连接时通过已打开的发布通道发送。两个模块的测试报告分别位于 `app/build/reports/tests/testDebugUnitTest/` 和 `livekit/build/reports/tests/testDebugUnitTest/`。Lint 报告位于 `app/build/reports/lint-results-debug.html`。

## 专用设备或模拟器

先明确选定 serial，安装当前 Debug APK 和测试 APK，再执行：

```sh
adb -s SERIAL install -r app/build/outputs/apk/debug/app-debug.apk
adb -s SERIAL install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s SERIAL shell am instrument -w cn.youzifeile.chirp.android.test/androidx.test.runner.AndroidJUnitRunner
```

- `NativeFeatureTest` 加载实际 APK 中的 RNNoise 和 MLS 原生库，验证共享恢复文件、授权名单、双槽发送者密钥及轮换。
- `PairingImageTest` 从待授权页面保存 PNG，检查图库相册、图片类型、分享入口和安全码阶段，并用授权端的图片读取器解码。
- `VoiceTransportTest` 在本机两个 WebRTC 端点间发送合成 Opus，验证初始授权和换钥后接收端恢复解密。
- `AudioSettingsTest`：在真实 Compose 声音设置点击开始、停止、停止并试听。逐一验证三个预设收到采集帧、试听进度及结束，检查页面重建不继续采集、音频选项持久化和中英文切换。会使用所选测试设备的麦克风和输出；模拟器应关闭宿主音频，使用虚拟音源。
- `SettingsLayoutTest`：400／610／900 dp 宽和 400／500／1000 dp 高、深色和 1.5 倍字体；断言控件可滚动到达，导出顶部与底部 PNG。截图位于应用外部文件目录的 `ui-checks/`，人工查看布局；不自动更新任何黄金图片。
- `CallParityTest` 覆盖账号停用、服务接管前取消、系统通话启动失败、过时通知，以及当前房间目录变更。
- `AttachmentCatalogTest` 和 `AttachmentPreviewTest` 检查乱序目录、缓存终态、关闭已打开的预览和导出入口。
- `RoomParityUiTest`、`IdentitySettingsParityTest` 和 `PreparedAvatarTest` 覆盖入房前信息、核验指纹、聊天定位、登录前身份管理及头像预览与保存。
- `GroupProtocolTest`、`AttachmentProtocolTest`、`ProductionFlowTest` 和 `PeerFlowTest` 读取隔离 fixture。这些用例在普通 instrumentation 中会跳过，按下一节选择运行模式。

WebRTC 150.7871.08 在 ARM64 和 x86_64 上使用不同的 C++ 虚函数表布局。更新 WebRTC 或 NDK 后，在两种 ABI 上各运行一次 `VoiceTransportTest`。支持 ARM64 转译的 x86_64 模拟器可以这样测试 ARM64 接收路径。

```sh
adb -s SERIAL install -r --abi arm64-v8a app/build/outputs/apk/debug/app-debug.apk
adb -s SERIAL install -r --abi arm64-v8a app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s SERIAL shell am instrument -w -e class cn.youzifeile.chirp.media.VoiceTransportTest cn.youzifeile.chirp.android.test/androidx.test.runner.AndroidJUnitRunner
```

Espresso 明确使用 3.7.0；[官方发布说明](https://developer.android.com/jetpack/androidx/releases/test#espresso-3.7.0)记录了 InputManager 调用修复，避免 Compose 传递依赖的旧版本在新系统上无法执行界面测试。

单独运行声音设置布局用例并取回 12 组配置的顶部和底部截图，可在安装两个 APK 后，从 `Client/android` 执行以下命令。[布局用例](../app/src/androidTest/kotlin/cn/youzifeile/chirp/ui/SettingsLayoutTest.kt)

```sh
adb -s SERIAL shell am instrument -w -e class cn.youzifeile.chirp.ui.SettingsLayoutTest cn.youzifeile.chirp.android.test/androidx.test.runner.AndroidJUnitRunner
adb -s SERIAL pull /sdcard/Android/data/cn.youzifeile.chirp.android/files/ui-checks ../../.build/android-ui-checks
```

## 真实 Go 群组与附件接口联调

脚本直接调用指定设备上的 instrumentation，不会构建或安装 Android APK；先按上一节安装当前 Debug APK 和测试 APK。在仓库根目录运行，必须指定专用设备序列号：

```sh
python3 scripts/test-android-protocol.py --serial SERIAL
# 同一模拟器再运行 MainActivity 通话流程。多次指定 --serial 时依次运行各模拟器。
python3 scripts/test-android-protocol.py --serial SERIAL --livekit-server /path/to/livekit-server
# 只运行 MainActivity 的单端流程。
python3 scripts/test-android-protocol.py --production-only --serial SERIAL --livekit-server /path/to/livekit-server
# 两台模拟器同时进入同一房间。先列发送端，再列接收端。
python3 scripts/test-android-protocol.py --paired --serial SENDER --serial RECEIVER --livekit-server /path/to/livekit-server
# 一台留在房内，测另一台首次核验和三次互信重入，到对端解密第一帧为止。
python3 scripts/test-android-protocol.py --startup-repeats 3 --serial SENDER --serial RECEIVER --livekit-server /path/to/livekit-server
```

脚本启动临时 Go 处理器及 SQLite 存储，通过 `adb reverse` 转发 HTTP。普通模式在每台所选设备依次运行下列五项测试，fixture 使用临时授权密钥。

- 首次登录界面测试从真实 PKCE 回调进入密码表单，通过系统文件选择器的测试回调取消和重试保存，回读校验导出的文件，再检查最终确认倒计时与返回操作。
- 身份设置从模拟的浏览器认证结果开始，验证真实的 PKCE 回调兑换、首次激活、备份回读与续办、配对、恢复、设备改名与撤销，以及前后台目录和身份同步。
- 群组测试由两个 Android 客户端完成真实三组数字互认，并通过 Go 协调器连续更换三个 epoch。测试比较两端密钥，同时检查租约和媒体对象的连续性，以及身份同步短暂失败、持续失败和恢复时的房间提示。
- 三人房间测试从三台互不信任的设备开始，覆盖同时邀请、双方互邀、第三人向任一方核验时收到「对方正忙」、旧回复和重新邀请。测试核对双方的三组数字和信任记录，再将一条身份声明延迟到接收者离房后投递，验证留下的两端没有误报、密钥匹配且语音租约有效。
- 附件：使用真实 Android 文件接口、加密和 HTTP 传输，覆盖上传中断与原密文续传、下载手动暂停与已验证前缀复用、内容一致导出、取消后不能复活，以及发布前的失败恢复。服务端撤销后还会检查已下载副本的访问和缓存清理。

提供 LiveKit 可执行文件后，脚本另启动本机 SFU，通过 `adb reverse` 转发信令，向 Android Emulator 通告可达宿主的 UDP 地址 `10.0.2.2`。单端模式从测试会话启动正式 MainActivity，覆盖头像、开麦和带密码切房。双端模式使用不同的测试账号，核对 SAS、依次开麦并验证双方持续解密，也检查文字和附件字节。接收端随后退出并重新加入，验证能继续接收房内成员的语音。两种模式都使用 APK 内置公钥，fixture 仅在该公钥与仓库默认示例 seed 匹配时运行这部分流程。测试结束后脚本释放自己的端口映射并清理临时文件。[脚本及参数](../../../scripts/test-android-protocol.py) · [单端流程](../app/src/androidTest/kotlin/cn/youzifeile/chirp/ui/ProductionFlowTest.kt) · [双端流程](../app/src/androidTest/kotlin/cn/youzifeile/chirp/ui/PeerFlowTest.kt)



## 真机验收

验证异常退出时，可在专用模拟器入房后执行 `adb -s SERIAL shell am force-stop cn.youzifeile.chirp.android`，从另一账号观察旧成员消失所需的时间。再测一次，在旧成员仍可见时重启应用并加入同一房间，检查同一账号只出现一次，并确认能收听房内成员的语音。

按[共用人工手册](../../../docs/manual-testing.md)执行 Android ↔ iOS 双向语音／附件、稳定名单连续三个换钥周期、成员变化、错误密码切房、撤销、锁屏与后台、系统来电、蓝牙／USB 热拔插、实际输入路由及噪声／回声听感。记录所测包、设备和网络；未执行项明确写未测。
