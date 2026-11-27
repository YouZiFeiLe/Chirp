# 参与 Chirp 开发

简体中文 · [English](CONTRIBUTING.en.md)

## 报告问题或提出建议

- **报告故障**时，请先搜索已有 Issue。写明受影响的客户端、操作系统和服务端版本，给出最短复现步骤、预期结果与实际结果。从客户端「设置 → 日志管理」导出已脱敏的 `.chirplog`，压缩为 `.zip` 随 Issue 上传。补充截图请先脱敏，令牌和 `.chirpkey` 备份请留在本地。[GitHub Issues](https://github.com/YouZiFeiLe/Chirp/issues)
- **提出功能建议**时，请举例说明使用场景和希望改善的行为。涉及多端协议的改动，适合先开 Issue 讨论兼容性。小的代码修复可以直接提交 PR。
- **修订文档**时，请将勘误、补充和文档翻译以 PR 提交到文档仓库。[Chirp-Doc-Page](https://github.com/YouZiFeiLe/Chirp-Doc-Page)
- **报告安全漏洞**时，请将受影响的版本和复现条件通过 GitHub 私下发给维护者。[私密漏洞报告](https://github.com/YouZiFeiLe/Chirp/security/advisories/new) · [安全策略](SECURITY.md)

## 开始开发

在 GitHub 上 fork 本仓库，将下面的 `YOUR-NAME` 换成你的用户名，从 `main` 创建工作分支。后续命令均从仓库根目录运行。

```sh
git clone https://github.com/YOUR-NAME/Chirp.git
cd Chirp
git switch -c fix/room-reconnect origin/main
```

只需准备改动涉及的工具链。以 Go 服务端为例，入口在 `cmd/chirp`，房间、身份和 SQLite 存储逻辑在 `internal/`。在 macOS 或 Linux 上，安装项目指定的 Go 版本，以及竞态检测所需的 C 编译器。[Go 版本](go.mod)

```sh
sh scripts/go.sh run ./cmd/chirp version
sh scripts/test-sqlite.sh local
```

第一条命令会编译 CLI 并打印版本。第二条用临时 SQLite 文件运行 Go 测试和竞态检测，再执行 `go vet`。需要启动本地 API 或验证 Compose 部署时，参见[服务端构建与测试](https://chirp.youzifeile.com/development/building)。

## 按改动范围验证

| 改动范围 | 验证命令 |
| --- | --- |
| 管理台与 Passkey 网页 | `node --test internal/webui/*_test.mjs internal/passkeyhttp/*_test.mjs` |
| 四端共享的 Rust 加密库 | `cargo test --locked --manifest-path Client/apple/MLS/native/Cargo.toml` |
| macOS 与 iOS 共享逻辑（Apple Silicon Mac） | 先运行 `sh scripts/prepare-mls.sh` 准备 XCFramework，再运行 `swift test --package-path Client/apple` |
| Android 客户端 | `./Client/android/gradlew -p Client/android :app:testDebugUnitTest` |
| Windows x64 协议与音频 | `pwsh -NoProfile -File Client/windows/scripts/Build-Native.ps1 -Test` |
| Windows 桌面行为 | `dotnet run --project Client/windows/tests/DesktopBehavior.csproj -c Release` |

客户端所需的 SDK 和原生依赖见[各平台构建指南](https://chirp.youzifeile.com/development/clients)。涉及麦克风、设备配对或两端通话时，可按[人工验收清单](https://chirp.youzifeile.com/development/testing)检查实际设备上的表现。

## 提交 Pull Request

将工作分支推送到你的 fork，向 `YouZiFeiLe/Chirp` 的 `main` 提交 PR。

- 每个 PR 聚焦一个问题，说明改动原因和用户能观察到的变化，并关联已有 Issue（如有）。
- 用 `gofmt` 格式化改动过的 Go 文件。修复故障时，尽量补上能复现原问题的回归测试。PR 中列出实际执行的检查、结果和测试平台，界面改动可附脱敏截图。
- 修改身份、配对或恢复文件格式时，请用共享测试向量核对各端实现，并说明新旧版本之间的兼容性。[跨端测试向量](internal/identity/testdata/)

Chirp 的原创内容采用 AGPL-3.0-only。引入第三方代码或素材时，请注明来源，并保留其许可证和署名。[项目许可证](LICENSE) · [合规声明](COMPLIANCE.md)
