#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
signing_identity="${WORDGLIDE_SIGNING_IDENTITY:-}"
signing_keychain="${WORDGLIDE_SIGNING_KEYCHAIN:-}"
bundle_identifier="app.wordglide.signing-check"

fail() {
  print -u2 -- "FAIL signing stability: $1"
  exit 1
}

# This check creates only disposable Mach-O samples. It never launches them,
# changes a keychain, or asks for Accessibility / Screen Recording permission.
[[ "${WORDGLIDE_ADHOC_SIGNING:-0}" == 0 ]] ||
  fail "此检查需要证书身份，不接受 WORDGLIDE_ADHOC_SIGNING。"
identity_file="$project_dir/.local/signing-identity"
if [[ -z "$signing_identity" && -f "$identity_file" ]]; then
  if ! signing_identity="$(/bin/cat "$identity_file")"; then
    fail "无法读取 .local/signing-identity。"
  fi
fi
[[ -n "$signing_identity" ]] ||
  fail "请先运行 ./scripts/setup-local-signing.sh，或设置 WORDGLIDE_SIGNING_IDENTITY。"
[[ ${#signing_identity} -eq 40 && "$signing_identity" != *[^0-9A-Fa-f]* ]] ||
  fail "签名身份必须为代码签名证书的 40 位 SHA-1。"
signing_identity="${(U)signing_identity}"
identity_args=(find-identity -v -p codesigning)
if [[ -n "$signing_keychain" ]]; then identity_args+=("$signing_keychain"); fi
if ! available_identities="$(/usr/bin/security "${identity_args[@]}" 2>&1)"; then
  fail "无法检查代码签名身份；请确认钥匙串路径正确且已解锁。"
fi
if ! print -r -- "$available_identities" | /usr/bin/awk -v wanted="$signing_identity" \
    'toupper($2) == wanted { found = 1 } END { exit !found }'; then
  fail "没有找到有效的代码签名身份 $signing_identity。"
fi

temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wordglide-signing-check.XXXXXXXX")"
cleanup() {
  local result=$?
  /bin/rm -rf "$temporary_dir"
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print -r -- 'int main(void) { return 21; }' > "$temporary_dir/first.c"
print -r -- 'int main(void) { return 22; }' > "$temporary_dir/second.c"
/usr/bin/xcrun clang "$temporary_dir/first.c" -o "$temporary_dir/first"
/usr/bin/xcrun clang "$temporary_dir/second.c" -o "$temporary_dir/second"

# Match build-app.sh: stable identifier plus this exact certificate, with no
# build-specific cdhash and no identifier-only identity claim.
signing_args=(--force --sign "$signing_identity" --identifier "$bundle_identifier" --timestamp=none
  --requirements "=designated => identifier \"$bundle_identifier\" and certificate leaf = H\"$signing_identity\"")
if [[ -n "$signing_keychain" ]]; then signing_args+=(--keychain "$signing_keychain"); fi
for sample in first second; do
  /usr/bin/codesign "${signing_args[@]}" "$temporary_dir/$sample"
  /usr/bin/codesign --verify --strict --verbose=2 "$temporary_dir/$sample"
done

first_signature="$(/usr/bin/codesign -d --verbose=4 "$temporary_dir/first" 2>&1)"
second_signature="$(/usr/bin/codesign -d --verbose=4 "$temporary_dir/second" 2>&1)"
first_hash="$(print -r -- "$first_signature" | /usr/bin/awk -F= '/^CDHash=/ { print $2 }')"
second_hash="$(print -r -- "$second_signature" | /usr/bin/awk -F= '/^CDHash=/ { print $2 }')"
[[ -n "$first_hash" && -n "$second_hash" && "$first_hash" != "$second_hash" ]] ||
  fail "两个不同内容的样例没有产生不同的 CDHash。"

first_requirements="$(/usr/bin/codesign -d -r- "$temporary_dir/first" 2>&1)"
second_requirements="$(/usr/bin/codesign -d -r- "$temporary_dir/second" 2>&1)"
first_dr="$(print -r -- "$first_requirements" | /usr/bin/awk '/^(# )?designated => / { sub(/^# /, ""); print }')"
second_dr="$(print -r -- "$second_requirements" | /usr/bin/awk '/^(# )?designated => / { sub(/^# /, ""); print }')"
[[ -n "$first_dr" && "$first_dr" == "$second_dr" ]] ||
  fail "两个样例导出的 designated requirement 不一致。"
if [[ "$first_dr" == *"cdhash "* || "$first_dr" != *'identifier "app.wordglide.signing-check"'* ||
      "$first_dr" != *"certificate leaf"* || "${(U)first_dr}" != *"$signing_identity"* ]]; then
  fail "导出的 DR 未绑定预期的应用标识与证书指纹。"
fi

# Test each signed sample against the OTHER sample's exported requirement.
# --test-requirement takes a single expression, without the set's designated tag.
first_expression="${first_dr#designated => }"
second_expression="${second_dr#designated => }"
/usr/bin/codesign --verify --strict --test-requirement "=$first_expression" "$temporary_dir/second"
/usr/bin/codesign --verify --strict --test-requirement "=$second_expression" "$temporary_dir/first"

print -r -- "PASS signing stability: different code hashes, identical certificate-bound DR, mutual requirement checks, and strict signature verification."
print -r -- "Identity SHA1: $signing_identity"
print -r -- "Sample CDHash: $first_hash / $second_hash"
print -r -- "$first_dr"
print -r -- "此检查只证明签名身份跨内容变化保持稳定；未运行样例，也未验证 TCC 隐私权限保留。"
