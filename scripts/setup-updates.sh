#!/bin/zsh
set -euo pipefail
umask 077
project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-tools.sh"

repository=""
requested_channel=""
if [[ $# -eq 1 && "$1" == --help ]]; then
  print -- "Usage: ./scripts/setup-updates.sh [--repository OWNER/REPO] [--channel v2]"
  print -- "Create/reuse Wordglide's Sparkle key in the login keychain and save only public configuration."
  print -- "Select v2 for manual migration to appcast-v2.xml. Omit it to reuse the saved channel."
  print -- "Does not create a GitHub repository, publish files, or export a private key."
  exit 0
fi
while [[ $# -gt 0 ]]; do
  if [[ $# -lt 2 ]]; then
    print -u2 -- "Usage: ./scripts/setup-updates.sh [--repository OWNER/REPO] [--channel v2]"
    exit 2
  fi
  case "$1" in
    --repository)
      [[ -z "$repository" ]] || sparkle_fail "请只指定一次 --repository。"
      repository="$2"
      sparkle_valid_repository "$repository" || sparkle_fail "仓库必须是 OWNER/REPO，不接受 URL、空格或路径。"
      ;;
    --channel)
      [[ -z "$requested_channel" && "$2" == v2 ]] || sparkle_fail "请只指定一次 --channel v2。"
      requested_channel="$2"
      ;;
    *)
      print -u2 -- "Usage: ./scripts/setup-updates.sh [--repository OWNER/REPO] [--channel v2]"
      exit 2
      ;;
  esac
  shift 2
done

existing_channel=legacy
existing_repository=""
if [[ -f "$sparkle_config_file" ]]; then
  /usr/bin/plutil -lint "$sparkle_config_file" >/dev/null || sparkle_fail "原更新配置损坏，已保留。"
  sparkle_read_config_channel
  existing_channel="$sparkle_channel"
  existing_repository="$(/usr/bin/plutil -extract repository raw "$sparkle_config_file" 2>/dev/null)" ||
    existing_repository=""
  [[ -z "$existing_repository" ]] || sparkle_valid_repository "$existing_repository" ||
    sparkle_fail "原仓库配置不正确，已保留。"
  repository="${repository:-$existing_repository}"
fi
sparkle_select_channel "${requested_channel:-$existing_channel}"
sparkle_select_account "$repository"
generate_keys="$(sparkle_tool_path generate_keys)"
existing_public_key=""
if sparkle_is_upstream "$repository"; then
  existing_public_key="$sparkle_upstream_public_key"
elif [[ -n "$repository" && "${(L)repository}" == "${(L)existing_repository}" &&
        "$sparkle_channel" == "$existing_channel" ]]; then
  existing_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "原更新配置缺少公钥，已保留。"
  sparkle_valid_public_key "$existing_public_key" || sparkle_fail "原更新配置公钥不正确，已保留。"
fi
if [[ -n "$existing_public_key" ]]; then
  # Never rotate the key for an existing feed implicitly.
  sparkle_check_repository_key "$repository" "$existing_public_key"
  public_key="$("$generate_keys" --account "$sparkle_key_account" -p)" ||
    sparkle_fail "找不到账户 $sparkle_key_account 的原更新密钥，或钥匙串尚未解锁。请恢复原密钥，现有配置已保留。"
else
  # A different repository or channel uses its own account.
  "$generate_keys" --account "$sparkle_key_account"
  public_key="$("$generate_keys" --account "$sparkle_key_account" -p)" ||
    sparkle_fail "无法从钥匙串读取更新公钥。"
fi
sparkle_valid_public_key "$public_key" || sparkle_fail "Sparkle 返回了无效公钥，配置未写入。"
sparkle_check_repository_key "$repository" "$public_key"
[[ -z "$existing_public_key" || "$existing_public_key" == "$public_key" ]] ||
  sparkle_fail "钥匙串密钥与已配置公钥不一致，配置未改动。请恢复正确密钥。"

/bin/mkdir -p "$project_dir/.local"
pending_config="$(/usr/bin/mktemp "$project_dir/.local/.updates.XXXXXXXX")"
trap '/bin/rm -f "$pending_config"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/plutil -create xml1 "$pending_config"
/usr/bin/plutil -replace SUPublicEDKey -string "$public_key" "$pending_config"
/usr/bin/plutil -replace channel -string "$sparkle_channel" "$pending_config"
if [[ -n "$repository" ]]; then
  /usr/bin/plutil -replace repository -string "$repository" "$pending_config"
  /usr/bin/plutil -replace SUFeedURL -string "$(sparkle_feed_url_for_repository "$repository")" "$pending_config"
fi
/usr/bin/plutil -lint "$pending_config" >/dev/null
/bin/mv -f "$pending_config" "$sparkle_config_file"
print -- "更新公钥已保存到 .local/updates.plist；私钥仅留在登录钥匙串（account: $sparkle_key_account）。"
if /usr/bin/plutil -extract SUFeedURL raw "$sparkle_config_file" >/dev/null 2>&1; then
  print -- "Feed: $(/usr/bin/plutil -extract SUFeedURL raw "$sparkle_config_file")"
  print -- "下一步：./scripts/prepare-update.sh"
else
  print -- "尚未设置更新地址，当前构建不会联网检查更新。"
  print -- "创建公开 GitHub 仓库后运行：./scripts/setup-updates.sh --repository OWNER/REPO"
fi
