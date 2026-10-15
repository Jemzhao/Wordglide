#!/bin/zsh
set -euo pipefail
umask 077
project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-tools.sh"

repository=""
if [[ $# -eq 1 && "$1" == --help ]]; then
  print -- "Usage: ./scripts/setup-updates.sh [--repository OWNER/REPO]"
  print -- "Create/reuse Wordglide's Sparkle key in the login keychain and save only public configuration."
  print -- "Does not create a GitHub repository, publish files, or export a private key."
  exit 0
elif [[ $# -eq 2 && "$1" == --repository ]]; then
  repository="$2"
  sparkle_valid_repository "$repository" || sparkle_fail "仓库必须是 OWNER/REPO，不接受 URL、空格或路径。"
elif [[ $# -ne 0 ]]; then
  print -u2 -- "Usage: ./scripts/setup-updates.sh [--repository OWNER/REPO]"
  exit 2
fi

generate_keys="$(sparkle_tool_path generate_keys)"
existing_public_key=""
if [[ -f "$sparkle_config_file" ]]; then
  /usr/bin/plutil -lint "$sparkle_config_file" >/dev/null || sparkle_fail "原更新配置损坏，已保留。"
  existing_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$sparkle_config_file" 2>/dev/null)" ||
    sparkle_fail "原更新配置缺少公钥，已保留。"
  sparkle_valid_public_key "$existing_public_key" || sparkle_fail "原更新配置公钥不正确，已保留。"
  # Once configured, never generate a replacement key if the original is missing.
  public_key="$("$generate_keys" --account "$sparkle_key_account" -p)" ||
    sparkle_fail "找不到原更新签名密钥或钥匙串尚未解锁。请恢复原密钥，不要重新生成。"
else
  # Sparkle itself reuses an existing key for this account and never overwrites it.
  "$generate_keys" --account "$sparkle_key_account"
  public_key="$("$generate_keys" --account "$sparkle_key_account" -p)" ||
    sparkle_fail "无法从钥匙串读取更新公钥。"
fi
sparkle_valid_public_key "$public_key" || sparkle_fail "Sparkle 返回了无效公钥，配置未写入。"
[[ -z "$existing_public_key" || "$existing_public_key" == "$public_key" ]] ||
  sparkle_fail "钥匙串密钥与已配置公钥不一致，配置未改动。请恢复正确密钥。"

/bin/mkdir -p "$project_dir/.local"
pending_config="$(/usr/bin/mktemp "$project_dir/.local/.updates.XXXXXXXX")"
trap '/bin/rm -f "$pending_config"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -f "$sparkle_config_file" ]]; then
  /bin/cp "$sparkle_config_file" "$pending_config"
else
  /usr/bin/plutil -create xml1 "$pending_config"
fi
/usr/bin/plutil -replace SUPublicEDKey -string "$public_key" "$pending_config"
if [[ -n "$repository" ]]; then
  /usr/bin/plutil -replace repository -string "$repository" "$pending_config"
  /usr/bin/plutil -replace SUFeedURL -string "https://github.com/$repository/releases/latest/download/appcast.xml" "$pending_config"
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
