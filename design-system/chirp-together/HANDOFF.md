# Windows 与 Android 设计交接

## 当前完成范围与下一步

Windows 端采用 WinUI 3，桌面结构参照 macOS。各端的实现及参考截图见对应平台手册。

当前 Windows 客户端使用 V5 设备身份、好友互认与群组协议。构建和联调见 [Windows 手册](../../Client/windows/doc/README.md)。

| 平台 | 当前基准 | 后续工作 |
| --- | --- | --- |
| macOS | SwiftUI，参考源码与 Mac 原生截图 | Windows 桌面布局与信息层级的基准 |
| iOS | SwiftUI，参考 iPhone 截图 | 移动端文案与身份、通话流程的参考 |
| Web | 共享 `theme.css`，认证与管理页 | 共享语义色、认证反馈与表单层级参考 |
| Windows | C# / WinUI 3、WASAPI、原生 OpenMLS | 测试窗口缩放、系统主题、键盘导航及真实设备互认 |
| Android | Kotlin、Compose、Material 3 与 V5 群组 | 验证 Android 与 iOS 真机互认、连续换钥和音频路由 |

Windows 使用主题资源字典及系统高对比度画刷。Android 的主题适配见 [Android 规范](pages/android.md)。

iOS 与 Android 手机使用「房间／好友／我的」三个入口。macOS 在主侧栏显示好友，并使用独立系统设置窗口。2026-11-16 的房间截图用于查看当时的布局，设置与好友布局见 [2026-11-17 截图](previews/apple-settings-2026-11-17/README.md)。Windows 桌面已有 WinUI 实拍和独立拍摄记录。[Windows 截图](previews/README.md#windows-桌面客户端)

## 阅读顺序与决策依据

1. 阅读 [MASTER.md](MASTER.md) 与 [design-tokens.json](design-tokens.json)。令牌负责精确数值，Master 负责共用语义与交互。
2. 阅读目标平台的 [Windows](../../Client/windows/doc/winui-design.md) 或 [Android](pages/android.md) 规范；平台差异写在这里。
3. 查看 [截图索引](previews/README.md) 与相应图片。Mac 主窗口是桌面基准；成员／聊天参考图是独立组件示例，不是完整三栏通话截图。
4. 打开平台规范中链接的 Apple 和目标平台源码，确认状态、布局与操作条件。
5. 需要额外的组件参考时，可用本机的 `ui-ux-pro-max` 定向检索。把实现差异和验收结果写进对应平台规范。

截图中的文字是合成示例。灰色「加入」和不可用聊天入口来自离线模式；正式界面以真实连接、加密、媒体和权限状态控制可用性。不要把截图中的示例姓名、人数或禁用状态写死。Mac 顶栏的紫色系统共享指示也不属于 Chirp 的设计元素。

## 在 Windows 使用已安装的技能

在 Codex 中明确调用 `$ui-ux-pro-max`，并让它先读取本目录。技能由同事在本机安装，仓库不包含整套技能数据库。不要沿用原作者 `/Users/...` 的路径。

以下 PowerShell 片段仅定位常见的本地技能安装位置并执行检索；若技能安装在其他位置，按 Codex 的技能清单改为实际路径。命令从仓库根目录运行。

```powershell
$chirpCodexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$chirpUxSkill = Join-Path $chirpCodexRoot 'skills\ui-ux-pro-max'
$chirpUxSearch = Join-Path $chirpUxSkill 'scripts\search.py'
if (-not (Test-Path -LiteralPath $chirpUxSearch)) { throw '请先安装 ui-ux-pro-max，或按本机技能清单修正路径。' }
Get-Content -Raw -LiteralPath (Join-Path $chirpUxSkill 'SKILL.md')
python.exe $chirpUxSearch 'keyboard focus desktop' --domain ux
python.exe $chirpUxSearch 'adaptive navigation layout' --stack winui
python.exe $chirpUxSearch 'adaptive navigation accessibility' --stack jetpack-compose
```

Windows 原生客户端使用 `winui` 栈，Android 使用 Chirp 家族配色和 Compose Material 3 组件。各端的配色和组件层级以平台说明为准，有具体交互问题时可按 `ux` 或 `icons` 定向检索。Windows 已实现的页面与实机截图见 [Windows 规范](../../Client/windows/doc/winui-design.md)。

## 可直接复制给 Codex 的任务

### Windows

> 对照 Mac 房间、好友和聊天操作检查 WinUI 3 窗口，验证浅深色、中英文、紧凑布局和键盘焦点，并在安装包内复核登录和语音。

### Android

> 使用本机 Material 3 技能和 Android 平台规范维护 Compose 界面。检查家族配色的明暗模式、系统对比度、导航、窗格、输入法与大字号，结合共享文案处理登录、核验与通话状态。在专用模拟器运行界面测试和本机服务联调。[Android 规范](pages/android.md)

## 实施与验收边界

分阶段提交可评审结果：语义主题 → 登录 → 房间与成员 → 聊天／附件 → 设置与异常状态。每阶段使用真实页面和状态；可以增加明确标记的 Debug fixture，但不生成可用于真实服务的伪凭据，也不自动开麦。

家族化适配保留配置发现、Passkey／设备授权、凭据、MLS、加密媒体、音频路由、缓存撤销和附件状态机。视觉测试与真实语音／文件联调分别记录；离线截图不能证明媒体连通。既有安全和功能合同以[架构](../../docs/architecture.md)、[安全说明](../../docs/security.md)、[附件合同](../../docs/attachments.md)及各客户端测试文档为准。

最终交接附：实际 Git SHA、工具链、包／设备、窗口逻辑尺寸或 dp、缩放／字号、语言／主题／状态、执行与跳过的检查。将新平台截图及来源补到 `previews/manifest.json` 和截图索引；新增 UI 词条同步中英文。具体平台检查见各自规范。
