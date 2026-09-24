# Windows + 普通 Apple 账号：云端编译与安装

适用环境：只有 Windows、有 GitHub 账号、iPhone iOS 16 或以上。
本流程尚未在你的 iOS 27 手机上实测。云端生成 IPA、苹果签名、键盘共享配置是三个独立环节；构建成功不等于全部验证通过。

## 1. 把构建配置放到自己的 GitHub 仓库

1. 登录 GitHub，打开 https://github.com/jev-chat/jev-chat-jarvis-ios ，点击 **Fork → Create fork**。
2. 进入自己名下的仓库，点击 **Add file → Create new file**。
3. 文件名输入 `.github/workflows/build-ipa.yml`。
4. 用记事本打开本地项目内同名文件，复制全部内容到 GitHub 编辑框，然后点击 **Commit changes** 提交到默认分支。

只需添加这个工作流文件，它不依赖本说明文件。无需上传 Apple 密码、验证码、证书或模型 API Key。
工作流仅在手动点击时运行。GitHub 官方说明，公开仓库使用标准托管 runner 免费；私有仓库受账号分钟数及计费规则约束。

## 2. 编译并下载 IPA

1. 点击仓库顶部 **Actions**。如果是 Fork 后首次使用，先启用工作流。
2. 左侧选择 **Build iPhone IPA**，点击 **Run workflow → Run workflow**。
3. 等待此次运行显示绿色对勾，打开运行详情。
4. 在 **Artifacts** 区域下载 **JevJarvis-for-resigning**，解压得到 `JevJarvis-resign.ipa`。

产物保留 7 天，下载后的文件不受此保留期影响。失败时打开红色步骤查看报错，不要把“未生成 IPA”当成手机签名问题。

工作流用云端 Mac 编译主 App 和键盘扩展，运行项目已有检查，并保留 App Groups 权限信息供后续签名工具识别。产物只有本地占位签名，没有苹果签发的设备授权，不能直接点击安装，也不能直接上传 TestFlight。
工作流在云端临时源码中清除原作者内置的模型 API Key；你的源码文件不因此修改。安装后必须在 App 内配置自己的模型接口。

## 3. Windows 上签名安装

可以尝试 [Sideloadly 官方版](https://sideloadly.io/)。官网支持 Windows 和普通 Apple 账号，但本项目在 iOS 27 上的完整键盘功能仍需实测。

1. 按官网下载页的 Windows 要求安装 Sideloadly 和所需的 Apple 驱动组件。官网要求网页版 iTunes/iCloud；如已装其他版本，先阅读其当前说明处理冲突。
2. 数据线连接 iPhone，解锁并选择“信任此电脑”。确认签名工具能识别手机。
3. 导入 `JevJarvis-resign.ipa`，选择手机，在签名工具中填写自己的 Apple 账号，按提示完成登录和验证。
4. **保留 JevKeyboard 扩展**；不要启用删除扩展/移除 PlugIns 的选项。使用 Apple ID 签名安装模式。
5. 如果系统提示，前往“设置 → 通用 → VPN 与设备管理”信任自己的开发者身份；在“设置 → 隐私与安全性 → 开发者模式”启用并按提示重启。

普通账号的设备授权 7 天后失效，需要续签。自动续签仍需要电脑和手机满足工具的连接、运行条件，不等于永久签名。

## 4. 验证键盘是否真正可用

1. 打开 Jev Jarvis，进入“模型”，选择你使用的服务，填写自己的接口和 Key，测试连接，并在“试一试”中测试。
2. 手机“设置 → 通用 → 键盘 → 键盘 → 添加新键盘”，添加 **Jev 键盘**，打开“允许完全访问”。
3. 在 App 的话术配置里做一个容易识别的修改，去备忘录或微信切换到 Jev 键盘，确认键盘读取到同一配置。
4. 复制一条无敏感信息的测试消息，在键盘中点“分析剪贴板”，确认能生成并插入候选文本。

如果主 App 正常，但键盘提示未配置、读不到你改过的话术或完全没有键盘入口，就还没有安装成功：先检查是否保留了扩展，然后检查签名后的 App Groups。
本项目代码固定使用 `group.com.jevchat.jarvis.ios`。重签工具如果更改或移除共享组权限，两个组件与代码中的标识必须同步处理；不要通过删除 App Groups 来假装修复。仅凭 App 内共享容器状态的绿灯也不能证明两个进程实际共享成功。
若免费签名工具不能为此项目提供可用的共享组，需进一步适配重签后的标识或改用作者的 TestFlight，不能保证原样 IPA 可用。

## 官方参考

- [GitHub 托管构建环境与公开仓库免费额度](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Sideloadly 下载及安装说明](https://sideloadly.io/)
- [苹果普通开发账号与 7 天有效期](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [苹果开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
