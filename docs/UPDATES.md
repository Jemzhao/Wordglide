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

## 0.3.1 更新通道迁移

0.3.1 使用新的本地代码签名身份和 Sparkle 公钥。从 0.3.0 或更早版本升级需要手动替换应用一次，启动后按需重新授予辅助功能和屏幕录制权限。完成迁移后，使用菜单栏“检查更新…”获取后续版本。[手动迁移步骤](DISTRIBUTION.md#手动迁移到-031)

| 客户端 | Latest Release 更新清单 | Sparkle 钥匙串账户 |
| --- | --- | --- |
| 0.3.0 | `appcast.xml`，固定为 0.3.0 原签名文件 | `app.wordglide.mac` |
| 0.3.1 及后续版本 | `appcast-v2.xml`，由新版更新密钥签名 | `app.wordglide.mac.v2` |

旧客户端的验证公钥和更新地址已随应用包签名固定。新版 Latest Release 继续提供原始 `appcast.xml`，其签名和指向 `v0.3.0` 的安装包链接完整保留。原版客户端仍可检查其通道，新版只能通过手动下载完成首次迁移。

## 配置新版发布通道

先完成工具链和稳定的本地代码签名准备，再解析依赖并配置通道。[开发指南](DEVELOPMENT.md)

```sh
swift package resolve
./scripts/setup-updates.sh --repository Jemzhao/Wordglide --channel v2
```

`setup-updates.sh` 通过固定版本的 Sparkle `generate_keys` 读取 v2 账户的 Ed25519 公钥，系统可能询问钥匙串访问权限。原项目的正式发布固定使用已随 0.3.1 分发的 v2 公钥。脚本核对公钥后，将仓库、通道和更新配置写入 Git 忽略的 `.local/updates.plist`。以后 `setup-updates.sh` 和 `prepare-update.sh` 读取已保存的通道。钥匙串密钥不可用或不匹配时，从备份恢复原密钥。

新版应用的 `SUFeedURL` 使用以下固定地址。

```text
https://github.com/Jemzhao/Wordglide/releases/latest/download/appcast-v2.xml
```

Fork 项目时，将命令中的仓库名换为自己的公开仓库，并配置独立的代码签名身份。脚本拒绝将原项目的正式代码签名证书和更新密钥用于 fork。脚本按 GitHub 仓库和通道选择钥匙串账户，同一仓库的大小写写法会使用同一个账户。首次配置会创建或复用对应账户中的更新密钥。新版清单需要上传至对应仓库的正式 Latest Release。

如果 fork 已有独立密钥，把原密钥从加密备份导入脚本提示的新账户，再运行配置命令。脚本会核对原公钥并保留现有客户端兼容性。若 fork 曾与原项目共用正式密钥，先把 fork 的旧 `.local/updates.plist` 移出工作区，再为该 fork 建立独立的更新通道。已安装的 fork 客户端需要手动迁移一次。

## 备份签名身份与更新密钥

1. 在磁盘工具中创建加密的读写磁盘映像，挂载为 `Wordglide-Update-Backup`。把映像保存在仓库和云同步目录之外，并将解锁密码另存于可信的密码管理器。
2. 从项目根目录运行下面的命令，将 v2 Sparkle 私钥直接导出到加密卷。保留同次公开配置，以便恢复后核对公钥。

   ```sh
   (
     set -eu
     umask 077
     backup_dir="/Volumes/Wordglide-Update-Backup"
     test -d "$backup_dir"
     test ! -e "$backup_dir/wordglide-sparkle-v2.key"
     key_tool="$(./scripts/sparkle-tools.sh generate_keys)"
     "$key_tool" --account app.wordglide.mac.v2 -x "$backup_dir/wordglide-sparkle-v2.key"
     cp .local/updates.plist "$backup_dir/updates-v2.plist"
   )
   ```

3. 确认两个备份文件存在后卸载加密卷，复制加密映像到独立的备份介质。用加密的 Time Machine 备份保管本地代码签名所在的登录钥匙串，并记录签名证书的公开指纹。单独保存证书或 `.local/signing-identity` 无法恢复其私钥。
4. 在启用发布前验证能打开加密备份。需要更换机器时，先恢复原代码签名钥匙串，在没有该 v2 账户的钥匙串中使用 `generate_keys --account app.wordglide.mac.v2 -f <备份文件>` 导入更新私钥。比较 `generate_keys --account app.wordglide.mac.v2 -p` 输出与备份 plist 的 `SUPublicEDKey`，再配置并准备发布。

私钥备份只存放在受控的加密介质上。Git、Release 和 DMG 只应包含发布文件及公开配置。

## 准备一个版本

1. 同时增加 `Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。例如从 `0.3.3` 的构建 `12` 升至 `0.3.4` 的构建 `13`。Sparkle 按数字段比较内部构建号，`12` 和 `12.0` 等价。
2. 运行测试，提交要发布的改动，在该提交创建与 `Info.plist` 版本一致的本地标签，例如 `v0.3.4`。原项目的正式发布要求当前提交与标签一致，工作区干净。发布说明可以保存在仓库之外。
3. 执行准备命令。

```sh
./scripts/test.sh
./scripts/prepare-update.sh
# 或将这一版本的说明嵌入更新窗口：
./scripts/prepare-update.sh --release-notes /absolute/path/release-notes.md
```

两种准备命令二选一。原项目的正式更新使用既有代码签名证书。脚本从版本标签归档源码，在隔离目录按 `Package.resolved` 解析、构建并调用 Sparkle 签名工具，再核对代码签名、版本号与构建号。设置 `WORDGLIDE_ADHOC_SIGNING=1` 会在访问钥匙串和构建前被拒绝。Sparkle 从 DMG 中的应用读取版本、最低系统及架构，生成并验证清单。

生成安装包前，脚本会下载配置通道在 GitHub Latest 上的更新清单并验签。候选构建号必须高于清单中的所有构建号。清单缺失、网络错误或验签失败都会停下准备流程。

Fork 第一次发布某个通道时运行 `./scripts/prepare-update.sh --first-release`。脚本仅在 Latest 缺少该通道的清单，且公开发布记录中也没有同名清单时继续。该选项仅用于 fork，可以和 `--release-notes` 一起用。

以 `0.3.1` 的 Apple Silicon 构建为例，原项目的发布目录包含以下文件。

```text
build/updates/0.3.1/
├── Wordglide-0.3.1-macOS-arm64.dmg
├── Wordglide-0.3.1-macOS-arm64.dmg.sha256
├── appcast.xml
├── appcast.xml.sha256
├── appcast-v2.xml
└── appcast-v2.xml.sha256
```

原项目的 v2 准备流程从固定的 `v0.3.0` Release 下载旧 `appcast.xml`，核对内置的 SHA-256 后逐字节保留原文件，并生成配套校验文件。此步骤需要访问 GitHub。将原始 Release 的清单和 DMG 附件一并保留，以维持旧签名清单引用的固定安装包地址。

可选的 Markdown 源文件也会保留在该目录，内容已嵌入新版清单。新版清单使用固定版本的完整更新包，例如 `…/releases/download/v0.3.1/Wordglide-0.3.1-macOS-arm64.dmg`。

应用、DMG、校验文件和清单都在独立暂存目录中生成。验签和校验通过后，准备脚本将完整结果移入 `build/updates/<版本>/`。准备失败可直接重试，日常构建的 `build/Wordglide.app` 与 `build/` 下的 DMG 不受影响。已有同版本更新输出时拒绝覆盖。已发布版本如需变更，须提高显示版本和构建号后重新生成并签名。

## 发布到 GitHub

将构建时输出的标签及对应提交推送到实际仓库，再用该标签创建正式 Release。上传上述 **DMG、两份清单和三个校验文件**，再发布并设为 **Latest**。发布准备脚本只生成本地文件。

每个新的 Latest Release 都需要保留两份清单和配套校验文件。发布后匿名访问 `releases/latest/download/appcast.xml` 和 `releases/latest/download/appcast-v2.xml`，核对旧清单与 0.3.0 原附件逐字节一致，并验证新版清单及其固定版本 DMG 的签名和校验值。确认无误后通知使用者迁移。

首次对外发布前，应在另一台 Mac 上实际验证：安装到“应用程序”、首次打开、授权、检查更新、取消下载、下载安装、重启后的版本与功能、隐私授权及替换行为。本地签名、清单验证和匿名下载验证不能代替真实客户端跨版本升级验收；已完成范围见 [验证记录](VALIDATION.md)。

## 隔离升级验收

1. 准备一台测试 Mac 或带图形会话的 macOS 虚拟机，以及测试专用的 HTTPS 目录。HTTPS 证书需受测试机信任。在独立检出目录构建两个版本，后一个使用更高的 `CFBundleVersion`。两份构建使用同一应用标识、代码签名身份及测试专用的 Sparkle 密钥。在为测试包签名前，写入相同的测试 `SUFeedURL`（以 `appcast.xml` 结束）和 `SUPublicEDKey`，保持清单验签和解压前包验签开启。
2. 把含有已签名新版应用的 DMG 放入空目录。使用固定版本 Sparkle 的 `generate_appcast --account 测试账户 --download-url-prefix 测试HTTPS目录URL --maximum-deltas 0 安装包目录` 生成签名清单，下载 URL 前缀以 `/` 结束。用同一测试账户的 `sign_update --verify` 验证清单，并取清单 enclosure 的 `sparkle:edSignature` 验证 DMG。校对 enclosure 的下载地址及条目的构建号。正式发布脚本绑定 GitHub 更新地址，测试 HTTPS 目录可单独托管这一组已签名文件。[Sparkle 发布指引](https://sparkle-project.org/documentation/publishing/)
3. 在测试环境把旧构建安装到固定位置，打开并记下版本与构建号。授予辅助功能和屏幕录制权限，确认语言包可用，再用示例文本验证取词、OCR 和替换，作为升级前基线。
4. 用旧构建的「检查更新…」发现新版，下载时取消一次并确认仍可使用旧版。重新检查并确认安装，观察原应用退出、更新和重启。
5. 在同一安装位置核对重启后的版本和构建号，验证签名、语言包、原授权及实际取词、OCR 和替换。记录环境、结果和需要重新授权的情况。[验证记录](VALIDATION.md)

0.3.0 到 0.3.1 的正式迁移按手动替换路径验收。另外使用与 0.3.1 同身份、同公钥的更高构建号候选版，在隔离通道验证后续自动更新的下载、安装和重启。[手动迁移步骤](DISTRIBUTION.md#手动迁移到-031)

## 已安装用户如何进入更新通道

0.3.0 及更早版本与缺少更新配置的本地构建，需要手动安装带 v2 通道配置的 0.3.1 或更新版本。已经接入新版通道后，只要固定地址、公钥、签名身份和应用标识保持一致，即可检查并安装更高构建号的版本。

没有更新源、离线或 GitHub 暂时不可用时，翻译、取词、复制与输入框替换不依赖更新服务，继续正常工作；仍可按 [分发说明](DISTRIBUTION.md) 手动安装。
