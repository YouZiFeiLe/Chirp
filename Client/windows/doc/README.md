# Windows 客户端开发手册

Windows 版使用 WinUI 3 和独立的 Go 协议进程，目标为 Windows 11 x64 24H2（内部版本 26100）及以上。以下命令都在仓库根目录的 PowerShell 7 中运行。[应用工程](../Chirp/Chirp.csproj) · [系统架构](../../../docs/architecture.md)

## 运行

安装 .NET 11 SDK、Windows SDK、Visual Studio x64 C++ 构建工具、WinApp CLI、Go、rustup、Git 和 Python 3.12+。Go 版本随 `go.mod`，Rust 使用 Windows 项目固定的 MSVC 工具链。Windows App SDK、WinApp 和其他 NuGet 版本由项目清单管理。[依赖版本](../Directory.Packages.props) · [Go 模块](../../../go.mod) · [Rust 工具链](../rust-toolchain.toml)

```powershell
& ./Client/windows/scripts/Use-DevTools.ps1
winapp run Client/windows/Chirp/Chirp.csproj --arch x64
```

`winapp run` 构建并以包身份启动应用，注册浏览器回调 `cn.youzifeile.chirp.windows://auth/callback`。只需编译时运行 `dotnet build Client/windows/Chirp/Chirp.csproj -p:Platform=x64`。两条路径都会准备 Go 协议进程、原生 DLL、授权公钥和许可证。新检出使用 PATH 上的工具。[构建入口](../Chirp/Chirp.csproj) · [原生构建脚本](../scripts/Build-Native.ps1)

启动后确认自己的 HTTPS 服务地址，通过浏览器 Passkey 或手机扫码登录。Debug 包支持环回 HTTP。若时间校验阻止登录或设备授权，核对 Windows 自动时间设置及 UDP 123 的连通性。[时间校验](../Chirp/NetworkClock.cs) · [服务端部署](../../../deploy/README.md)

## 实现

| 模块 | 职责与源码 |
| --- | --- |
| `Chirp/` | WinUI 窗口共享账号与通话状态，负责 PKCE 回调、二维码、文件选择、聊天界面、WASAPI 音频以及 Opus 编解码。[窗口与协议激活](../Chirp/App.xaml.cs) · [音频设备](../Chirp/DesktopAudio.cs) · [WinUI 设计](winui-design.md) |
| `Chirp/ProtocolClient.cs`、`engine/` | 应用启动 `Chirp.Protocol.exe`，通过标准输入/输出传递 JSON 命令与事件。Go 进程运行身份、好友、群组、短时媒体许可、LiveKit/WebRTC 和加密附件协议。[进程通信](../Chirp/ProtocolClient.cs) · [协议入口](../engine/main_windows.go) · [房间](../engine/room_windows.go) · [媒体](../engine/media_windows.go) |
| `audio/`、RNNoise | Rust 的 Sonora 实现 WebRTC AEC3 和 AGC2，本机 DLL 提供 RNNoise。默认预设使用系统通信处理，用户可启用 RNNoise 或软件 AEC。声音设置也负责本机采集、试听和输出选择。[Rust 音频模块](../audio/) · [RNNoise 构建](../scripts/Build-Audio.ps1) · [设置](../Chirp/Settings.cs) |
| 共享 Rust MLS | 四端共用 OpenMLS、SAS 及恢复文件实现。Windows 构建生成 `chirp_mls_native.dll`，本机设备材料由当前用户的 DPAPI 保护。[共享库](../../apple/MLS/native/) · [Windows 本机存储](../engine/vault_windows.go) |
| 授权与运行目录 | 构建脚本从 Apple 共享资源复制 `AuthorizationTrust.json` 到协议进程同目录。进程用它验证授权历史；使用自有签发密钥的部署需要配套构建。[验签](../engine/authority_windows.go) · [部署授权密钥](../../../docs/authorization-keys.md) |

首次登录需保存加密恢复文件，换机可导入恢复文件或由已授权设备配对。多人房间等待在场设备互认、建组和配钥，接收端验证帧后才交付音频。离房清除当次聊天与附件访问材料。持久账户身份、临时媒体许可和本机日志分别见[恢复文件](../../../docs/chirpkey.md)、[V5 协议](../../../docs/e2ee-v5-development.md)和[日志格式](../../../docs/chirplog.md)。

## 验证

```powershell
pwsh -NoProfile -File Client/windows/scripts/Build-Native.ps1 -Test
dotnet run --project Client/windows/tests/DesktopBehavior.csproj -c Release
go test ./internal/passkeyhttp ./internal/httpapi ./internal/group
```

协议用例使用临时 SQLite、HTTP 处理器、DPAPI 和实际 Rust DLL。要运行包括 `TestNativeTwoPartyRoom` 的双端语音用例，将 `CHIRP_LIVEKIT_SERVER` 设为本机 LiveKit Server 的可执行文件路径，或使用脚本识别的 `.build/windows-tools/livekit-*/livekit-server.exe`。交互夹具 `TestLocalWinUIDesktop` 需启用 `CHIRP_UI_FIXTURE`。[协议与媒体用例](../engine/client_windows_test.go) · [桌面测试](../tests/Program.cs) · [WinUI 夹具](../engine/ui_fixture_windows_test.go)

在不同设备用两个获批账号核对 SAS，再双向测试开麦、收听和附件。物理设备热插拔、Windows Hello、蓝牙及跨平台通话需要真机。[人工测试](../../../docs/manual-testing.md)

## 更新 Windows 客户端版本号

协议使用 `年.月.日` 与整数构建号，程序集和包清单使用四段版本 `年.月.日.构建号`。同步以下三处，Inno Setup 将从 `Chirp.dll` 读取安装包版本。

- `const version`、`const build` 决定 `X-Chirp-Version` 与 `X-Chirp-Build`。[协议字段](../engine/network_windows.go)
- `<Version>` 用于程序集与安装器，清单的 `Identity Version` 用于 MSIX。[程序集项目](../Chirp/Chirp.csproj) · [包清单](../Chirp/Package.appxmanifest) · [安装器](../installer/Chirp.iss)

## 生成 Windows 安装包

**Setup.exe** 是当前用户安装版，构建机需要 Inno Setup 7。将 `ISCC.exe` 加入 PATH 或设置 `CHIRP_ISCC` 后执行以下命令。脚本输出 `.build/releases/Chirp-Windows-<版本>-x64-Setup.exe`，包含 .NET、WinUI 运行时和原生组件。[安装器脚本](../scripts/Build-Installer.ps1)

```powershell
pwsh -NoProfile -File Client/windows/scripts/Build-Installer.ps1
```

默认生成的 Setup.exe 未做 Authenticode 签名。其卸载操作会清除本机设置、设备身份和缓存。需要恢复身份的用户应保有外部 `.chirpkey` 及密码。[卸载定义](../installer/Chirp.iss)

**MSIX** 使用 WinApp 构建。以下命令生成待签名的包。侧载发行时使用系统信任且与清单 `Publisher="CN=Chirp"` 对应的证书签名。[包清单](../Chirp/Package.appxmanifest)

```powershell
winapp package Client/windows/Chirp/Chirp.csproj -c Release --arch x64 --no-sign --output .build/Chirp-x64.msix
Get-FileHash .build/Chirp-x64.msix -Algorithm SHA256
```

## 历史记录

这些报告记录各自版本上的实测结果、修复和边界。复查当前版本时可沿报告的模块链接查找代码，再运行上面的测试。

