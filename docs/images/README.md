# README 界面预览 / README previews

这些 PNG 由 Wordglide 的原生视图预览导出工具生成，使用固定的示例文字与状态。它们用于展示应用界面，不截取用户屏幕，不包含真实文档、剪贴板或个人信息。界面语言当前为简体中文，中英文 README 共享同一组预览。

These PNGs are exported from Wordglide's native views using fixed sample text and state. They illustrate the interface without capturing the user's screen, documents, clipboard, or personal information. Both READMEs use these previews; the interface shown is Simplified Chinese.

## 更新素材 / Refresh the previews

从项目根目录构建，再导出原生视图：

Build and export the native views from the project root:

```sh
./scripts/build-app.sh
build/Wordglide.app/Contents/MacOS/Wordglide --export-ui-previews
cp build/ui-previews/main-light.png docs/images/
cp build/ui-previews/card-light.png docs/images/
cp build/ui-previews/card-dark.png docs/images/
cp build/ui-previews/settings-light.png docs/images/
```

导出过程不请求取词权限、不进行翻译或粘贴。更新后检查两种语言首页中的布局、替代文字和图片路径；图片尺寸由 README 控制，无需修改原始 PNG。

Exporting does not request capture permissions, translate, or paste. Check the layout, alt text, and image paths in both READMEs after refreshing. The README controls display sizes; the original PNGs need no editing.
