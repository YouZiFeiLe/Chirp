# Android 发布签名

本目录保存 Chirp 开源版 Android APK 的发布签名身份。密钥库和构建口令随源码公开，任何人都可以用它们签署 APK。后续开源版更新沿用同一个密钥库。

| 配置 | 值 |
| --- | --- |
| 应用 ID | `cn.youzifeile.chirp.android` |
| 密钥库 | [chirp-release.p12](chirp-release.p12) |
| 公钥证书 | [chirp-release.pem](chirp-release.pem) |
| 构建参数 | [release.properties](release.properties) |
| 密钥库类型 | `PKCS12` |
| 密钥别名 | `chirp-release` |
| 密钥库密码（storePassword） | [release.properties](release.properties) 中的 `storePassword` |
| 私钥密码（keyPassword） | [release.properties](release.properties) 中的 `keyPassword` |
| 密钥算法 | RSA 4096 位 |
| 证书签名算法 | SHA256withRSA |
| 证书主体 | `CN=Chirp Open Source, OU=Android, O=Chirp Open Source` |
| 有效期 | 10000 天 |

证书有效时间（GMT／UTC）：

```text
notBefore=Nov 23 14:03:48 2026 GMT
notAfter=Apr 10 14:03:48 2054 GMT
```

证书 SHA-256 指纹：

```text
FE:2C:66:57:7E:28:56:A8:CA:5A:0C:F9:E8:50:2A:D3:AF:CA:0F:D5:AE:6E:7E:B2:9A:0A:0D:38:08:D1:57:42
```

## 构建与验证

在 `Client/android` 目录中，使用 JDK 27.0.1 和已配置的 Android SDK。以下命令调用项目使用的 Build Tools 37.0.0。

```sh
./gradlew :app:assembleRelease
"$ANDROID_HOME/build-tools/37.0.0/apksigner" verify --verbose --print-certs app/build/outputs/apk/release/app-release.apk
```

PowerShell 中使用以下命令。

```powershell
.\gradlew.bat :app:assembleRelease
& "$env:ANDROID_HOME\build-tools\37.0.0\apksigner.bat" verify --verbose --print-certs app/build/outputs/apk/release/app-release.apk
```

Release 构建读取本目录的 `release.properties`。最低系统版本是 `minSdk = 35`（Android 15），目标为 `targetSdk = 37`（Android 17）。Gradle 启用 APK Signature Scheme v2、v3 并关闭 v1。按上述命令验证开源版 2026.11.23（构建 1，`versionCode = 5`）的 APK，输出为 `Verifies`，v3 为 `true`，v2 为 `false`。`certificate SHA-256 digest` 与本文指纹一致。[构建与签名配置](../app/build.gradle.kts)

密钥库中保存加密私钥和证书；PEM 文件只导出公钥证书。证书由本项目自签名，用于 Android APK 发布身份。[Android 应用签名说明](https://developer.android.com/studio/publish/app-signing) · [apksigner 验证说明](https://developer.android.com/tools/apksigner)
