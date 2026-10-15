#!/bin/zsh
# Shared helpers for the pinned Sparkle release. No private key is read here.

sparkle_project_dir="${${(%):-%x}:A:h:h}"
sparkle_key_account="app.wordglide.mac"
sparkle_config_file="$sparkle_project_dir/.local/updates.plist"

sparkle_fail() {
  print -u2 -- "错误：$1"
  exit 1
}

sparkle_tool_path() {
  local tool_name="$1"
  case "$tool_name" in
    generate_keys|sign_update|generate_appcast|BinaryDelta) ;;
    *) sparkle_fail "不支持的 Sparkle 工具：$tool_name" ;;
  esac
  local artifact_dir="$sparkle_project_dir/.build/artifacts/sparkle/Sparkle"
  local framework_info="$artifact_dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Resources/Info.plist"
  local tool_path="$artifact_dir/bin/$tool_name"
  [[ -x "$tool_path" && -f "$framework_info" ]] ||
    sparkle_fail "尚未下载 Sparkle 工具。请先运行 swift package resolve（使用项目要求的完整 Xcode）。"
  local sparkle_version
  sparkle_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$framework_info")" ||
    sparkle_fail "无法读取 Sparkle 版本。"
  [[ "$sparkle_version" == 2.10.0 ]] ||
    sparkle_fail "Sparkle 工具版本应为 2.10.0，当前为 $sparkle_version。请按 Package.resolved 恢复依赖。"
  print -r -- "$tool_path"
}

sparkle_valid_repository() {
  # GitHub owner: 1-39 letters/digits or internal hyphens. Repository: 1-100
  # letters/digits/dots/underscores/hyphens, excluding dot path components.
  local repository="$1"
  [[ "$repository" == */* && "$repository" != */*/* ]] || return 1
  local owner="${repository%%/*}"
  local repo_name="${repository#*/}"
  [[ ${#owner} -le 39 && "$owner" =~ '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' &&
     "$owner" != *--* && ${#repo_name} -le 100 &&
     "$repo_name" =~ '^[A-Za-z0-9._-]+$' && "$repo_name" != . && "$repo_name" != .. ]]
}

sparkle_valid_public_key() {
  local public_key="$1"
  [[ "$public_key" =~ '^[A-Za-z0-9+/]{43}=$' ]] || return 1
  # Re-encoding rejects non-canonical base64 without exposing or writing secrets.
  local round_trip
  round_trip="$(print -rn -- "$public_key" | /usr/bin/base64 -D | /usr/bin/base64 | /usr/bin/tr -d '\n')" || return 1
  [[ "$round_trip" == "$public_key" ]]
}

sparkle_read_config() {
  [[ -f "$sparkle_config_file" ]] ||
    sparkle_fail "尚未配置更新。先运行 ./scripts/setup-updates.sh；有仓库后追加 --repository OWNER/REPO。"
  /usr/bin/plutil -lint "$sparkle_config_file" >/dev/null ||
    sparkle_fail "更新配置不是有效 plist：$sparkle_config_file"
  sparkle_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "更新配置缺少 SUPublicEDKey。"
  sparkle_valid_public_key "$sparkle_public_key" || sparkle_fail "SUPublicEDKey 格式不正确。"
  sparkle_repository="$(/usr/bin/plutil -extract repository raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "尚未设置 GitHub 仓库。创建仓库后运行 ./scripts/setup-updates.sh --repository OWNER/REPO。"
  sparkle_valid_repository "$sparkle_repository" || sparkle_fail "repository 必须是有效的 OWNER/REPO。"
  sparkle_feed_url="$(/usr/bin/plutil -extract SUFeedURL raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "更新配置缺少 SUFeedURL。"
  [[ "$sparkle_feed_url" == "https://github.com/$sparkle_repository/releases/latest/download/appcast.xml" ]] ||
    sparkle_fail "SUFeedURL 与 repository 不一致，请用 setup-updates.sh --repository OWNER/REPO 修复。"
}

if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  set -euo pipefail
  if [[ $# -eq 1 && "$1" == --help ]]; then
    print -- "Usage: ./scripts/sparkle-tools.sh TOOL"
    print -- "Print the path to a tool from the pinned Sparkle 2.10.0 artifact."
  elif [[ $# -eq 1 ]]; then
    sparkle_tool_path "$1"
  else
    print -u2 -- "Usage: ./scripts/sparkle-tools.sh TOOL"
    exit 2
  fi
fi
