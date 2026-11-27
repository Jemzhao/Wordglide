# DMG 下载与分发

安装包与发布说明入口为 [GitHub Releases](https://github.com/Jemzhao/Wordglide/releases)，请以实际发布的附件为准。当前流程使用维护者本机的自签名证书为应用签名，**没有 Developer ID 分发签名，也没有 Apple 公证**，适合把来源和限制说明清楚的小范围测试；制作 DMG 无需加入 Apple Developer Program。

DMG 只是安装载体，不会让 macOS 自动信任其中的应用。本地签名有助于开发时保持应用身份；它不能代替 Apple 对开发者身份的验证，也不能保证接收者无需确认即可打开。

## 制作安装包

构建需要 [开发指南](DEVELOPMENT.md) 所列的 Xcode 工具链，以及本机已配置的稳定签名身份。尚未配置的开发者应先阅读其中的“一次性本地签名”，使用自己的证书，不复制其他维护者的证书或私钥。

在项目根目录执行：

```sh
./scripts/package-dmg.sh
```

脚本会先重新构建并签名应用，再生成 DMG 和 SHA-256 校验文件。以 0.3.1 的 Apple Silicon 构建为例，输出如下。

```text
build/Wordglide-0.3.1-macOS-arm64.dmg
build/Wordglide-0.3.1-macOS-arm64.dmg.sha256
```

DMG 内包含 Wordglide、指向“应用程序”的快捷入口和安装说明。脚本只在本地生成文件。带更新通道的发布使用 `prepare-update.sh`，在独立目录生成并验证整套更新文件。单独打包得到的 DMG 保留在 `build/`。[应用内更新说明](UPDATES.md)

分享时同时提供 DMG、对应的校验文件、本页的安装说明及已验证的系统范围。校验文件需要与安装包来自可信渠道；单纯通过校验不等于已经验证发布者身份。

## 安装与首次打开

- 需要 **macOS 26 或更高版本**。当前提供的 `arm64` 安装包面向 Apple Silicon Mac；Intel 尚无对应产物，macOS 26 实机仍待验证。
- 双击 DMG，将 Wordglide 拖入“应用程序”，然后从“应用程序”打开。不要长期从 DMG 内运行。
- 已安装旧版时，先从菜单栏退出旧实例，再替换“应用程序”中的 Wordglide。

通过网络下载的未公证应用可能被 macOS 阻止打开。只有在确认安装包来源、确实愿意运行此测试版时，才由接收者本人尝试打开后，在“系统设置 → 隐私与安全性”中查看是否出现 Wordglide 的“仍要打开”，再按系统提示确认。该入口针对这一个应用；是否允许由系统版本和设备管理策略决定。参见 [Apple：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)。

**不需要安装或信任维护者的自签名根证书。** 不要关闭系统整体的安全检查，也不要以删除隔离属性代替确认来源。若提示应用“已损坏”“将损害你的电脑”，或受管理的设备不允许打开，应先停止安装，重新核对来源和校验值、重新下载或联系维护者；不要把所有警告都当成普通的未公证提示。

打开后还需完成应用自身的首次准备：

1. 在 Wordglide 设置中准备中英双向语言包，由 Apple 系统完成下载。
2. 授予辅助功能权限，供悬停取词、选区和输入框替换使用。
3. 如需 OCR，再授予屏幕录制权限。
4. 返回 Wordglide 重新检测并开启全局翻译；系统要求重启时退出后重新打开。

这些权限由每位使用者在自己的 Mac 上授予，安装包不会携带维护者的授权。详细使用步骤见 [README](../README.md#首次准备)。

## 核对下载文件

将 DMG 与 `.dmg.sha256` 文件放在同一目录。以 0.3.1 的文件名为例，在文件所在目录执行以下命令。

```sh
shasum -a 256 -c Wordglide-0.3.1-macOS-arm64.dmg.sha256
```

应显示对应 DMG 为 `OK`。若显示失败，先不要安装，重新取得可信来源的安装包和校验文件。版本号和架构以实际文件名为准。

## 手动迁移到 0.3.1

从 0.3.0 或更早版本升级需要手动安装一次。0.3.0 仍查询旧签名清单。请从 GitHub 下载当前正式版本。[最新发布](https://github.com/Jemzhao/Wordglide/releases/latest)

1. 等待翻译和替换完成，从菜单栏退出 Wordglide。
2. 从 GitHub Releases 下载最新的 `arm64` DMG 及配套 `.sha256` 文件，并核对校验值。[下载入口](https://github.com/Jemzhao/Wordglide/releases/latest)
3. 打开 DMG，把 Wordglide 拖入“应用程序”，出现提示时选择替换旧版。随后从“应用程序”打开新版。
4. 在 Wordglide 设置中重新检测权限。macOS 如有要求，重新授权辅助功能，使用 OCR 时再授予屏幕录制权限。

完成这次迁移后，使用菜单栏“检查更新…”获取后续版本。

## 更新方式

Wordglide 使用 Sparkle 检查 GitHub Releases 上的签名更新。0.5.0 及后续版本使用 `appcast-v3.xml`，0.3.1 至 0.4.1 使用 `appcast-v2.xml`，0.3.0 使用 `appcast.xml`。[发布通道](https://github.com/Jemzhao/Wordglide/releases)

同一通道内，客户端可以下载更高构建号的版本，由使用者确认安装。每个新的 Latest Release 都保留三份清单和对应的校验文件。[发布工具和密钥管理](UPDATES.md)

## 手动迁移到 0.5.0

0.5.0 使用新代码签名和更新公钥。0.4.1 及更早版本用户需从 GitHub Releases 下载 0.5.0 的 Apple Silicon DMG，退出旧版后将新版拖入“应用程序”。首次打开按 macOS 提示重新授予辅助功能权限，使用 OCR 时也重新检查屏幕录制权限。完成迁移后，可从菜单栏使用“检查更新…”。[下载入口](https://github.com/Jemzhao/Wordglide/releases/latest)

保持同一签名身份、应用标识和安装路径有助于沿用隐私授权，但系统仍可能要求重新确认。将来切换到 Developer ID 正式签名时，应单独验证授权与升级流程，不能直接假定与本地签名完全相同。

面向更广泛用户的正式分发仍建议使用 Developer ID 和 Apple 公证。当前 Sparkle 的独立更新签名负责校验更新内容，不能代替 Apple 对开发者身份的验证。
