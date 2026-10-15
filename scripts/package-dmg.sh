#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"

if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == --help ]]; then
    print -- "Usage: ./scripts/package-dmg.sh"
    print -- "Build a release app with the configured local signing identity, then create a test DMG and SHA-256 file in build/."
    print -- "This does not provide Developer ID signing, Apple notarization, or publication."
    exit 0
  fi
  print -u2 -- "Usage: ./scripts/package-dmg.sh [--help]"
  exit 2
fi

# Keep the existing signing identity and permissions; never create or import
# certificates as a side effect of packaging.
CONFIGURATION=release "$project_dir/scripts/build-app.sh"
app_dir="$project_dir/build/Wordglide.app"
/usr/bin/codesign --verify --deep --strict "$app_dir"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist" >/dev/null

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_dir/Contents/Info.plist")"
minimum_system="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$app_dir/Contents/Info.plist")"
[[ "$version" =~ '^[0-9A-Za-z][0-9A-Za-z._-]*$' ]] || {
  print -u2 -- "无法将应用版本用于安装包文件名。"
  exit 1
}
architectures="$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/Wordglide")"
case "$architectures" in
  arm64) architecture=arm64 ;;
  x86_64) architecture=x86_64 ;;
  *)
    if [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]; then
      architecture=universal2
    else
      print -u2 -- "不支持的应用架构：$architectures"
      exit 1
    fi
    ;;
esac

staging_dir="$(/usr/bin/mktemp -d "$project_dir/build/.wordglide-dmg.XXXXXXXX")"
cleanup() { /bin/rm -rf "$staging_dir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

payload="$staging_dir/payload"
/bin/mkdir "$payload"
# Copy only the sealed application, not the project, local identity, or keys.
/usr/bin/ditto "$app_dir" "$payload/Wordglide.app"
/bin/ln -s /Applications "$payload/Applications"
if /usr/bin/plutil -extract SUFeedURL raw "$app_dir/Contents/Info.plist" >/dev/null 2>&1; then
  update_instructions="此版本已配置 Sparkle 更新源。可在菜单栏或设置中检查更新，
也可开启自动检查；发现新版本后由你确认下载与安装。
更新清单与安装包均验证提供者的更新签名，未通过验证不会安装。"
else
  update_instructions="此版本已集成 Sparkle，但尚未配置在线更新源，设置中会显示此状态。
提供者建好 GitHub 仓库后，会分发首个配置好更新源的版本；该版本需手动安装一次。
在此之前，新版仍由提供者分发，退出旧版后手动替换。"
fi
/bin/cat > "$payload/安装说明.txt" <<EOF
Wordglide $version — 小范围测试版

系统要求：macOS $minimum_system 或更新版本。
此安装包架构：$architecture。当前 Apple Silicon 已实测，Intel 尚未验收。

安装
1. 将 Wordglide.app 拖到旁边的 Applications（应用程序）文件夹。
2. 从“应用程序”打开 Wordglide，不要直接从磁盘映像运行。
3. 此包使用本地签名，未经 Apple Developer ID 签名或 Apple 公证。
   如果系统提示开发者无法验证，请先确认下载来自你信任的提供者。
   确认来源和完整性后，由你在“系统设置 → 隐私与安全性”中
   对本应用选择“仍要打开”，并按系统提示确认。受管理的 Mac 可能不允许此操作。
   如果提示应用会损害电脑、已损坏或内容被修改，请停止安装并联系提供者。
   不需要安装或信任提供者的根证书，也不需要关闭系统安全保护。
4. 在 Wordglide 设置中准备中英语言包，授权辅助功能。
   OCR 为可选功能，需要额外的屏幕录制授权。

使用
选中文字可翻译；在可编辑输入框按 Control + Return 可直接替换。
先完成输入法选词。译文可复制，替换后可在原编辑器尝试 Command + Z 撤销。

$update_instructions
更新时继续使用同一提供者的签名身份。系统仍可能要求重新确认权限。

应用自身不上传原文、译文或截图。语言包下载使用 Apple 服务；不持久保存翻译历史。
启用检查更新后，会连接 GitHub 发布服务器；不发送翻译内容或系统分析报告。
许可证位于应用包 Contents/Resources 内。

Apple 官方打开说明：https://support.apple.com/zh-cn/102445
EOF

/usr/bin/codesign --verify --deep --strict "$payload/Wordglide.app"
dmg_name="Wordglide-$version-macOS-$architecture.dmg"
dmg_path="$staging_dir/$dmg_name"
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO \
  -volname "Wordglide $version" -srcfolder "$payload" "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"
(
  cd "$staging_dir"
  /usr/bin/shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)
/bin/mv -f "$dmg_path" "$project_dir/build/$dmg_name"
/bin/mv -f "$staging_dir/$dmg_name.sha256" "$project_dir/build/$dmg_name.sha256"
print -- "Created: $project_dir/build/$dmg_name"
print -- "SHA-256: $project_dir/build/$dmg_name.sha256"
print -- "本地签名测试包，未进行 Developer ID 签名或 Apple 公证。"
