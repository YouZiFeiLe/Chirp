# 授权快照签名密钥

Chirp 服务端用 Ed25519 seed 签署授权快照，客户端用打包的公钥验签。开源镜像和四端源码附带配套密钥。沿用这对密钥时，用户只需在客户端确认自己的服务器地址。下面说明如何改用私有签名身份，并核对实际交付的安装包。[一站式部署](../deploy/README.md)

## 默认文件与用途

| 文件 / 配置 | 用途 |
| --- | --- |
| `deploy/authorization-key.default` | 仓库公开的默认 Ed25519 seed，44 字节规范 Base64，无末尾换行 |
| `Client/apple/Shared/Resources/AuthorizationTrust.json` | 四个平台的共用构建输入，公钥适用于所有使用对应 seed 的部署 |
| `/usr/share/chirp/authorization-key.default` | Docker Hub 成品镜像内的开源默认 seed，UID 65532、0400 |
| `CHIRP_AUTHORIZATION_KEY_FILE` | 指定 app 实际读取的 seed。自用 seed 可以只读挂载到 `/run/secrets/authorization-key` |

Apple 客户端从应用资源读取公钥，Android 从 APK 的 `assets/AuthorizationTrust.json` 读取，Windows 从 MSIX 根目录、与 `Chirp.Protocol.exe` 同级的位置读取。给客户端安装包签名使用各平台的代码签名证书。

签名快照用于验证设备授权历史。用户账号根、设备私钥、Passkey 和 MLS 内容密钥在各自独立的流程中产生。公开 Compose 在首次启动时为本机随机生成 LiveKit 令牌签名秘密。[部署配置](../compose.yaml)

**默认 seed 是公开材料，任何人都能生成有效的快照签名。** 能控制授权响应的一方可对旧历史重新签名，长期隐瞒客户端尚未知晓的撤销。客户端仍校验已保存的历史检查点、设备签名、本地撤销、SAS、群组名单和密钥确认。若一台仍被客户端信任的旧设备私钥失窃，隐瞒撤销可能使该设备继续被接纳。

私有部署若要求只有自己的服务能签署快照，应更换这对密钥。HTTPS 负责验证网络服务身份，设备和内容密钥保存在客户端。若主服务或其自用 seed 失陷，快照仍有相同的新鲜度边界。[安全说明](security.md)

## 生成并同步自用密钥

在可信的 Linux、macOS 或 WSL 的 Linux 文件系统中，从仓库根目录执行以下命令，Go 版本见仓库的 `go.mod`。授权 CLI 离线运行，生成时只向标准输出打印公钥，seed 写入新建的 0600 文件。读取要求权限为 0400 或 0600，生成操作拒绝覆盖已有文件，重试时使用新路径。`.build/` 已被 Git 忽略。

```sh
mkdir -p .build/authorization
go run ./cmd/chirp authorization -generate-key \
  -key-file .build/authorization/new-key
go run ./cmd/chirp authorization -export-trust \
  -key-file .build/authorization/new-key \
  > .build/authorization/AuthorizationTrust.json
cp .build/authorization/AuthorizationTrust.json \
  Client/apple/Shared/Resources/AuthorizationTrust.json
go run ./cmd/chirp authorization -verify-trust \
  Client/apple/Shared/Resources/AuthorizationTrust.json \
  -key-file .build/authorization/new-key
```

导出的 JSON 只含 `public_key`。核对成功时 `-verify-trust` 以状态 0 退出、无输出，可在分发前独立执行。以上命令显式传入 `-key-file`。省略该参数时，授权 CLI 先读 `CHIRP_AUTHORIZATION_KEY_FILE`，缺省用 `/run/secrets/authorization-key`。裸机运行 `chirp serve` 的缺省值则是业务库同目录的 `authorization-key`。[授权 CLI](../cmd/chirp/authorization.go) · [服务配置](../internal/config/authorization.go)

把生成的 `new-key` 通过受信任的渠道传到部署机，仅允许运维账号读取。在部署机进入 Compose 目录，把下列源路径换成该文件的实际位置，安装为容器可读的运行副本。

```sh
sudo install -d -m 0700 secrets
sudo install -o 65532 -g 65532 -m 0400 /实际存放位置/new-key secrets/authorization-key
```

在 `compose.yaml` 同目录保存 `compose.override.yaml`。Compose 会自动合并两份配置。

```yaml
services:
  app:
    environment:
      CHIRP_AUTHORIZATION_KEY_FILE: /run/secrets/authorization-key
    volumes:
      - type: bind
        source: ./secrets/authorization-key
        target: /run/secrets/authorization-key
        read_only: true
        bind:
          create_host_path: false
```

用新公钥重新构建并签署客户端，再执行 `docker compose up -d --force-recreate --wait app` 让服务端重新加载密钥。旧公钥客户端会拒绝新的签名。私钥与运行配置留在部署主机，离线备份 seed 及其配套公钥。

## 使用其他部署或修改域名

客户端通过发现、版本与健康检查后，从已确认的 `passkey_origin` 派生 `/authorization/v5/snapshot` 和 `/authorization/v5/append`。例如 `https://voice.example.com:8443` 对应 `https://voice.example.com:8443/authorization/v5/snapshot`。发现响应里的 `endpoints.authorization_url` 用于浏览器登录。此仓库的统一服务从同一个 `CHIRP_PUBLIC_ORIGIN` 生成这些端点。[发现端点](../internal/config/client.go)

切换服务器后必须重新确认连接，授权地址随新连接变化。公钥始终来自应用内置资源，重启后客户端使用已保存的连接配置。

签名消息中的 origin 使用规范化的主机名和显式端口，如 `https://chirp.first.test:443`。请求还绑定客户端产生的随机 nonce。账号、设备信任和历史检查点按 origin 隔离。换域名时应按新身份域处理，公钥相同也不能直接重放旧部署的授权历史。[Origin 规范化](../internal/identity/activation.go) · [快照签名](../internal/authorization/server.go)

## 核对发行包内的公钥

macOS 和 iOS 的 Xcode target 都将共享 JSON 加入应用资源，运行时从 `Bundle.main` 查找。按 Apple 构建说明生成对应的应用后，可在 macOS 上从仓库根目录分别运行以下比较。公钥一致时 `cmp` 以状态 0 退出、无输出。[Xcode 工程](../Client/apple/Chirp.xcodeproj/project.pbxproj) · [Apple 构建说明](../Client/apple/README.md)

```sh
cmp Client/apple/Shared/Resources/AuthorizationTrust.json \
  Client/apple/dist/macos/Chirp.app/Contents/Resources/AuthorizationTrust.json
cmp Client/apple/Shared/Resources/AuthorizationTrust.json \
  .build/DerivedData-ios-device/Build/Products/Release-iphoneos/Chirp.app/AuthorizationTrust.json
```

Android Gradle 校验共享文件中唯一的 `public_key` 字段和 32 字节 Ed25519 公钥的规范编码。Android 登录后用该公钥验证快照的 origin、nonce、账号根列表、设备签名事件和本地历史检查点。入房预检与后续换钥使用这些验证结果。[Gradle 资源任务](../Client/android/app/build.gradle.kts) · [账号授权同步](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/data/AccountIdentity.kt) · [快照验签](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/data/Authorization.kt)

Windows 构建会将共享 JSON 随协议进程装入 MSIX。协议进程检查文件只含一个规范编码的 `public_key` 字段，再用它验证快照。[Windows 项目](../Client/windows/Chirp/Chirp.csproj) · [公钥加载与快照验签](../Client/windows/engine/authorization_trust_windows.go)

在仓库根目录可用 Python 3 逐字节核对安装包。把最后一个参数换成实际交付的 APK 或 MSIX 路径。

```sh
python -c "
import sys
from pathlib import Path
from zipfile import ZipFile

package = Path(sys.argv[1])
entries = {'.apk': 'assets/AuthorizationTrust.json', '.msix': 'AuthorizationTrust.json'}
entry = entries[package.suffix.lower()]
expected = Path('Client/apple/Shared/Resources/AuthorizationTrust.json').read_bytes()
with ZipFile(package) as archive:
    if archive.namelist().count(entry) != 1 or archive.read(entry) != expected:
        raise SystemExit('安装包内公钥缺失、重复或与共享文件不符')
print('安装包内公钥与共享文件一致')
" Client/android/app/build/outputs/apk/release/app-release.apk
```

## 发布时核对

GitLab 发布作业在上传镜像前，用镜像内的公开 seed 和标签源码中的客户端公钥离线执行 `authorization -verify-trust`。自用 seed 留在部署机，通过上文的 Compose 覆盖文件挂载。升级时同时保留业务库、授权库、运行配置及自用密钥。[开源发布](publishing.md) · [服务端运维](server-operations.md)
