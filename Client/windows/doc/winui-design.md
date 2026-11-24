# Windows 客户端 WinUI 设计说明

Windows 使用 WinUI 3，沿用 Mac 客户端的森林绿、纸面底色、声波标记和首字头像。主窗口按房间导航、成员区和通话操作划分。导航折叠、标题栏、对话框、文件选择器和键盘焦点遵循 Windows 原生行为。

| 视图 | Windows 实现 | 交互 |
| --- | --- | --- |
| 登录 | [MainPage.xaml](../Chirp/MainPage.xaml) | 宽窗口并排显示品牌和表单，窄窗口收成单列。地址框按 Enter 连接，成功后焦点移到通行密钥登录，也可选择手机授权或注册 |
| 房间与成员 | [RoomStage.cs](../Chirp/RoomStage.cs) | 标题区显示房名、加密和访问条件。成员卡随宽度换列，显示头像、姓名和实时状态。通话中点成员可查看详情或调节对方音量 |
| 通话操作 | [RoomStage.cs](../Chirp/RoomStage.cs) | 状态和声音设置固定在房间底部。入房时默认静音，通话时可开关麦克风或离房。在其他页面可从侧栏返回当前通话 |
| 聊天 | [Workspace.cs](../Chirp/Workspace.cs) | 宽窗口在右侧展开聊天，内容区不足 700 DIP 时切换整栏。Ctrl+Shift+B 打开或收起聊天，打开后可直接输入。Enter 发送，Shift+Enter 换行 |
| 好友与设置 | [Settings.cs](../Chirp/Settings.cs) | 好友可搜索，设备指纹与信任操作可展开查看。资料卡下按使用偏好、账号与安全、本机身份分组，外观和语言可就地切换 |
| 配对 | [PairingCamera.cs](../Chirp/PairingCamera.cs) | 摄像头、二维码图片或本机粘贴配对请求，核对安全码后使用 Windows 用户验证 |
| 主题 | [App.xaml](../Chirp/App.xaml) | 浅色、深色和系统高对比度三套语义画刷 |

构建、运行、原生协议测试和 MSIX 打包见 [Windows 开发手册](README.md)。

## Windows 实机参考

2026-11-19 在 150% 显示缩放、系统默认文字大小下检查了 1120 × 780、900 × 620 和 640 × 620 DIP 窗口。用本机测试服务验证了登录、静音入房、发送中英文消息、返回通话及刷新时的键盘焦点。截图、环境和验证范围见[实机截图索引](../../../design-system/chirp-together/previews/README.md#windows-桌面客户端)。
