#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
# SwiftUI in the macOS SDK needs the macro plugins shipped with full Xcode.
# Respect an explicit selection; only repair the Command Line Tools fallback
# for this process, without changing the system-wide xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" && "$(/usr/bin/xcode-select -p)" == /Library/Developer/CommandLineTools &&
      -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${CONFIGURATION:-release}"
app_dir="$project_dir/build/Wordglide.app"
bundle_identifier="app.wordglide.mac"
signing_identity="${WORDGLIDE_SIGNING_IDENTITY:-}"
signing_keychain="${WORDGLIDE_SIGNING_KEYCHAIN:-}"
adhoc_signing="${WORDGLIDE_ADHOC_SIGNING:-0}"
require_updates="${WORDGLIDE_REQUIRE_UPDATES:-0}"

fail() {
  print -u2 -- "错误：$1"
  exit 1
}

[[ "$adhoc_signing" == 0 || "$adhoc_signing" == 1 ]] ||
  fail "WORDGLIDE_ADHOC_SIGNING 只能设为 0 或 1。"
[[ "$require_updates" == 0 || "$require_updates" == 1 ]] ||
  fail "WORDGLIDE_REQUIRE_UPDATES 只能设为 0 或 1。"

# Validate public release metadata before compiling or replacing a working app.
# A key-only configuration is useful while no GitHub repository exists.
source "$project_dir/scripts/sparkle-tools.sh"
update_public_key=""
update_feed_url=""
if [[ -f "$sparkle_config_file" ]]; then
  /usr/bin/plutil -lint "$sparkle_config_file" >/dev/null || fail "更新配置损坏，原应用未改动。"
  update_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$sparkle_config_file" 2>/dev/null)" ||
    fail "更新配置缺少公钥，原应用未改动。"
  sparkle_valid_public_key "$update_public_key" || fail "更新公钥无效，原应用未改动。"
  update_feed_url="$(/usr/bin/plutil -extract SUFeedURL raw "$sparkle_config_file" 2>/dev/null)" || update_feed_url=""
  update_repository="$(/usr/bin/plutil -extract repository raw "$sparkle_config_file" 2>/dev/null)" || update_repository=""
  if [[ -n "$update_feed_url" || -n "$update_repository" ]]; then
    sparkle_read_config
    update_feed_url="$sparkle_feed_url"
  fi
fi
if [[ "$require_updates" == 1 && ( -z "$update_public_key" || -z "$update_feed_url" ) ]]; then
  fail "发布更新需要完整的仓库、HTTPS 更新地址与公钥。请运行 ./scripts/setup-updates.sh --repository OWNER/REPO。原应用未改动。"
fi

# Check identity before compiling, and never silently fall back to an ad-hoc
# signature: its changing cdhash would invalidate privacy grants on rebuild.
if [[ "$adhoc_signing" == 1 ]]; then
  print -u2 -- "提示：本次显式使用临时签名，重新构建后可能需要重新授权。"
  signing_identity="-"
else
  identity_file="$project_dir/.local/signing-identity"
  if [[ -z "$signing_identity" && -f "$identity_file" ]]; then
    if ! signing_identity="$(/bin/cat "$identity_file")"; then
      fail "无法读取 $identity_file。请重新运行 ./scripts/setup-local-signing.sh。"
    fi
  fi
  [[ -n "$signing_identity" ]] || fail "尚未配置稳定签名。请先运行 ./scripts/setup-local-signing.sh；也可将 WORDGLIDE_SIGNING_IDENTITY 设为代码签名证书的 40 位 SHA-1。仅临时检查可显式设置 WORDGLIDE_ADHOC_SIGNING=1。"
  [[ ${#signing_identity} -eq 40 && "$signing_identity" != *[^0-9A-Fa-f]* ]] ||
    fail "WORDGLIDE_SIGNING_IDENTITY（或 .local/signing-identity）必须是代码签名证书的 40 位 SHA-1，不能是证书名称或 '-'。"
  signing_identity="${(U)signing_identity}"
  identity_args=(find-identity -v -p codesigning)
  if [[ -n "$signing_keychain" ]]; then identity_args+=("$signing_keychain"); fi
  if ! available_identities="$(/usr/bin/security "${identity_args[@]}" 2>&1)"; then
    fail "无法检查代码签名身份。请确认登录钥匙串已解锁，且 WORDGLIDE_SIGNING_KEYCHAIN 指向正确的钥匙串。"
  fi
  if ! print -r -- "$available_identities" | /usr/bin/awk -v wanted="$signing_identity" \
      'toupper($2) == wanted { found = 1 } END { exit !found }'; then
    fail "找不到有效的代码签名身份 $signing_identity。请运行 ./scripts/setup-local-signing.sh，或修复证书、私钥配对、有效期与代码签名信任设置。原应用未改动。"
  fi
fi

swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
sparkle_framework="$binary_dir/Sparkle.framework"
[[ -d "$sparkle_framework" && -x "$sparkle_framework/Sparkle" ]] ||
  fail "SwiftPM 未生成完整的 Sparkle.framework，原应用未改动。"
mkdir -p "$project_dir/build"
staging_dir="$(/usr/bin/mktemp -d "$project_dir/build/.wordglide-build.XXXXXXXX")"
staged_app="$staging_dir/Wordglide.app"
previous_app="$staging_dir/PreviousWordglide.app"

cleanup() {
  local result=$?
  # A signal or failed final move must not remove the last working application.
  if [[ ( -e "$previous_app" || -L "$previous_app" ) && ! -e "$app_dir" && ! -L "$app_dir" ]]; then
    if ! /bin/mv "$previous_app" "$app_dir"; then
      print -u2 -- "无法自动恢复旧应用；已保留在 $previous_app。"
      return "$result"
    fi
  fi
  /bin/rm -rf "$staging_dir"
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Assemble and validate a separate bundle. A compile or signing failure must
# leave build/Wordglide.app intact and usable with its existing permissions.
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"
cp "$binary_dir/Wordglide" "$staged_app/Contents/MacOS/Wordglide"
/usr/bin/ditto "$sparkle_framework" "$staged_app/Contents/Frameworks/Sparkle.framework"
cp Info.plist "$staged_app/Contents/Info.plist"
# Only public metadata enters the sealed bundle; no Keychain item is exported.
/usr/bin/plutil -remove SUFeedURL "$staged_app/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/bin/plutil -remove SUPublicEDKey "$staged_app/Contents/Info.plist" >/dev/null 2>&1 || true
if [[ -n "$update_public_key" ]]; then
  /usr/bin/plutil -replace SUPublicEDKey -string "$update_public_key" "$staged_app/Contents/Info.plist"
fi
if [[ -n "$update_feed_url" ]]; then
  /usr/bin/plutil -replace SUFeedURL -string "$update_feed_url" "$staged_app/Contents/Info.plist"
fi
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist" >/dev/null
cp ThirdParty/HoverTranslate-LICENSE "$staged_app/Contents/Resources/HoverTranslate-LICENSE"
cp ThirdParty/Sparkle-LICENSE "$staged_app/Contents/Resources/Sparkle-LICENSE"
cp LICENSE "$staged_app/Contents/Resources/Wordglide-LICENSE"
if [[ -f Assets/AppIcon.icns ]]; then
  cp Assets/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
fi
xattr -cr "$staged_app"

# Sign inside-out using the same local identity as the host. Do not use --deep
# for signing: each helper keeps its own identifier and upstream entitlements.
# ditto above preserves the versioned framework's symlinks and executable bits.
embedded_sparkle="$staged_app/Contents/Frameworks/Sparkle.framework"
sparkle_version="$embedded_sparkle/Versions/Current"
nested_signing_args=(--force --sign "$signing_identity" --timestamp=none --options 0 --preserve-metadata=entitlements)
if [[ "$adhoc_signing" != 1 && -n "$signing_keychain" ]]; then
  nested_signing_args+=(--keychain "$signing_keychain")
fi
[[ -L "$embedded_sparkle/Versions/Current" && -L "$embedded_sparkle/Sparkle" &&
   -x "$sparkle_version/Autoupdate" && -d "$sparkle_version/Updater.app" ]] ||
  fail "Sparkle.framework 的链接或辅助程序不完整，原应用未改动。"
for helper in "$sparkle_version/Autoupdate" \
              "$sparkle_version"/XPCServices/*.xpc(N) \
              "$sparkle_version/Updater.app" \
              "$embedded_sparkle"; do
  /usr/bin/codesign "${nested_signing_args[@]}" "$helper"
  /usr/bin/codesign --verify --strict --verbose=2 "$helper"
done
signing_args=(--force --sign "$signing_identity" --identifier "$bundle_identifier" --timestamp=none)
if [[ "$adhoc_signing" != 1 ]]; then
  # Bind updates to the same certificate, never just to a self-declared bundle
  # identifier or to the build-specific CodeDirectory hash.
  signing_args+=(--requirements "=designated => identifier \"$bundle_identifier\" and certificate leaf = H\"$signing_identity\"")
  if [[ -n "$signing_keychain" ]]; then signing_args+=(--keychain "$signing_keychain"); fi
fi
/usr/bin/codesign "${signing_args[@]}" "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_app"
if [[ "$adhoc_signing" != 1 ]]; then
  requirement="$(/usr/bin/codesign -d -r- "$staged_app" 2>&1)"
  if [[ "$requirement" == *"cdhash "* || "$requirement" != *'identifier "app.wordglide.mac"'* ||
        "$requirement" != *"certificate leaf"* || "${(U)requirement}" != *"$signing_identity"* ]]; then
    fail "签名验证未得到绑定当前证书的稳定身份，已保留原应用。"
  fi
fi

if [[ -e "$app_dir" || -L "$app_dir" ]]; then /bin/mv "$app_dir" "$previous_app"; fi
/bin/mv "$staged_app" "$app_dir"
printf 'Built: %s\n' "$app_dir"
