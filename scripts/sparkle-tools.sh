#!/bin/zsh
# Shared helpers for the pinned Sparkle release. No private key is read here.

sparkle_project_dir="${${(%):-%x}:A:h:h}"
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
  local artifact_dir="${2:-$sparkle_project_dir}/.build/artifacts/sparkle/Sparkle"
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

sparkle_select_channel() {
  case "$1" in
    legacy)
      sparkle_feed_name="appcast.xml"
      ;;
    v2)
      sparkle_feed_name="appcast-v2.xml"
      ;;
    *) sparkle_fail "未知的更新通道：$1。" ;;
  esac
  sparkle_channel="$1"
}

sparkle_read_config_channel() {
  local channel
  channel="$(/usr/bin/plutil -extract channel raw "$sparkle_config_file" 2>/dev/null)" || channel=legacy
  sparkle_select_channel "$channel"
}

sparkle_feed_url_for_repository() {
  print -r -- "https://github.com/$1/releases/latest/download/$sparkle_feed_name"
}

sparkle_valid_build_number() {
  [[ "$1" =~ '^[0-9]{1,18}([.][0-9]{1,18}){0,2}$' ]]
}

sparkle_build_is_newer() {
  local candidate="$1" published="$2" part left right
  local -a candidate_parts published_parts
  candidate_parts=("${(@s:.:)candidate}" 0 0)
  published_parts=("${(@s:.:)published}" 0 0)
  # Sparkle compares numeric components and pads missing trailing parts with zero.
  for part in 1 2 3; do
    left="${candidate_parts[part]}"
    right="${published_parts[part]}"
    if (( 10#$left != 10#$right )); then
      (( 10#$left > 10#$right ))
      return $?
    fi
  done
  return 1
}

sparkle_require_newer_than_feed() {
  local candidate="$1" feed="$2" count index item version_path published
  local version_predicate='local-name()="version" and namespace-uri()="http://www.andymatuschak.org/xml-namespaces/sparkle"'
  count="$(/usr/bin/xmllint --nonet --xpath 'count(/rss/channel/item)' "$feed")" ||
    sparkle_fail "无法读取已发布的更新清单。"
  [[ "$count" =~ '^[1-9][0-9]*$' ]] || sparkle_fail "已发布的更新清单没有更新条目。"
  for (( index = 1; index <= count; index++ )); do
    item="/rss/channel/item[$index]"
    # An older enclosure version attribute takes precedence in Sparkle.
    version_path="$item/enclosure/@*[$version_predicate]"
    published="$(/usr/bin/xmllint --nonet --xpath \
      "normalize-space($version_path | $item/*[$version_predicate and not($version_path)])" "$feed")" ||
      sparkle_fail "无法读取已发布条目的构建号。"
    sparkle_valid_build_number "$published" || sparkle_fail "已发布条目的 CFBundleVersion 格式无效。"
    sparkle_build_is_newer "$candidate" "$published" ||
      sparkle_fail "CFBundleVersion 必须高于已发布的构建号 $published，当前为 $candidate。"
  done
}

sparkle_fetch_public_release_file() {
  local url="$1" output="$2"
  shift 2
  /usr/bin/curl --disable --silent --show-error --location --max-time 30 \
    --proto '=https' --proto-redir '=https' --write-out '%{http_code}' --output "$output" "$@" "$url"
}

sparkle_require_unpublished_feed() {
  local metadata="$1" per_page=100 page=1 summary count http_code
  while true; do
    http_code="$(sparkle_fetch_public_release_file \
      "https://api.github.com/repos/$sparkle_repository/releases?per_page=$per_page&page=$page" \
      "$metadata" --header 'Accept: application/vnd.github+json')" ||
      sparkle_fail "无法确认公开发布记录，请核对仓库与 GitHub 连接。"
    [[ "$http_code" == 200 ]] || sparkle_fail "无法确认公开发布记录（HTTP $http_code）。"
    summary="$(/usr/bin/jq -r --arg feed "$sparkle_feed_name" '
      if type != "array" or any(.[]; (.assets | type) != "array" or any(.assets[]; (.name | type) != "string")) then
        error("invalid release list")
      else
        "\(length):\(any(.[]; any(.assets[]; .name == $feed)))"
      end
    ' "$metadata")" || sparkle_fail "无法读取公开发布记录。"
    count="${summary%:*}"
    [[ "$count" =~ '^(0|[1-9][0-9]{0,2})$' && "$count" -le "$per_page" ]] ||
      sparkle_fail "公开发布记录格式无效。"
    [[ "${summary##*:}" == false ]] || sparkle_fail "该通道已经发布。请先恢复 Latest 上的 $sparkle_feed_name。"
    if (( count < per_page )); then return; fi
    (( page += 1 ))
  done
}

sparkle_check_published_build() {
  local candidate="$1" staging_dir="$2" sign_tool="$3" first_release="$4"
  local feed="$staging_dir/published-$sparkle_feed_name" http_code
  http_code="$(sparkle_fetch_public_release_file "$sparkle_feed_url" "$feed")" ||
    sparkle_fail "无法下载已发布的 $sparkle_feed_name。"
  case "$http_code" in
    200)
      [[ "$first_release" == 0 ]] || sparkle_fail "该通道已有更新清单，请去掉 --first-release。"
      "$sign_tool" --account "$sparkle_key_account" --verify "$feed" ||
        sparkle_fail "已发布的 $sparkle_feed_name 未通过当前更新密钥验签。"
      sparkle_require_newer_than_feed "$candidate" "$feed"
      ;;
    404)
      [[ "$first_release" == 1 ]] || sparkle_fail "Latest 缺少 $sparkle_feed_name，无法核对已发布构建号。"
      sparkle_require_unpublished_feed "$staging_dir/published-releases.json"
      ;;
    *) sparkle_fail "无法下载已发布的 $sparkle_feed_name（HTTP $http_code）。" ;;
  esac
}

sparkle_is_upstream() {
  local repository="$1"
  [[ "${(L)repository}" == jemzhao/wordglide ]]
}

# Verification values taken from the public v0.3.0 and v0.3.3 DMGs.
sparkle_upstream_legacy_public_key="1kXmDIPW8G9D4yJ9ML6XYcRYE6CKJvkw8zNBd0AX0bY="
sparkle_upstream_public_key="7th1dPoOcRPkynPeTGkvfR/g7ETQddretZVj3ykHIGM="
sparkle_upstream_signing_identity="9741B1380FB6648CF5AA25E9D6B9DCB18A461F00"

sparkle_require_upstream_channel() {
  [[ "$sparkle_channel" == v2 ]] ||
    sparkle_fail "Wordglide 正式发布使用 v2 通道。请运行 ./scripts/setup-updates.sh --repository Jemzhao/Wordglide --channel v2。"
}

sparkle_select_account() {
  local repo="$1"
  if sparkle_is_upstream "$repo"; then
    sparkle_require_upstream_channel
    sparkle_key_account="app.wordglide.mac.v2"
  elif [[ -n "$repo" ]]; then
    # Use a filesystem-independent account name and GitHub's case-insensitive
    # repository identity. Multiple checkouts of the same fork can share it.
    local digest
    digest="$(print -rn -- "${(L)repo}" | /usr/bin/shasum -a 256)"
    sparkle_key_account="app.wordglide.mac.repo.$sparkle_channel.${digest%% *}"
  else
    sparkle_key_account="app.wordglide.mac.local.$sparkle_channel"
  fi
}

sparkle_check_repository_key() {
  local repo="$1" key="$2"
  if sparkle_is_upstream "$repo"; then
    [[ "$key" == "$sparkle_upstream_public_key" ]] ||
      sparkle_fail "更新公钥与 Wordglide v2 发布通道不一致。请恢复原 v2 更新签名密钥。"
  else
    [[ "$key" != "$sparkle_upstream_public_key" && "$key" != "$sparkle_upstream_legacy_public_key" ]] ||
      sparkle_fail "正式更新密钥不能用于其他仓库。已保留现有配置。请为该仓库配置独立密钥，再手动迁移已安装的客户端。"
  fi
}

sparkle_read_config() {
  [[ -f "$sparkle_config_file" ]] ||
    sparkle_fail "尚未配置更新。先运行 ./scripts/setup-updates.sh；有仓库后追加 --repository OWNER/REPO。"
  /usr/bin/plutil -lint "$sparkle_config_file" >/dev/null ||
    sparkle_fail "更新配置不是有效 plist：$sparkle_config_file"
  sparkle_read_config_channel
  sparkle_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "更新配置缺少 SUPublicEDKey。"
  sparkle_valid_public_key "$sparkle_public_key" || sparkle_fail "SUPublicEDKey 格式不正确。"
  sparkle_repository="$(/usr/bin/plutil -extract repository raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "尚未设置 GitHub 仓库。创建仓库后运行 ./scripts/setup-updates.sh --repository OWNER/REPO。"
  sparkle_valid_repository "$sparkle_repository" || sparkle_fail "repository 必须是有效的 OWNER/REPO。"
  sparkle_select_account "$sparkle_repository"
  sparkle_check_repository_key "$sparkle_repository" "$sparkle_public_key"
  sparkle_feed_url="$(/usr/bin/plutil -extract SUFeedURL raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "更新配置缺少 SUFeedURL。"
  [[ "$sparkle_feed_url" == "$(sparkle_feed_url_for_repository "$sparkle_repository")" ]] ||
    sparkle_fail "SUFeedURL 与仓库或通道不一致，请用 setup-updates.sh --repository OWNER/REPO 修复。"
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
