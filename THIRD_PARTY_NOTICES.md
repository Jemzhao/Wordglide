# 第三方许可与来源

Wordglide 的取词、浮窗布局、交互监测、文本处理和替换基础实现改编自
[HoverTranslate](https://github.com/Kianzzz/hover-translate)。

- 上游作者及版权：Copyright (c) 2026 Kianzzz。
- 上游许可：MIT License，全文保留于 [ThirdParty/HoverTranslate-LICENSE](ThirdParty/HoverTranslate-LICENSE)。构建脚本会将该文件复制到应用资源中。
- 来源版本：初始实现参考了上游源码副本，未记录对应的提交 SHA 或发布标签，因此目前无法准确标注参考版本。
- Wordglide 的修改和新增实现采用根目录 [MIT 许可](LICENSE)。

## Sparkle

- 项目：[Sparkle](https://sparkle-project.org/)，源码：[sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)。
- 固定依赖版本：[2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)，对应提交 `eef1a539a373c1f1a320624b1130fc5de7b2e100`，由 Swift Package Manager 下载官方二进制。
- 版权：包括 Andy Matuschak、Elgato Systems GmbH、Kornel Lesiński、Mayur Pawashe、C.W. Betts、Petroules Corporation、Big Nerd Ranch；各自年份及完整声明见下列上游许可全文。
- 许可：MIT License。上游许可全文及随附组件声明保留在 [ThirdParty/Sparkle-LICENSE](ThirdParty/Sparkle-LICENSE)；构建脚本将其复制到应用资源目录，并保留 Sparkle 框架内的许可与资源。
- Wordglide 使用 Sparkle 完成应用内更新，不将其用于翻译文字、截图或分析统计。

SwiftUI、AppKit、Translation、Vision、ScreenCaptureKit 等为 Apple 平台框架，不随本项目重新分发。
