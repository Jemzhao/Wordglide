# 开发指南

Wordglide 是单个 SwiftPM 可执行模块及对应测试模块。SwiftPM 会自动解析 `Package.resolved` 固定的 Sparkle 依赖，无需手动安装 framework；源码职责划分见 [架构说明](ARCHITECTURE.md)。

## 工具链

- 部署目标为 macOS 26+，构建 SDK 须包含 macOS 26.4 Translation API。
- 当前验证环境是 Apple Silicon、macOS 27.0.1、Xcode 27.0、Swift 6.4、macOS SDK 27.0。
- `Package.swift` 使用 Swift tools 5.9 和 Swift 5 语言模式；这不代表 Xcode 15 自带 SDK 可以构建本项目。

可用 Xcode 打开 `Package.swift` 编辑和调试。运行需要系统授权的功能时，使用脚本生成的 `.app`。

若系统 `xcode-select` 选中 Command Line Tools，构建与测试脚本会在当前进程使用 `/Applications/Xcode.app` 的完整工具链，以加载 SwiftUI 宏插件，不修改全局选择。显式设置的 `DEVELOPER_DIR` 始终优先；Xcode 安装在其他路径时可先设置它。

## 日常命令

在项目根目录运行：

```sh
./scripts/test.sh
./scripts/build-app.sh
./scripts/run.sh
```

测试脚本执行 XCTest 与不申请权限的 `--self-test`。构建默认使用 release 配置，产物为 `build/Wordglide.app`；`CONFIGURATION=debug ./scripts/build-app.sh` 可生成调试版应用。`run.sh` 仅在应用不存在时构建，修改后需显式重新构建。

应用与中英文 README 共享 `Assets/AppIcon.png` / `Assets/AppIcon.icns`。选定的 PNG 母版为 `Assets/AppIcon-master.png`，图案为淡绿色底、鼠尾草绿描边气泡与 W。母版、生成提示词及派生资产说明见 [Assets/README.md](../Assets/README.md)。

更新母版后，从项目根目录重新生成各尺寸图标与 ICNS：

```sh
swift scripts/make-icon.swift "$PWD"
./scripts/build-app.sh
```

`make-icon.swift` 只缩放并打包母版，不会重绘图案或生成旧版图标。更新涉及主窗口标识时，重新导出文档预览，步骤见 [预览素材说明](images/README.md)。

## 一次性本地签名

每位开发者在自己的机器上配置自己的身份。首次运行前先确认愿意向用户登录钥匙串新增本地证书和私钥：

```sh
./scripts/setup-local-signing.sh
./scripts/build-app.sh
```

配置脚本创建或复用名为 `Wordglide Local Development` 的自签名代码签名证书，证书有效期 10 年。它不是 Developer ID 分发证书，不能替代 Apple 公证；测试版分发边界见 [分发说明](DISTRIBUTION.md)。私钥在用户钥匙串中设为不可导出，只预授权 `/usr/bin/codesign` 使用；信任仅限用户域的代码签名用途。系统可能要求在钥匙串确认框中批准操作。脚本不修改辅助功能、屏幕录制等隐私授权。

`.local/signing-identity` 只保存该机器所用证书的公开 SHA-1 指纹，整个 `.local/` 已忽略。临时私钥文件在配置结束后清理。不要提交私钥、证书导出包或复制维护者的签名身份；其他开发者应自行配置。

重复运行脚本会复用原身份。已有配置的证书或私钥不可用时会报错，不会静默创建新身份。正常重新编译继续使用同一证书、应用标识和 `build/Wordglide.app` 路径；首次由临时签名切换或更换证书仍需重新授权。系统策略变化也可能要求重新确认。

### 使用已有证书

可先列出自己机器上有效的代码签名身份：

```sh
security find-identity -v -p codesigning
```

将其中证书的 40 位 SHA-1 指纹设为环境变量后构建；下列值为占位符，需自行替换：

```sh
WORDGLIDE_SIGNING_IDENTITY="替换为40位证书指纹" ./scripts/build-app.sh
```

`WORDGLIDE_SIGNING_KEYCHAIN` 可指定现有用户钥匙串。选择身份时必须包含可用私钥，不能仅凭相同证书名称。

构建脚本会先检查稳定身份，独立暂存、签名并严格验证新应用后才替换旧应用。找不到身份时停止并保留旧应用，不会自动退回临时签名。只有显式设置 `WORDGLIDE_ADHOC_SIGNING=1` 才使用临时签名，适合不需要隐私授权的检查；其身份可能随重新编译变化。

### 签名稳定性检查

```sh
./scripts/check-signing-stability.sh
```

该脚本对两个内容不同的样例程序检查相同证书绑定的 designated requirement，不运行样例、不申请隐私权限。它证明签名身份跨代码变化保持稳定，不能代替两次真实应用更新之间的辅助功能和屏幕录制权限验收。签名身份背景见 [Apple 的代码签名要求说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。

## 开发检查入口

以下检查不申请权限或下载语言包：

```sh
.build/debug/Wordglide --self-test
build/Wordglide.app/Contents/MacOS/Wordglide --check-engine
build/Wordglide.app/Contents/MacOS/Wordglide --check-window-flow
.build/debug/Wordglide --export-ui-previews
```

- `--self-test` 检查文本、坐标、布局与状态等内部逻辑。先运行 `scripts/test.sh` 可生成 debug 二进制。
- `--check-engine` 检查已安装模型，仅在模型就绪时执行真实翻译。
- `--check-window-flow` 会打开和关闭测试窗口并退出。运行前退出正常实例；从项目根目录运行时报告位于 `build/window-check.txt`。
- `--export-ui-previews` 只用示例内容渲染应用自身视图，不截取用户屏幕。深浅色预览位于 `build/ui-previews/`。

当前构建已获辅助功能授权时，还可运行独立样例的实际整框/选区粘贴及撤销检查：

```sh
build/Wordglide.app/Contents/MacOS/Wordglide --check-direct-replacement-flow
```

该检查会操作自己创建的样例窗口，运行前退出正常实例并避免同时编辑其他内容；未授权时直接跳过，不请求权限。跨应用人工验收请使用 [选区样例](../scripts/selection-fixture.html) 和 [验证清单](VALIDATION.md#跨应用人工验收清单)。

## 提交前

按 [贡献指南](../CONTRIBUTING.md) 完成与改动相关的检查，更新用户可见行为对应的 [更新记录](../CHANGELOG.md) 和验证证据。构建产物、语言包、签名配置及系统授权属于本机状态，不纳入源码提交。
