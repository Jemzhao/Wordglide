# 应用内更新与 GitHub 发布

Wordglide 从 **0.3.0** 起集成 [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)。维护者可以沿用本地代码签名，以 [Jemzhao/Wordglide Releases](https://github.com/Jemzhao/Wordglide/releases) 托管更新，不需要为了 Sparkle 本身加入 Apple Developer Program。可下载版本以实际发布的附件为准；仓库和源码存在不等于已经发布应用更新。

Sparkle 检查已发布的版本，下载安装包并由使用者确认安装、重启。普通代码提交不会直接推送给使用者，只有下面的正式 Release 流程会提供更新。应用关闭系统信息上报，不发送文字、截图或翻译历史；检查更新和下载仍会向 GitHub 发起网络请求，网络服务会获得通常的连接信息。

## 两套独立签名

| 用途 | 保存位置 | 需要保持稳定的内容 |
| --- | --- | --- |
| 应用代码签名 | 维护者的用户钥匙串 | 当前本地代码签名证书、应用标识，尽量保持安装路径稳定 |
| Sparkle 更新验签 | 私钥在维护者登录钥匙串；公钥随应用分发 | 同一 Ed25519 公私钥配对 |

本地签名不能代替 Developer ID 或 Apple 公证。接收者首次打开仍可能需要本人确认，系统及设备管理策略也可能阻止运行。自动更新不会关闭这些检查，也不能保证每次更新都沿用辅助功能、屏幕录制授权。

应用要求 **更新清单签名**和**解压前更新包验签**，公钥写入应用的 `SUPublicEDKey`；发布脚本会验证包和清单的签名。清单验签失败不会因经过一段时间而放宽。SHA-256 文件供人工核对，不能代替更新签名。详见 [Sparkle 发布文档](https://sparkle-project.org/documentation/publishing/)及 [Sparkle 配置说明](https://sparkle-project.org/documentation/customization/)。

## 第一次配置

先完成 [开发指南](DEVELOPMENT.md) 中的工具链及本地签名准备，并解析已锁定的依赖：

```sh
swift package resolve
./scripts/setup-updates.sh
```

`setup-updates.sh` 调用当前固定版本的 Sparkle `generate_keys`。首次创建 Ed25519 密钥，以 `app.wordglide.mac` 为 account 保存在登录钥匙串；已有密钥时复用，不轮换密钥、不导出私钥。系统可能询问钥匙串访问权限。配置后的公钥与钥匙串不匹配或原密钥不可用时，脚本会停止，不能通过重新生成密钥修复已发出的客户端。

本地 `.local/updates.plist` 仅存公开配置，不保存私钥，也不提交到 Git。**没有仓库时可以先生成密钥，但不会写入占位更新地址，也不会联网检查更新。**

原项目的发布仓库为 [Jemzhao/Wordglide](https://github.com/Jemzhao/Wordglide)。在维护者本机配置：

```sh
./scripts/setup-updates.sh --repository Jemzhao/Wordglide
```

它只保存配置，不创建仓库、不登录 GitHub、不上传任何文件。生成的固定检查地址为：

```text
https://github.com/Jemzhao/Wordglide/releases/latest/download/appcast.xml
```

该地址只有在正式 Latest Release 上传 `appcast.xml` 后才可用。Fork 项目时，将命令中的仓库名换为自己的公开仓库，并使用自己的签名身份和更新密钥；不能为原项目已经分发的客户端发布更新。

请妥善保管代码签名身份和 Sparkle 更新私钥。它们不应出现在源码、Release、日志或截图中；更换电脑前应自行安排可靠的钥匙串/密钥备份。不要为了让接收者安装应用而向其分发私钥或要求其信任你的根证书。

## 准备一个版本

1. 同时增加 `Info.plist` 的 `CFBundleShortVersionString` 和单调递增的 `CFBundleVersion`。例如用户版本 `0.3.1`、内部构建号 `10`。Sparkle 主要用内部构建号判断是否更新。
2. 运行测试，按需要准备一份 Markdown 发布说明。
3. 执行准备命令：

```sh
./scripts/test.sh
./scripts/prepare-update.sh
# 或将这一版本的说明嵌入更新窗口：
./scripts/prepare-update.sh --release-notes /absolute/path/release-notes.md
```

两种准备命令二选一。正式更新需要稳定的代码签名证书。设置 `WORDGLIDE_ADHOC_SIGNING=1` 会在访问钥匙串和构建前被拒绝。脚本检查仓库、HTTPS 更新源和原 Sparkle 密钥，再调用 `package-dmg.sh` 构建并签名。Sparkle 从 DMG 中的应用读取版本、最低系统及架构，生成并验证清单。

以 `0.3.0` 的 Apple Silicon 构建为例，最终目录是：

```text
build/updates/0.3.0/
├── Wordglide-0.3.0-macOS-arm64.dmg
├── Wordglide-0.3.0-macOS-arm64.dmg.sha256
├── appcast.xml
└── appcast.xml.sha256
```

可选的 Markdown 源文件也会保留在该目录；内容已嵌入清单，无需另行托管。更新包使用固定版本下载地址，例如 `…/releases/download/v0.3.0/Wordglide-0.3.0-macOS-arm64.dmg`，不会让已签名条目指向会变化的 `latest` 安装包。当前生成完整更新包，暂不生成差分更新。

应用、DMG、校验文件和清单都在独立暂存目录中生成。验签和校验通过后，准备脚本将完整结果移入 `build/updates/<版本>/`。准备失败可直接重试，日常构建的 `build/Wordglide.app` 与 `build/` 下的 DMG 不受影响。已有同版本更新输出时拒绝覆盖。已发布版本如需变更，须提高显示版本和构建号后重新生成并签名。

## 发布到 GitHub

在实际仓库中创建正式 Release，标签必须与准备时一致，例如 `v0.3.0`，上传上述 **DMG、appcast.xml 及两个校验文件**，再发布并设为 **Latest**。当前脚本只在本地准备，不创建标签、提交、上传、发布或配置 CI。

每个新 Latest Release 都必须包含名为 `appcast.xml` 的附件，因为客户端的固定入口使用 `releases/latest/download/appcast.xml`。Draft 或 Pre-release 不作为这条正式更新通道。确认匿名访问可下载清单及其固定版本 DMG 后，再通知使用者。

首次对外发布前，应在另一台 Mac 上实际验证：安装到“应用程序”、首次打开、授权、检查更新、取消下载、下载安装、重启后的版本与功能、隐私授权及替换行为。本地签名、清单验证和匿名下载验证不能代替真实客户端跨版本升级验收；已完成范围见 [验证记录](VALIDATION.md)。

## 隔离升级验收

1. 准备一台测试 Mac 或带图形会话的 macOS 虚拟机，以及测试专用的 HTTPS 目录。HTTPS 证书需受测试机信任。在独立检出目录构建两个版本，后一个使用更高的 `CFBundleVersion`。两份构建使用同一应用标识、代码签名身份及测试专用的 Sparkle 密钥。在为测试包签名前，写入相同的测试 `SUFeedURL`（以 `appcast.xml` 结束）和 `SUPublicEDKey`，保持清单验签和解压前包验签开启。
2. 把含有已签名新版应用的 DMG 放入空目录。使用固定版本 Sparkle 的 `generate_appcast --account 测试账户 --download-url-prefix 测试HTTPS目录URL --maximum-deltas 0 安装包目录` 生成签名清单，下载 URL 前缀以 `/` 结束。用同一测试账户的 `sign_update --verify` 验证清单，并取清单 enclosure 的 `sparkle:edSignature` 验证 DMG。校对 enclosure 的下载地址及条目的构建号。正式发布脚本绑定 GitHub 更新地址，测试 HTTPS 目录可单独托管这一组已签名文件。[Sparkle 发布指引](https://sparkle-project.org/documentation/publishing/)
3. 在测试环境把旧构建安装到固定位置，打开并记下版本与构建号。授予辅助功能和屏幕录制权限，确认语言包可用，再用示例文本验证取词、OCR 和替换，作为升级前基线。
4. 用旧构建的「检查更新…」发现新版，下载时取消一次并确认仍可使用旧版。重新检查并确认安装，观察原应用退出、更新和重启。
5. 在同一安装位置核对重启后的版本和构建号，验证签名、语言包、原授权及实际取词、OCR 和替换。记录环境、结果和需要重新授权的情况。[验证记录](VALIDATION.md)

若验收对象是已公开发布的 0.3.0，需在测试机安装实际发布的 DMG。它的更新地址及公钥由已签名的应用包固定，正式升级验收需要在其实际更新源提供由原发布身份签名的更高构建号候选版。隔离通道可以先验证安装器和重启过程。

## 已安装用户如何进入更新通道

- **0.2.5 及之前**没有更新器，需手动安装一次已配置好仓库和公钥的 0.3.0 或更新版本。
- **未配置仓库地址的本地 0.3.0**也不知道发布仓库在哪里，需要手动安装一次已包含上述更新地址和公钥的构建。
- 之后，只要固定检查地址、公钥、应用标识和发布规则保持一致，客户端即可发现并安装更高构建号版本。发布到新仓库或轮换公钥涉及客户端迁移，应在旧通道仍可用时单独设计，不能仅修改维护者的本地配置。

没有更新源、离线或 GitHub 暂时不可用时，翻译、取词、复制与输入框替换不依赖更新服务，继续正常工作；仍可按 [分发说明](DISTRIBUTION.md) 手动安装。
