#!/bin/zsh
set -euo pipefail
umask 022
project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-tools.sh"

release_notes=""
if [[ $# -eq 1 && "$1" == --help ]]; then
  print -- "Usage: ./scripts/prepare-update.sh [--release-notes PATH.md]"
  print -- "Build a signed DMG and appcast for the configured GitHub repository, without uploading."
  print -- "For the Wordglide v2 channel, also includes the original v0.3.0 appcast."
  print -- "Writes build/updates/VERSION/ and refuses to overwrite an existing version."
  exit 0
elif [[ $# -eq 2 && "$1" == --release-notes ]]; then
  release_notes="${2:A}"
  [[ -f "$release_notes" && "$release_notes" == *.md ]] || sparkle_fail "发布说明必须是现有的 .md 文件。"
elif [[ $# -ne 0 ]]; then
  print -u2 -- "Usage: ./scripts/prepare-update.sh [--release-notes PATH.md]"
  exit 2
fi

# All publication prerequisites are checked before packaging or touching an app.
[[ "${WORDGLIDE_ADHOC_SIGNING:-0}" == 0 ]] ||
  sparkle_fail "正式更新需要稳定的证书签名。请取消 WORDGLIDE_ADHOC_SIGNING。"
sparkle_read_config
generate_keys="$(sparkle_tool_path generate_keys)"
sign_update="$(sparkle_tool_path sign_update)"
generate_appcast="$(sparkle_tool_path generate_appcast)"
keychain_public_key="$("$generate_keys" --account "$sparkle_key_account" -p)" ||
  sparkle_fail "无法读取更新公钥；请解锁登录钥匙串并恢复原更新签名密钥。"
[[ "$keychain_public_key" == "$sparkle_public_key" ]] ||
  sparkle_fail "钥匙串密钥与更新配置不一致，未构建或生成更新。"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$project_dir/Info.plist")"
[[ "$version" =~ '^[0-9]+([.][0-9]+){1,3}$' ]] || sparkle_fail "发布版本必须是点分隔的数字。"
updates_dir="$project_dir/build/updates"
output_dir="$updates_dir/$version"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] ||
  sparkle_fail "已存在 $output_dir。已发布的版本不可覆盖；请增加版本号和 CFBundleVersion。"

/bin/mkdir -p "$updates_dir"
# Keep the same advisory lock file so a competing invocation cannot publish
# between our existence check and directory move. The OS releases the lock on exit.
exec 9>>"$updates_dir/.prepare.lock"
/usr/bin/lockf -s -t 0 9 || sparkle_fail "已有另一个更新准备任务正在运行。"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || sparkle_fail "输出目录在准备期间已出现，未覆盖。"
staging_dir="$(/usr/bin/mktemp -d "$updates_dir/.pending-$version.XXXXXXXX")"
trap '/bin/rm -rf "$staging_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
build_dir="$staging_dir/build"
release_dir="$staging_dir/release"
/bin/mkdir "$release_dir"

# The old clients still check appcast.xml at the Latest release URL. Only the
# upstream repository serves that channel. Pin the bytes whose Ed25519 signature
# was verified against the public key bundled in the published 0.3.0 app.
legacy_dir=""
if sparkle_is_upstream "$sparkle_repository"; then
  legacy_dir="$staging_dir/legacy"
  /bin/mkdir "$legacy_dir"
  /usr/bin/curl --disable --fail --silent --show-error --location --max-time 30 \
    --proto '=https' --proto-redir '=https' --output "$legacy_dir/appcast.xml" \
    'https://github.com/Jemzhao/Wordglide/releases/download/v0.3.0/appcast.xml' ||
    sparkle_fail "无法下载 v0.3.0 的原始更新清单。"
  (
    cd "$legacy_dir"
    print -- 'e13f9f72d2541dc7b3d2f2dda47a285297422bd0bc40e63728a40b9c993c7fc4  appcast.xml' > appcast.xml.sha256
    /usr/bin/shasum -a 256 -c appcast.xml.sha256
  ) || sparkle_fail "v0.3.0 的更新清单与原始签名文件不一致。"
fi

WORDGLIDE_REQUIRE_UPDATES=1 WORDGLIDE_OUTPUT_DIR="$build_dir" "$project_dir/scripts/package-dmg.sh"
app_info="$build_dir/Wordglide.app/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_info")" == "$version" &&
   "$(/usr/bin/plutil -extract SUPublicEDKey raw "$app_info")" == "$sparkle_public_key" &&
   "$(/usr/bin/plutil -extract SUFeedURL raw "$app_info")" == "$sparkle_feed_url" &&
   "$(/usr/bin/plutil -extract SURequireSignedFeed raw "$app_info")" == true &&
   "$(/usr/bin/plutil -extract SUSignedFeedFailureExpirationInterval raw "$app_info")" == 0 &&
   "$(/usr/bin/plutil -extract SUVerifyUpdateBeforeExtraction raw "$app_info")" == true ]] ||
  sparkle_fail "应用的版本、公钥、更新源或强制验签配置不一致，不生成更新清单。"
build_number="$(/usr/bin/plutil -extract CFBundleVersion raw "$app_info")"
minimum_system="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$app_info")"
archives=("$build_dir/Wordglide-$version-macOS-"*.dmg(N))
[[ ${#archives} -eq 1 ]] || sparkle_fail "未找到唯一的本版本 DMG。"
archive="${archives[1]}"
archive_name="${archive:t}"
download_prefix="https://github.com/$sparkle_repository/releases/download/v$version/"

/bin/mv "$archive" "$release_dir/$archive_name"
if [[ -n "$release_notes" ]]; then
  /bin/cp "$release_notes" "$release_dir/${archive_name:r}.md"
fi

# Sparkle reads the bundle version, minimum OS, architecture, key and feed name
# from this DMG. This release flow generates only the full update package.
"$generate_appcast" --account "$sparkle_key_account" \
  --download-url-prefix "$download_prefix" \
  --link "https://github.com/$sparkle_repository" \
  --maximum-deltas 0 --embed-release-notes "$release_dir"
feed="$release_dir/$sparkle_feed_name"
[[ -f "$feed" ]] || sparkle_fail "Sparkle 未生成 $sparkle_feed_name。"
# generate_appcast signs feeds required by the bundle; explicitly re-signing is
# safe and ensures all final bytes are authenticated before checksums are made.
"$sign_update" --account "$sparkle_key_account" "$feed"
"$sign_update" --account "$sparkle_key_account" --verify "$feed"
archive_signature="$("$sign_update" --account "$sparkle_key_account" -p "$release_dir/$archive_name")"
"$sign_update" --account "$sparkle_key_account" --verify "$release_dir/$archive_name" "$archive_signature"

# Validate the exact output, not a guessed filename or host application's info.
enclosure_url="$(/usr/bin/xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@url)' "$feed")"
feed_build="$(/usr/bin/xmllint --xpath 'string(/rss/channel/item[1]/*[local-name()="version"])' "$feed")"
feed_minimum="$(/usr/bin/xmllint --xpath 'string(/rss/channel/item[1]/*[local-name()="minimumSystemVersion"])' "$feed")"
feed_signature="$(/usr/bin/xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@*[local-name()="edSignature"])' "$feed")"
[[ "$enclosure_url" == "$download_prefix$archive_name" && "$feed_build" == "$build_number" &&
   "$feed_minimum" == "$minimum_system" && "$feed_signature" == "$archive_signature" ]] ||
  sparkle_fail "生成清单的下载地址、版本、系统要求或签名与真实安装包不一致。"
/bin/mv "$build_dir/$archive_name.sha256" "$release_dir/$archive_name.sha256"
(
  cd "$release_dir"
  /usr/bin/shasum -a 256 -c "$archive_name.sha256"
  /usr/bin/shasum -a 256 "$sparkle_feed_name" > "$sparkle_feed_name.sha256"
)
if [[ -n "$legacy_dir" ]]; then
  /bin/mv "$legacy_dir/appcast.xml" "$legacy_dir/appcast.xml.sha256" "$release_dir/"
fi
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || sparkle_fail "输出目录在准备期间已出现，未覆盖。"
/bin/mv "$release_dir" "$output_dir"
print -- "更新文件已准备：$output_dir"
print -- "发布标签必须为 v$version；将目录中的 DMG、更新清单及对应的 .sha256 文件上传到同一 GitHub Release。"
if [[ -n "$legacy_dir" ]]; then
  print -- "旧版使用原始 appcast.xml，新版使用 $sparkle_feed_name；发布时须同时上传。"
fi
print -- "请将该 Release 设为 Latest；尚未创建仓库、上传或发布。"
