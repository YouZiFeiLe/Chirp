# Chirp 客户端日志格式 v1

`.chirplog` 是支持人员可以用 SQLite 3 打开的客户端诊断数据库。Android、macOS、iOS 和 Windows 使用本规范，可用同一条查询分析四个平台的导出文件。日志属于本次客户端安装，切换服务器或登录账号均沿用本机开关和保留策略。

## 用户可见行为

- 首次安装时关闭记录。登录前和登录后的设置均可进入「日志管理」，方便先开启记录，再复现登录失败。
- 开启后立即记录操作及通话诊断。声音设置没有独立诊断开关或导出入口。通话所需的连接监测和解密恢复可以始终运行。
- 关闭后停止接收新事件，已接收的事件写完，已有日志继续按时过期。关闭期间仍可导出或清除。重新开启时从当前操作开始。
- 「导出日志」生成最近 24 小时的一个独立文件，用户自行保存、分享。没有可导出的事件时显示空状态。客户端只提供管理和导出功能，无日志浏览器，也无自动上传。
- 「清除日志」清空本机写入缓冲、分片和导出暂存，保留用户当前的开关选择。「清空本地数据」同时清除日志并恢复默认关闭。用户已另存的副本归用户管理。

## 文件、分片与时间

每个本机分片是一个独立的 SQLite 3 数据库，名称为 `<UTC小时序号>.chirplog`。小时序号取 Unix 毫秒时间戳除以 `3600000` 的整数部分。同一个小时内，各种事件进入各自的表。UTC 分片不受本地时区、夏令时或跨午夜影响。

保留边界为 `cutoff = now_ms - 86400000`。整点以前已过期的分片连同关联文件删除，边界所在小时按行删除 `time_ms < cutoff`，最后一条记录过期后删除空文件。各端在启动、运行和导出时检查保留期限，关闭记录也会清理旧记录。导出固定一个快照时刻，包含闭区间 `[cutoff, now_ms]`。

Apple 将分片放在 Application Support 下的 `Chirp/ClientLogs/` 并排除备份，Android 使用 `noBackupFilesDir/ClientLogs/`，Windows 协议引擎使用传入缓存目录下的 `ClientLogs/`。SQLite 的 `secure_delete=ON` 用于清除边界小时内被删除的行。

## 数据库约定

所有分片和导出文件均带有下列 SQLite 文件头标记。打开已有文件时先验证标记和版本。扩展名本身不能用于判断兼容性。列的含义、单位或必需表发生不兼容变化时，应升级 `user_version` 并增加兼容性测试。[SQLite 文件标记与 PRAGMA](https://www.sqlite.org/pragma.html#pragma_application_id)

| 标记 | v1 值 |
| --- | --- |
| SQLite 文件头 | `SQLite format 3` 加一个 NUL 字节 |
| `PRAGMA application_id` | `1128813136`，十六进制 `0x43485250`，ASCII `CHRP` |
| `PRAGMA user_version` | `1` |
| 扩展名 | `.chirplog` |
| Apple 导出类型 | `cn.youzifeile.chirp.log`，符合 `public.data` |

v1 创建下列十二张表，即使某一类没有数据也保留空表。所有平台使用相同的英文表名、列名和字段单位。事件名是源代码定义的稳定标识，界面语言不会改变事件名。

| 表名 | 记录范围 | 事件举例 |
| --- | --- | --- |
| `application` | 生命周期、版本环境、写入异常 | `launch`、`active`、`background`、`storageOverflow` |
| `navigation` | 打开页面、切换视图、查看或收起详情 | `room`、`roomChat`、`friends`、`settings`、`logSettings` |
| `account` | 浏览器／二维码登录、会话结束、资料操作 | `browserLogin`、`phoneLogin`、`loginAccepted`、`sessionEnded`、`logout` |
| `identity` | 设备授权、恢复、身份核验、好友和信任变更 | `approveDevice`、`verifyBackup`、`verificationMismatch`、`removeFriend` |
| `network` | 具体请求或事件流的操作名、响应码、耗时、重试结果 | `preflight`、`groupHeartbeat`、`mediaLease`、`rotationActivate`、`eventStreamEnded` |
| `room` | 房间操作及入房尝试 | `join` |
| `call` | 通话状态转换、音轨及传输统计 | `lifecycle`、`trackSample` |
| `audio` | 输入输出、语音激活、音频处理器状态 | `selectInput`、`preferOutput`、`captureInitialized`、`changeActivationThreshold` |
| `crypto` | 媒体、附件和缩略图的加解密性能 | `voiceDecrypt`、`attachmentDecrypt`、`thumbnailEncrypt` |
| `chat` | 开始／清空草稿、恢复失败消息、收发及投递结果 | `compose`、`restoreDraft`、`sendMessage`、`receiveAttachment` |
| `attachment` | 选择、上传、取消、重试、预览和导出 | `selectFile`、`upload`、`retryUpload`、`previewAttachment`、`exportAttachment` |
| `settings` | 设置变更、缓存和日志管理 | `confirmServer`、`changeLanguage`、`recordingEnabled`、`recordingDisabled`、`exportLogs` |

以下是 `call` 表的完整示例。其余十一张表使用相同的列顺序，并各建一个 `<表名>_time` 索引。

```sql
CREATE TABLE call (
    time_ms INTEGER NOT NULL,
    event TEXT NOT NULL,
    outcome TEXT,
    error_code TEXT,
    duration_us INTEGER,
    http_status INTEGER,
    details TEXT,
    segment TEXT NOT NULL,
    seq INTEGER NOT NULL
);
CREATE INDEX call_time ON call(time_ms);
```

| 列 | 写入约定 |
| --- | --- |
| `time_ms` | UTC Unix 毫秒，取事件发生或计时完成的时刻。保留和导出只用此列判断。 |
| `event` | 固定操作名。跨平台同义操作复用已有名字。新增事件不需要创建新表。 |
| `outcome` | 可空。可取 `started`、`succeeded`、`failed`、`cancelled`。单次导航等无结果的事件使用 NULL。 |
| `error_code` | 可空。只存客户端已知的固定错误码。未知服务端错误归一为 `CLIENT_UNKNOWN_SERVER_ERROR`。正常取消使用 `outcome=cancelled`，错误码为空。 |
| `duration_us` | 可空。操作从开始到完成的单调时钟耗时，单位微秒。网络请求包含本地等待和传输时间。 |
| `http_status` | 可空。收到 HTTP 响应时的数值状态码。 |
| `details` | 可空。仅按该事件的字段白名单编码的 UTF-8 JSON 对象，数值使用 JSON 数字。可选指标缺失时省略字段。 |
| `segment` | 随机 UUID，小写标准文本。在进程启动、重新开启及清除后重新生成。与账号、设备、密钥均无映射。 |
| `seq` | 当前记录段跨表共用的正整数，从 1 开始递增。同一毫秒内按此列还原操作顺序，跨段用时间戳排序。 |

## 通话指标与脱敏

`call.lifecycle` 的 `details` 记录固定的 `event`、`phase`、`sequence`、`elapsedMilliseconds`、`transportGeneration`、`keyRevision`，可附固定 `failure` 和 `audio`。其中 `audio` 只含 `microphoneMuted`、`listening`、`preset`、`route`。`elapsedMilliseconds` 使用单调时钟，在当前记录段第一次通话诊断事件时开始。定位入房耗时可比较同一段的 `authorizationStarted` 和 `activated`。生命周期事件逐条写入，避免长通话只剩最后几个事件。

`call.trackSample` 的 `details` 保存 `schema=1`、`phase`、`microphoneMuted`、`listening`、`audioInterrupted`、`route`、`preset`、`mediaLeaseValid`、可选的 `mediaLeaseRemainingMS` 以及 `tracks` 数组。每条获准加入的远端麦克风音轨只分配样本内的序号 `number`。分析工具按样本解释序号，成员或音轨变化时序号可以改变。

| 音轨字段 | 单位或取值 |
| --- | --- |
| `muted`、`subscribed`、`subscriptionFailed` | 布尔值 |
| `encryption` | `waiting`、`verified`、`missingKey`、`decryptionFailed`、`failed` |
| `quality` | `unknown`、`excellent`、`good`、`poor`、`lost` |
| `packetsReceived`、`packetsLost` | SDK 报告的累计包计数。缺失值省略。 |
| `jitterMS`、`roundTripMS` | 毫秒。RTT 取选中 ICE 候选对的往返时间。丢弃非有限数和负值，Apple 对两者封顶 600000 毫秒。 |
| `lastDecryptionEventAgeMS` | 距 SDK 最近一次成功解密状态事件的毫秒数。与单帧解密用时分别统计。 |

`crypto.voiceDecrypt` 直接测量获准播放的音频帧构造密封数据并完成 AES-GCM 认证解密所用的单调时钟时间。回放重复帧、无效帧和无授权帧均不进入成功样本。每个统计窗口只输出 `frames`、`total_ns`、`max_ns`。平均每帧耗时为 `total_ns / frames` 纳秒，跨窗口求平均时先分别求和。Apple 复用现有媒体监测周期，约每秒取一次计数，音轨状态变化时立即记录快照，状态稳定时每五秒取样。恢复文件的原生加解密操作用 `recoveryEncrypt` 和 `recoveryDecrypt` 记录耗时。附件和缩略图使用事件行的 `duration_us`。其中整文件操作也包含读写和校验时间。

`application.launch` 和 `settings.recordingEnabled` 可附 `platform`、`app_version`、`app_build`、`os_version`。平台名用 `macos`、`ios`、`windows` 或 `android`。音频处理初始化可附 `sample_rate_hz`、`channels` 和 `rnnoise`（0 或 1）。每个平台都应使用固定的预设和路由类别。无法获得的指标留空，避免把未知延迟解释为零。

在操作入口记录用户意图，在业务层记录成功、失败、取消及时间。只允许固定事件、枚举、布尔值、计数和上文声明的元数据进入写入器。Apple 在初始化媒体组件前关闭 LiveKit 的通用日志输出。其他平台也应检查 SDK 的默认日志配置。严禁序列化整份请求、异常、SDK 统计、音轨对象或业务模型。排除账号／房间／消息／音轨 ID、昵称、设备名、指纹、服务地址、IP、文件名和路径、输入文本、聊天、图片、音频、密码、令牌、恢复材料与密钥。登录记录只表明使用的方式、时机和结果。页面显示与关闭可用 `navigation` 事件的 `details.visible` 布尔值表示。草稿只记操作边界。错误消息中的未知文本即使看似规范错误码，也须经过固定枚举映射。

## 写入、导出与移植

1. 用应用级服务接收事件，先检查开关，再读取时钟、生成操作记录。SQLite 写入、清理、合并均在后台串行执行。语音帧路径只做有条件的计时和计数，避免逐帧文件 I/O、JSON 编码和任务派发。
2. 事件入队时固定时间和顺序。按小时路由，同一分片批量提交事务。Apple 正常每 64 条或约 400 毫秒提交，切到后台和正常退出时尽快冲刷缓冲。进程被系统强杀时，最后一个未提交的批次可能丢失。磁盘持续不可写时限制缓冲，恢复后用 `application.storageOverflow` 的 `details.count` 报告被合并丢弃的条数。
3. 为未完成的请求和解密统计附上内存中的记录代次。关闭、重新开启或清除时使旧代次失效。清除与已排队写入共用顺序，避免清除后的延迟任务重新写入旧记录。
4. 导出时提交排队事件，固定一个 `now_ms`，执行清理并创建同版本的空库。逐片连接数据库，用事务将十二张表中处于闭区间内的行拷入导出库，再断开该片。仅交付已提交的 SQLite 主文件，接收方无需 WAL、SHM、分片目录或应用程序。结束或失败时回收暂存，下次启动回收被中断的暂存。Apple 使用 SQLite 的 ATTACH/DETACH 和回滚日志模式。[SQLite ATTACH DATABASE](https://www.sqlite.org/lang_attach.html)
5. Windows 由 Go 协议引擎的后台写入器生成快照，WinUI 负责选择并保存文件。Android 使用单线程后台执行器写库，导出时把快照复制到用户所选位置的输出流。[Windows 写入器](../Client/windows/engine/client_log_windows.go) · [Windows 导出](../Client/windows/Chirp/LogSettings.cs) · [Android 写入器与导出](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/data/ClientLog.kt)

支持端可以只读打开用户提供的文件，先检查文件头标记和两个 PRAGMA，再运行查询。例如统计整个导出窗口的语音解密平均与峰值，单位为微秒。

```sql
SELECT sum(json_extract(details, '$.frames')) AS frames,
       sum(json_extract(details, '$.total_ns')) /
         (1000.0 * nullif(sum(json_extract(details, '$.frames')), 0)) AS mean_us,
       max(json_extract(details, '$.max_ns')) / 1000.0 AS max_us
FROM crypto WHERE event = 'voiceDecrypt';
```

在空的 v1 测试数据库中写入下面两条合成记录。上述查询应返回 3 帧、平均 50 微秒、峰值 70 微秒。各端可共用这个样例验证单位和跨窗口加权。

```sql
INSERT INTO crypto (time_ms, event, details, segment, seq) VALUES
(1800000000000, 'voiceDecrypt', '{"frames":2,"total_ns":80000,"max_ns":50000}',
 '51dd4149-46fa-432e-bb84-bab6d005e39c', 1),
(1800000001000, 'voiceDecrypt', '{"frames":1,"total_ns":70000,"max_ns":70000}',
 '51dd4149-46fa-432e-bb84-bab6d005e39c', 2);
```

## 跨平台验收

| 场景 | 验收结果 |
| --- | --- |
| 首次启动、关闭期间登录 | 不创建事件分片，导出提示为空。 |
| 登录前开启，先后登录两个账号 | 同一安装产生匿名登录、结束与失败记录。切换账号不会改动开关或生成账号日志目录。 |
| 跨 UTC 小时、跨午夜，暂停后重新启动 | 文件按小时切换。关闭记录后启动仍删除过期整片，截止时刻前一毫秒的行删除，等于边界的行保留。 |
| 停止后导出、清除两次、清除后继续使用 | 停止后仍可导出有效数据，清除幂等。开关保持原值，旧计时和旧写入不会重新出现。 |
| 多个事件同毫秒发生，导出与生产并发 | 提交完整批次。同段按 `seq` 排序。用单文件打开后 `PRAGMA integrity_check` 返回 `ok`。 |
| 注入独特的测试账号、令牌、地址、文本、未知错误码、音轨名 | 检查所有表的行及导出文件字节，敏感标记均不可检索，未知错误码已归一。 |
| 真实加密语音、静音／重连、对端发声 | 有通话阶段、匿名音轨状态、可用时的 RTT 和解密聚合。连续通话期间比较开关前后的 CPU、内存、音频卡顿及写入次数。 |
| 其他客户端读取 Apple 生成的样本，反向再测一次 | SQLite 文件标记、十二张表、列类型、时间边界和性能查询都兼容。 |

各端使用相同的文件标记、分片边界和导出表结构。[Apple 数据库](../Client/apple/Shared/ChirpLogStore.swift) · [Apple 格式测试](../Client/apple/Tests/ClientLogTests.swift) · [Android 数据库](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/data/ChirpLogStore.kt) · [Android 格式测试](../Client/android/app/src/androidTest/kotlin/cn/youzifeile/chirp/data/ClientLogTest.kt) · [Windows 数据库](../Client/windows/engine/chirplog_store_windows.go) · [Windows 格式测试](../Client/windows/engine/client_log_windows_test.go)
