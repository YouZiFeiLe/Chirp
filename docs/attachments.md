# 附件传输与缓存

附件协议 v3 通过加密聊天通道传递描述和文件密钥，通过业务 HTTPS 接口传输密文。附件内部的 AES-GCM 记录格式为 v1，投递状态保存在业务库（schema 23）。[服务端存储](../internal/store/attachments.go)

Apple、Android 和 Windows 使用同一密文记录、描述、HTTPS 分块与回执协议。Apple 的 CryptoKit、URLSession 和缓存目录是平台实现细节。Android 通过系统文件选择器导出，Windows 由 WinUI 选择文件、Go 协议进程处理密文缓存和传输。[Apple 格式](../Client/apple/Shared/AttachmentCrypto.swift) · [Android 格式](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/data/AttachmentCrypto.kt) · [Windows 文件处理](../Client/windows/engine/files_windows.go)

## 传输流程

发送端先在本机完整加密文件，服务端把密文暂存在本地硬盘。完整上传并验证后，发送开始时锁定且仍在线的原接收者自动下载；后来加入或已经确认离线后重新上线的客户端不补发。客户端可靠落盘并通过完整性及解密认证校验后回执；全部接收者确认、离线退出或投递到期后，删除服务器副本。服务器不接收文件名、缩略图明文或文件密钥。

完整上传后才开放下载。SQLite 保存投递管理信息，硬盘按对象暂存单个连续密文文件。传输使用 1 MiB 网络块，加密使用独立的 256 KiB 明文记录。服务端在单个下载请求内每至多 64 KiB 重新检查授权。

## 发送、在线资格与自动接收

仅当前语音入房且安全群组就绪时可发送：本机加密文件 → 服务端预留对象与原接收者集合 → 向捕获的群组代发布一次加密描述 → 上传密文 → 显式完成。

描述含文件名、类型、大小、完整密文摘要、随机文件密钥和可选加密缩略图，只在加密数据通道中传递。接收端聊天消息只持有无密钥的 AttachmentInfo。文件密钥不放入服务端事件、列表或数据库。

附件事件流应在入房后、接收第一条附件描述前建立。服务端在预留时捕获原名单中的在线状态，含尚在 6 秒重连宽限内的连接，其他接收者标记为 `skipped`。原始名单仍保留，重复创建须使用相同密文和接收集合。

在线按准确入房与附件事件连接判定。入房授权失效时退出投递；服务端观察事件连接中断后保留 6 秒重连宽限，超过宽限将其全部 pending 投递永久标记为 skipped。恢复相同 entry 也不能重新获取这些文件。单次分块请求失败不是离线，宽限内可重连并重试。6 秒从服务端观察连接结束时起计算，不包含 TCP 失效探测时间，不是物理断网的全局探测上限。

服务端只接受相同入房的最新事件连接，每 2 秒发送保活。重连、离线清理和预留名单捕获互斥，迟到重连不能抢在清理前恢复旧资格。新文件可以使用恢复后的在线资格。

收到描述只登记密钥和缩略图。完整上传后，接收端按队列自动下载；自动队列一次处理一个文件，与用户触发的下载合计最多两个。手动暂停不会被后续状态通知自动重启。应用层重试失败后允许用户在投递仍有效时继续。

描述只向捕获的群组代发送，最多 8 个目标身份一批，总包上限 12 KiB。尚未发布的失败预留，仅在群组代与接收者仍一致时可重试；发布已尝试但结果不明时只能取消，不通过新群组重新广播旧文件密钥。轮换不扩大既有接收资格，安全连接未就绪时暂停传输。

## HTTPS 接口

公共前缀为 `/v1/rooms/{room}/attachments`。**所有请求都要带 `Authorization: Bearer <credential>` 和 `X-Chirp-Entry: <entry_id>`**。创建时还要在 JSON 正文提交相同的 `entry_id`，不一致会返回 `404 ATTACHMENT_UNAVAILABLE`。访问同时检查本次入房与原接收资格，重新入房后使用新 entry。

| 方法及后缀 | 合同 |
| --- | --- |
| POST 空后缀 | 严格 JSON 包含 `id`、`entry_id`、`ciphertext_size`、`ciphertext_sha256`、`recipients`。ID 为 16 字节随机值的小写十六进制，摘要为 32 字节 SHA-256 的小写十六进制。创建成功返回 201 |
| GET 空后缀 | 当前入房可见对象列表，返回服务实例与 revision |
| GET /events | 登记在线附件连接。SSE 的 `state` 事件含 `server_id`、`room_id` 和 `revision`，收到后重读列表 |
| GET /{id} | 对象状态、进度及已提交网络块摘要 |
| PUT /{id}/chunks/{index} | 序号从 0 起，使用 `Content-Type: application/octet-stream` 及准确 `Content-Length`。按序传 1 MiB 网络块，尾块用实际长度。首次提交或同内容重试成功返回 204 |
| GET /{id}/chunks/{index} | 完整上传后下载；每至多 64 KiB 重新检查入房、接收资格和在线连接 |
| POST /{id}/pause | 上传者显式暂停，空正文，无查询参数 |
| POST /{id}/cancel | 上传者取消未完成对象，空正文，无查询参数 |
| POST /{id}/complete | 空正文，无查询参数。验证全部块及完整密文 SHA-256 后完成 |
| POST /{id}/received | 严格 JSON：ciphertext_sha256；准确接收者确认已验证的本地副本，可幂等重试 |

对象的 JSON 表示包含 `protocol_version=3` 和 `chunk_bytes=1048576`。目录 revision 只在同一服务实例、同一房间内比较，重连或 `server_id` 改变后重新读取列表。对象有自己的 revision，完成、取消、回执及离线退出通过 SQLite 写事务裁决。取消响应丢失时继续确认原取消，已经完成的上传仍向原接收者分发。

下载过早会收到 `409 ATTACHMENT_PENDING`。上传跳过块序号、或用不同内容重传已提交块时返回 `409 ATTACHMENT_CONFLICT`，可重读对象状态及 `chunk_sha256`。配额用尽为 `413 ATTACHMENT_QUOTA`，暂时繁忙为 `429 ATTACHMENT_BUSY`，后者带 `Retry-After: 1`。[块处理与错误码](../internal/httpapi/attachments.go)

received 必须在客户端下载、同步写盘、完整摘要与逐记录 AEAD 校验成功之后调用。服务端检查原接收身份、状态和摘要，不使用发送完 HTTP 响应作为成功依据。发送者预留时已经标记 received，不重复下载，也不能代其他人确认。

每次回执只改变自己的记录。最后一个 pending 接收者确认或退出后，对象进入 delivered，立即删除本地密文。少量状态保留供回执、完成响应丢失后的幂等重试；已接收的客户端继续使用本地缓存，不能将 delivered 误作取消并清除密钥。

实现见[HTTP 传输](../internal/httpapi/attachments.go)、[在线与事件](../internal/httpapi/attachment_state.go)、[回执接口](../internal/httpapi/attachment_delivery.go)、[投递状态](../internal/store/attachment_delivery.go)及[Swift transport](../Client/apple/Shared/AttachmentTransport.swift)。

## 状态、有效期与配额

| 文件状态 | 含义 |
| --- | --- |
| reserved | 已预留，尚未提交块 |
| uploading | 至少一块已提交，可继续 |
| paused | 显式暂停，或预留／上传连续 30 秒无新块 |
| completed | 全部密文已验证，正在向 pending 接收者分发 |
| delivered | 没有待接收者，服务器副本已删除；已成功接收的本地副本仍有效 |
| cancelled | 未完成上传被取消，或上传者原 entry 已失效 |
| expired | 超过上传或分发期限，不再传输 |

每个原接收者有独立的 pending、received、skipped 状态。后加入者不能增加记录，skipped 不能恢复成 pending。入房授权失效和连接宽限超时会移除 pending 资格；全部退出时同样回收服务端副本。

未完成对象从预留起最多 15 分钟，重试不续期。完整上传后分发最多 15 分钟。`delivered`、`cancelled`、`expired` 的管理记录自进入终态满 5 分钟后可清除，已经没有有效原接收者的记录可提前清除。后台每秒核对状态和离线接收者，每分钟清理到期记录及孤立文件。5 分钟是回收条件，实际删除随清理任务执行。[状态回收](../internal/store/attachment_state.go)

客户端接受最大 100 MiB 的原文件。服务端按密文计费，每对象允许 16 字节至 `100 MiB + 8192 字节`，每房 512 MiB、全局 4 GiB。每房最多 256 个对象、全局最多 4096 个。创建的 `recipients` 为准确的 `member_id.login_id.entry_id`，数组最长 256 项，去重后连同自动计入的发送者至多 256 个身份。终态对象释放密文字节配额，保留的管理信息仍占对象数量。[服务端存储](../internal/store/attachments.go)

Apple 每次入房的本机容量为 512 MiB，含待下载预留。可预览图片最多 20 MiB、6000 万像素，缩略图最长边 256 像素、密文至多 6 KiB，预览最长边 2048 像素。GIF 只预览首帧，导出保留原文件。[客户端格式](../Client/apple/Shared/AttachmentCrypto.swift) · [图像处理](../Client/apple/Shared/AttachmentImages.swift)

每客户端最多一个上传、两个下载。上传与下载分别限速，每方向正常 8 MiB/s、受限 512 KiB/s，应用层重试也计入对应方向；连接恢复或音轨丢失时暂停。音轨 poor 或抖动达到 40 ms 时降速，单独的绝对 RTT 高不再视为拥塞。每方向最多一个网络块突发，不积累空闲额度。这是有限带宽策略，不能作为真实通话弱网质量验收的替代。

单网络操作最多 4 次尝试，受退避、Retry-After 与截止约束。一次上传／下载流程最多 15 分钟，自动下载在完整上传后才开始该流程；回执失败单独重试，不重新下载成功的本地副本。继续上传前校验不可变密文和服务端前缀摘要，下载恢复时校验本地前缀，损坏后从该块重取。恢复只重传已有密文，不重新加密。

## 硬盘暂存与崩溃清理

给 `CHIRP_ATTACHMENT_PATH` 分配专用绝对目录。启动和定期清理会移除其中所有不对应活动对象的文件和目录。服务端拒绝把符号链接作为附件目录，也会在解析父目录链接后检查它是否包含业务库、授权库或签名密钥。[存储初始化与回收](../internal/httpapi/attachments.go)

每对象使用权限受限目录及单个 ciphertext 文件。1 MiB 网络块顺序追加，可靠同步后再提交 SQLite 的块摘要与进度，减少 HTTP 请求、小文件及持久化次数。未提交尾部回滚或在续传时截断，不能仅凭文件长度跳过数据。SQLite 不存文件正文。

客户端下载使用 URLSession delegate 批量接收，同时限制每响应内存大小，拒绝超限响应及重定向；不逐字节追加大型 Data。下载过程中保留可验证前缀，结束时同步、完整认证并移入正式密文缓存，再发送回执。

服务端文件操作使用 os.Root 约束目录，全局最多 16 个分块处理，同文件写入串行。上传使用随读取进度刷新的空闲截止，下载按 64 KiB 重新核验授权并刷新写入截止，不以大请求延长权限检查粒度。

服务端重启意味着旧附件在线连接全部结束：启动时将旧 pending 接收者标记 skipped，未完成上传取消，已完成上传结束分发，回收相应临时密文和孤儿。不会在新进程里给旧投递重新登记接收资格。客户端已经验证的本地副本不因此失效。

## 加密记录

使用 AES-256-GCM，每对象独立随机 32 字节密钥，只开始一次加密。以 256 KiB 明文为记录，空文件也有一条认证记录，各记录为 ciphertext 加 16 字节 tag。该大小独立于 1 MiB 网络块。

每记录 nonce 为 4 个零字节加 64 位大端记录序号。AAD 为 UTF-8 的 Chirp attachment AES256GCM v1 换行格式，绑定房间、准确发送身份、对象 ID、总长度、记录数和位置。逐记录认证、精确长度及通过加密描述取得的完整密文摘要共同拒绝修改、截断、换序和拼接。

缩略图通过 HKDF-SHA256 派生独立子钥，salt 为文件 ID，info 为 Chirp attachment thumbnail v1，使用随机 nonce 的 GCM combined 格式及 index=-1 的 AAD。实现见[AttachmentCrypto](../Client/apple/Shared/AttachmentCrypto.swift)。

## 本地清理与导出

Apple 在 `Caches/ChirpRoomAttachments` 下按入房建立随机目录，只保存密文并排除备份。缓存初始化清除上次进程遗留目录，密钥保存在可撤销的 `AttachmentLease` 内存中。离房、切房、登录或入房失效、清缓存时先退役 lease，再取消下载、回执重试与自动队列，关闭预览并清密文。Android 在应用缓存 `chirp-attachments` 下管理入房文件，Windows 协议进程在应用数据目录下创建临时 `session-*` 目录。[Apple 缓存](../Client/apple/Shared/AttachmentCache.swift) · [Android 附件会话](../Client/android/app/src/main/kotlin/cn/youzifeile/chirp/media/RoomAttachments.kt) · [Windows 附件会话](../Client/windows/engine/attachment_session_windows.go)

服务端回收、管理信息到期和迟到状态不能删除已成功接收的本地缓存。用户清空缓存影响全部窗口，旧附件不再从服务端补回，此后仍可收发新附件。显式导出时重新认证实际使用的密文，直接写入用户选择的目标，不覆盖同名文件，失败删除本次不完整输出，不在缓存准备明文副本。

发送者离房只终止未完成上传，完整上传由剩余原接收者继续接收。已经导出、截图、复制或用修改版客户端保存的内容无法撤回。协议故障注入与设备验收入口见[开发与验证](development.md)。
