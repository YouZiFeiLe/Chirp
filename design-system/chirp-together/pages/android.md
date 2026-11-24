# Android 客户端界面

Chirp Android 使用 Jetpack Compose Material 3。浅色模式使用灰绿背景、白色卡片和深绿操作按钮，深色模式沿用 iOS 的深绿背景与薄荷绿强调色。文字和轮廓响应系统对比度设置，启动窗口沿用当前背景色。正文与控件使用 Material 字阶，中文使用系统字体回退。[主题实现](../../../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/ui/ChirpTheme.kt) · [共享色值](../design-tokens.json)

登录图形和房间详情标题共用声纹与回声环。进入时播放一次短展开动效，成员开始讲话时才点亮该成员的声纹。开麦和暂停收听的按钮会改变圆角和颜色，并保留相应文字。聊天与成员切换使用短距离滑入和淡出。动效遵循 Android 的动画时长设置。[声纹实现](../../../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/ui/SignalArtwork.kt) · [Compose 动画时长设置](https://developer.android.com/reference/kotlin/androidx/compose/ui/MotionDurationScale)

## 页面与操作

| 页面 | 主要操作与反馈 |
| --- | --- |
| 登录 | 确认服务器后，通行密钥登录使用整行实心按钮。扫码登录和注册按服务配置显示为下方带图标的文字入口，单个入口居中。右上角设置按使用偏好和设备与安全分组，已保存身份默认收起。 |
| 房间 | 顶栏展示 Chirp 标识和居中的页面标题，「你的语音空间」引导区随列表滚动。目录显示房间总数，每个房间使用同款卡片展示名称、密码要求和在线情况。打开房间可阅读名称下方的描述，点按标题卡片可查看全文。目录失去同步时显示提醒，停止展示缓存名单中的人名。 |
| 通话与聊天 | 底栏提供静音加入、开麦、收听和离开。成员详情直接显示语音状态和音量，展开连接详情可查看音轨指标。成员和聊天用主标签切换，新消息数与设备核验状态分别展示。 |
| 好友 | 支持按昵称和用户编号搜索，切换主导航会保留搜索内容。好友详情显示各设备的信任状态，点开可核对完整指纹或撤销信任。 |
| 我的与设置 | 个人资料、偏好与设备安全分组展示。设备列表显示当前设备和授权状态，展开可查看指纹、最近登录时间并管理设备。清理缓存和退出登录各有独立的确认操作。 |
| 声音设置 | 预设、语音激活和麦克风测试各自成组。输入与输出行显示当前设备，点开可切换。通话诊断保留加密状态摘要，成员明细和导出操作在展开后显示。 |
| 恢复与设备核验 | 首次设置展示密码、导出和确认的进度。房间内互认时，成员名下方并排显示三组等宽安全码，读屏按组序逐位朗读。核对操作固定在底部，确认后显示等待对方确认的状态。导入二维码后，每组安全码对应一个四位圆角输入框，使用纯数字键盘，支持整码粘贴。 |

## 窗口与文案

手机使用底部导航，房间和设置详情提供系统返回。中等及宽窗口使用自适应导航；房间的 Navigation 3 列表与详情根据 Material 的窗格指令布局。铰链分隔屏幕时，目录与详情可分处两侧，单栏表单使用较大的一侧。大窗口的表单与聊天内容限制在适合阅读的宽度。横屏输入时收起通话栏和紧凑窗口的顶部栏。[主导航](../../../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/ui/ChirpApp.kt) · [房间目录](../../../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/ui/RoomDirectory.kt)

应用弹窗使用同一套 Material 3 样式。内容可滚动，确认与取消保持在操作区。清空附件缓存、本机重置、退出登录、移除头像和撤销信任都会在确认前说明影响。

共享提示使用 Apple 的简体中文与英文资源。Gradle 构建时检查两种语言的共享文案、Android 专用资源、错误目录和格式参数。权限设置、缓存清理和房间密码使用适合 Android 流程的提示。[文案映射](../../../Client/android/app/src/main/shared-messages.json) · [生成脚本](../../../scripts/prepare-android-messages.py)

## 复核

从 Debug 的 `FeaturePreviewActivity` 打开 `rooms`，即可在实际主导航中查看示例房间、好友和账号。使用 `call` 观察成员状态、未读角标、通话操作和输入法，使用 `empty` 查看带密码的空房间。登录入口使用 `MainActivity`。初版 Material 3 的模拟器画面、主题、语言及窗口尺寸见截图记录。[Android 截图](../previews/README.md#android-客户端) · [构建与联调](../../../Client/android/README.md) · [设备测试](../../../Client/android/docs/testing.md)
