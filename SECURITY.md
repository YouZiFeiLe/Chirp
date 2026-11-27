# Chirp 安全策略 / Security Policy

[English](#english)

## 简体中文

如果你怀疑 Chirp 存在安全漏洞，请[通过 GitHub 私下报告](https://github.com/YouZiFeiLe/Chirp/security/advisories/new)。在与维护者商定披露时间前，请将细节保留在私密报告中，避免发布到公开 Issue 或 PR。已披露的问题见[项目安全公告](https://github.com/YouZiFeiLe/Chirp/security/advisories)。

### 适用范围与版本

本策略涵盖 Chirp 服务端和管理台、macOS、iOS、Android 和 Windows 客户端、共享加密核心，以及项目发布的容器镜像和默认部署配置。若某个自托管实例发生安全事件，请私下联系该实例管理员。若怀疑问题源于 Chirp 软件或默认配置，也请向项目报告。

维护者优先评估影响[最新正式版](https://github.com/YouZiFeiLe/Chirp/releases/latest)或 `main` 分支的问题。仅在旧版观察到的问题也欢迎报告，请注明实际版本。是否修复或将补丁移植到旧版，取决于影响和维护者可投入的时间。参见[项目维护说明](COMPLIANCE.md)。

### 报告中请包含

- 受影响的组件和版本。客户端请注明平台、系统和应用版本，服务端请注明发布标签、镜像摘要或 Git 提交号。
- 出现问题的前提条件和简要复现步骤。若涉及设备配对或房间权限，请说明各测试设备当时的状态。
- 预期行为、实际结果，以及哪些用户、数据或操作可能受到影响。

请使用测试账号和模拟数据，只在自己控制或获准测试的实例上验证。分享截图或日志（包括 `.chirplog` 诊断日志）时，请只截取与问题有关的部分，并遮盖会话令牌、配对码和真实通信内容。私钥、`.chirpkey` 身份恢复文件及其密码请保留在本地。

## English

If you suspect a vulnerability in Chirp, please [report it privately on GitHub](https://github.com/YouZiFeiLe/Chirp/security/advisories/new). Keep details out of public issues and pull requests until you and the maintainer agree on a disclosure date. For previously disclosed vulnerabilities, see [Chirp’s security advisories](https://github.com/YouZiFeiLe/Chirp/security/advisories).

### Scope and versions

This policy covers the Chirp server and admin console, the macOS, iOS, Android and Windows clients, the shared cryptographic core, and the container images and default deployment configuration published by the project. If a security incident affects a self-hosted instance, contact its operator privately. If you suspect a flaw in Chirp or its default configuration, please also report it to the project.

The maintainer prioritizes reports affecting the [latest release](https://github.com/YouZiFeiLe/Chirp/releases/latest) or the `main` branch. If you have only seen the issue on an older version, please report it and name that version. Fixes and backports depend on impact and maintainer availability. See the [project’s maintenance statement](COMPLIANCE.md).

### What to include

- The affected component and version. For a client, include the platform, OS version and app version. For the server, include the release tag, container image digest or Git commit.
- The conditions and minimal steps needed to observe the issue. For device pairing or room permissions, describe the state of each test device at the time.
- What you expected, what happened, and which users, data or operations could be affected.

Use test accounts and sample data on an instance you control or have permission to test. Share only the relevant excerpts from screenshots or logs, including `.chirplog` diagnostic logs. Redact session tokens, pairing codes and real communications. Keep private keys, `.chirpkey` identity recovery files and their passwords on your device.
