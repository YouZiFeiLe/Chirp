# 截图索引与复核说明

这里归档 Chirp 的原生客户端和网页界面截图。像素尺寸、SHA-256 和来源收录在[归档清单](manifest.json)及各次拍摄的清单中。设计规范见[上级入口](../README.md)。

## Android 客户端

2026-11-20 在 Android 17 模拟器拍摄，覆盖中文手机、平板宽度、半展开折叠屏和英文大字号。登录使用正式入口，其余画面使用 Debug 的离线示例数据。[三屏概览](android-material/overview.jpg) · [截图尺寸、主题与校验值](android-material/manifest.json)

| 页面 | 实际画面 |
| --- | --- |
| 登录与房间目录 | [登录](android-material/login-light.png) · [房间](android-material/rooms-light.png) · [深色房间](android-material/rooms-dark.png) |
| 通话与聊天 | [成员与通话控制](android-material/call-light.png) · [深色聊天](android-material/chat-dark.png) · [空房间](android-material/empty-dark.png) |
| 好友与设置 | [好友](android-material/friends-light.png) · [我的](android-material/account-light.png) · [声音设置](android-material/audio-dark.png) |
| 平板与折叠屏 | [平板目录与详情](android-material/tablet-light.png) · [折叠屏半展开](android-material/fold-room.png) |
| 英文 1.5 倍字号 | [通话操作](android-material/call-en-large.png) · [横屏键盘与消息输入](android-material/ime-large.png) |

## Windows 桌面客户端

2026-11-19 使用 WinUI 3 客户端、独立测试身份和本机服务拍摄。系统显示缩放为 150%，文字大小为默认值。下表尺寸是窗口的逻辑尺寸，PNG 保留原生截图像素。[拍摄环境与各图校验值](windows-2026-11-19/manifest.json)

| 页面 | 外观与窗口 | 观察点 |
| --- | --- | --- |
| [登录](windows-2026-11-19/windows-login-light.png) | 浅色 · 1120 × 780 DIP | 品牌区、地址表单、语言和本机选项 |
| [空房间](windows-2026-11-19/windows-room-light.png) | 浅色 · 1120 × 780 DIP | 房间状态、成员区，以及入房前就可打开的声音设置 |
| [通话与聊天](windows-2026-11-19/windows-chat-dark.png) | 深色 · 1120 × 780 DIP | 静音参会者、固定通话栏和右侧消息 |
| [紧凑聊天](windows-2026-11-19/windows-chat-compact-dark.png) | 深色 · 640 × 620 DIP | 英文单栏聊天，以及「Back to call」的键盘焦点 |
| [好友](windows-2026-11-19/windows-friends-light.png) | 浅色 · 1120 × 780 DIP | 搜索和添加第一位好友的入口提示 |
| [设置](windows-2026-11-19/windows-settings-light.png) | 浅色 · 1120 × 780 DIP | 账户资料、使用偏好、外观、语言和安全设置 |

上面六张页面截图拍摄于标题栏调整前。当前 Release 的标题栏见[实机局部截图](windows-2026-11-19/windows-titlebar.png)。右键标题栏或按 `Alt+空格` 可打开系统窗口菜单。

## 最新设置与好友页面

2026-11-17 新版见 [Apple 设置与好友页面](apple-settings-2026-11-17/README.md) 与独立 [manifest](apple-settings-2026-11-17/manifest.json)。包含 Mac 独立设置窗口、两端主界面好友、设备卡片、用户与设备指纹黑名单，以及空黑名单。下面的旧设置截图保留为历史资料，不再作为这些页面的布局依据。

## Mac：Windows 桌面适配的主要依据

2026-11-16 使用 macOS Debug 设计预览应用拍摄。主窗口为 1120 × 780 pt，PNG 为 2240 × 1560 px（2×）。最小内容区域为 900 × 620 pt；本机系统工具栏占 52 pt，实际最小窗口截图为 900 × 672 pt／1800 × 1344 px。平台系统装饰可能不同，Windows 按自己的内容区域和窗口缩放验证。

| 场景 | 浅色 | 深色 | 用途 |
| --- | --- | --- | --- |
| 房间主窗口 | [浅色](mac-room-light.png) | [深色](mac-room-dark.png) | 侧栏、房间标题、目录成员与固定底栏的主基准 |
| 空房间 | [浅色](mac-empty-light.png) | [深色](mac-empty-dark.png) | 紧凑横向空状态；声音设置直接位于底部固定栏 |
| 最小窗口的空房间 | [浅色](mac-empty-minimum-light.png) | [深色](mac-empty-minimum-dark.png) | 空状态完整、声音设置与入房入口均可达 |
| 声音设置打开 | [最小窗口内打开](mac-audio-minimum-light.png) | — | 原生滚动表单，固定关闭／应用栏 |
| 声音设置滚到底部 | [底部状态](mac-audio-minimum-bottom-light.png) | — | 长表单可以滚到底，底部操作未被遮挡 |
| 旧设置入口分组（历史） | — | [深色](mac-settings-dark.png) | 记录 2026-11-16 的入口；当前设置以 2026-11-17 独立设置窗口为准 |
| 成员状态组件 | — | [深色](mac-member-states-dark.png) | 独立组件参考中的说话／静音／开麦状态 |
| 聊天组件 | — | [深色](mac-chat-reference-dark.png) | 独立组件参考中的房间卡片和收发消息气泡 |

主窗口用离线目录数据运行，未建立真实通话，因此「加入」与聊天入口禁用，目录成员显示「房间成员」。请按源码中的真实状态条件实现正式按钮与成员状态。两张组件图来自可横纵滚动的组件 sheet，只展示局部组件；其中声音摘要卡不是新版 Mac 房间页的布局依据，房间声音入口以主窗口固定底栏为准。当前未归档完整三栏实时聊天和单独的 Mac 登录截图；登录参考 [LoginView.swift](../../../Client/apple/Shared/Views/LoginView.swift)，聊天几何参考 [MacRoomChatLayout.swift](../../../Client/apple/Shared/Views/MacRoomChatLayout.swift)。

紫色窗口共享指示和交通灯由 macOS 提供，不属于 Chirp 品牌。声音设置图中的设备名称取自本机设备列表，未开启麦克风测试。系统材质、激活／失焦状态可能影响控件颜色，勿从截图取色替代语义令牌。

复核步骤（Mac，从仓库根目录）：

```sh
./scripts/build_and_run.sh --design-preview
```

1. 「预览选项 → 外观」选浅色或深色；「窗口尺寸」选默认或最小窗口。预设受原生内容最小尺寸约束。
2. 选「朋友客厅」查看目录成员，选「一起专注」查看密码房间的空状态。
3. 从固定底栏打开「声音设置」，滚到底并关闭；无需改变预设或启动采集。
4. 「组件参考」可横纵滚动查看成员状态与聊天气泡。保存窗口截图并记录实际尺寸。

这次复核覆盖默认／最小窗口、浅深色、空房间、声音入口和长表单滚动。没有用离线图代替真实通话、权限、媒体连通或完整键盘／VoiceOver 验收。

## iOS 手机界面参考

本节旧版图片来自 iPhone 17e 模拟器上的真实应用界面，以正常字号作为房间布局基准。当前 iOS 已改为「房间／好友／我的」三项导航，设置与好友以[新版截图](apple-settings-2026-11-17/README.md)为准；旧图中的两项导航不代表当前 iOS。归档 JPEG 是工具优化后的预览尺寸，不是设备原始像素；不要用图片像素反推 Android dp 或触控尺寸。

| 场景 | 图片 |
| --- | --- |
| 登录 | [浅色](ios-login-light.jpg) |
| 房间目录 | [浅色](ios-rooms-light.jpg) · [深色](ios-rooms-dark.jpg) |
| 房间成员 | [浅色](ios-room-light.jpg) |
| 空房间顶部概览 | [浅色](ios-empty-overview-light.jpg) · [深色](ios-empty-overview-dark.jpg) |
| 空房间滚动底部 | [浅色](ios-empty-light.jpg) · [深色](ios-empty-dark.jpg) |
| 旧版我的／设置（历史） | [浅色](ios-settings-light.jpg) · [深色](ios-settings-dark.jpg) |

空房间四张图于 2026-11-16 在 iOS 27.2 的 iPhone 17e Debug 离线预览中补拍，房间为「一起专注」、成员数为 0。顶部概览保留完整房间标题；滚动底部的两张图展示完整空状态、声音设置卡片及固定入房栏。它们是两个真实滚动位置，不是拼接长图。此次同时修正 iOS 房间页的底部安全区域留白，滚动到底后声音设置不会再被通话栏遮住。

复现：以 `--design-preview` 启动 iOS Debug 应用 → 选择「一起专注」→ 在预览选项切换浅／深色 → 分别保存顶部与滚动底部画面。离线入房按钮主动禁用。历史[大字体预览](ios-large-type.jpg)保留存档，不作为本轮主要设计参考或交付要求。

按 [Android 适配规范](../pages/android.md)在实际 Compose 界面重新验收；这些图不证明 Android 的系统返回、IME、TalkBack、宽屏或媒体能力。

## Web：共享品牌、认证与管理参考

网页图来自[只读离线预览脚本](../preview-web.py)，使用仓库实际 HTML／CSS／JS 与合成数据。页面图可能包含完整页面高度，宽度和高度以 manifest 的物理像素为准。

| 场景 | 图片 |
| --- | --- |
| 登录 | [浅色](web-passkey-light.png) · [深色](web-passkey-dark.png) · [手机](web-passkey-mobile.png) |
| 登录成功 | [已登录](web-passkey-signed-in.png) |
| 注册 | [桌面](web-register-light.png) · [手机](web-register-mobile.png) |
| 注册回执 | [深色](web-passkey-receipt-dark.png) |
| 设备授权 | [浅色](web-device-light.png) |
| 管理台概况 | [浅色](web-admin-light.png) · [深色](web-admin-dark.png) · [手机](web-admin-mobile.png) |
| 管理台成员／失联 | [失联与过期数据](web-admin-offline.png) |
| 申请审批 | [申请](web-admin-requests.png) |
| 房间管理 | [房间](web-admin-rooms.png) |
| 系统状态 | [系统](web-admin-system.png) |
| 客户端版本 | [版本](web-admin-versions.png) |

以上不使用生产账号或管理数据，也不能证明真实 Passkey、审批写入或服务端连接。当前脚本仍使用固定历史版本示例，且未提供设备列表与黑名单的 GET fixture；旧网页图也不能证明这些后来新增的身份管理入口已通过预览验收。

## 后续补图约定

Windows 与 Android 同事按各自[交接规范](../HANDOFF.md)交付真实运行截图，沿用 `windows-场景-主题.png`／`android-场景-主题.png` 命名。记录 Git SHA 与未提交源码、系统与设备、窗口 pt／DIP／dp、物理像素、缩放／字号、语言、主题、状态、复现操作和未测项，再更新本索引与 manifest。保留原生截图，不通过裁切隐藏溢出问题。
