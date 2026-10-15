# Wordglide app icon / 应用图标

中文 · [English](#english)

`AppIcon-master.png` 是经过确认的图标母版：淡绿色底、鼠尾草绿色的 W 与描边对话气泡。保留母版的透明边缘、颜色和构图；生成脚本只缩放和打包，不重新绘制图案。

母版由内置图像生成工具根据用户选定的图片编辑而来；编辑要求记录在 [AppIcon-prompt.txt](AppIcon-prompt.txt)。

在仓库根目录运行：

```sh
swift scripts/make-icon.swift "$PWD"
```

脚本要求母版为可解码的正方形 PNG，至少 1024 × 1024 像素。它生成以下派生文件：

| 文件 | 用途 |
| --- | --- |
| `AppIcon-master.png` | 唯一图标母版，修改设计时替换此文件 |
| `AppIcon.png` | 1024 × 1024 PNG，供文档使用 |
| `AppIcon.iconset/` | 16、32、128、256、512 点的 @1x 与 @2x PNG |
| `AppIcon.icns` | macOS 应用包图标 |

生成时不会修改母版。全部尺寸和 ICNS 容器验证成功后，才替换派生文件；输入无效时会停止。所有图标资产随项目依照根目录 `LICENSE` 分发。

## English

`AppIcon-master.png` is the approved icon master: a pale green background with a sage-green W and outlined speech bubble. Keep its transparent edges, colors, and composition. The generator only resizes and packages the image; it does not redraw the artwork.

The master was edited from the user-selected image with the built-in image generation tool. Its editing instructions are recorded in [AppIcon-prompt.txt](AppIcon-prompt.txt).

Run from the repository root:

```sh
swift scripts/make-icon.swift "$PWD"
```

The master must be a decodable square PNG of at least 1024 × 1024 pixels. The generated assets are:

| File | Purpose |
| --- | --- |
| `AppIcon-master.png` | Single source of truth; replace this file to change the design |
| `AppIcon.png` | 1024 × 1024 PNG for documentation |
| `AppIcon.iconset/` | 16, 32, 128, 256, and 512-point PNGs at @1x and @2x |
| `AppIcon.icns` | macOS application bundle icon |

The master is never modified. Generated assets are replaced only after validating all pixel dimensions and decoding the ICNS container. Invalid input stops generation. Icon assets are distributed under the repository's root `LICENSE`.
