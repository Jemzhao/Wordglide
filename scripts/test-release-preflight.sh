#!/bin/zsh
set -euo pipefail
source "${0:A:h}/sparkle-tools.sh"

fixture_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wordglide-release-test.XXXXXXXX")"
trap '/bin/rm -rf "$fixture_dir"' EXIT
sparkle_repository="Example/Wordglide"
sparkle_select_channel v2
sparkle_select_account "$sparkle_repository"
sparkle_feed_url="$(sparkle_feed_url_for_repository "$sparkle_repository")"

/bin/cat > "$fixture_dir/feed.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>9</sparkle:version></item>
<item><sparkle:version>10</sparkle:version><enclosure sparkle:version="12"/></item>
</channel></rss>
XML

feed_http_code=200
verify_result=0
release_list='[]'
next_release_list='[]'
api_pattern="https://api.github.com/repos/$sparkle_repository/releases?per_page=100&page="

sparkle_fetch_public_release_file() {
  case "$1" in
    "$sparkle_feed_url")
      /bin/cp "$fixture_dir/feed.xml" "$2"
      print -r -- "$feed_http_code"
      ;;
    "${api_pattern}1")
      print -r -- "$release_list" > "$2"
      print -- 200
      ;;
    "${api_pattern}2")
      print -r -- "$next_release_list" > "$2"
      print -- 200
      ;;
    *) return 1 ;;
  esac
}

verify_fixture() {
  [[ "$1" == --account && "$2" == "$sparkle_key_account" && "$3" == --verify &&
     "$4" == "$fixture_dir/published-$sparkle_feed_name" ]] || return 1
  return "$verify_result"
}

check_build() {
  sparkle_check_published_build "$1" "$fixture_dir" verify_fixture "${2:-0}"
}

expect_failure() {
  local expected="$1" result
  shift
  if result="$( ( "$@" ) 2>&1 )" || [[ "$result" != *"$expected"* ]]; then
    print -u2 -- "预期发布检查拒绝：$expected"
    print -u2 -r -- "$result"
    exit 1
  fi
}

check_build 13
check_build 12.1
expect_failure '必须高于已发布的构建号 12' check_build 11
expect_failure '必须高于已发布的构建号 12' check_build 12
expect_failure '必须高于已发布的构建号 12' check_build 12.0.0
expect_failure '已有更新清单' check_build 13 1

verify_result=1
expect_failure '未通过当前更新密钥验签' check_build 13
verify_result=0
feed_http_code=503
expect_failure 'HTTP 503' check_build 13 1
feed_http_code=404
expect_failure '无法核对已发布构建号' check_build 13
check_build 1 1

release_list='[{"assets":[{"name":"appcast.xml"},{"name":"Wordglide.dmg"}]}]'
check_build 1 1
release_list='[{"assets":[{"name":"appcast-v2.xml"}]}]'
expect_failure '该通道已经发布' check_build 1 1
release_list="$(/usr/bin/jq -nc '[range(100) | {assets: []}]')"
next_release_list='[{"assets":[{"name":"appcast-v2.xml"}]}]'
expect_failure '该通道已经发布' check_build 1 1
release_list='{"assets":[]}'
expect_failure '无法读取公开发布记录' check_build 1 1

sparkle_select_channel v2
expect_failure '正式发布使用 v3 通道' sparkle_select_account Jemzhao/Wordglide
sparkle_select_channel v3
sparkle_repository=Jemzhao/Wordglide
sparkle_select_account "$sparkle_repository"
[[ "$sparkle_key_account" == app.wordglide.mac.v3 ]]
sparkle_feed_url="$(sparkle_feed_url_for_repository "$sparkle_repository")"
[[ "$sparkle_feed_url" == */appcast-v3.xml ]]
sparkle_check_repository_key "$sparkle_repository" "$sparkle_upstream_public_key"
expect_failure '与 Wordglide v3 发布通道不一致' sparkle_check_repository_key "$sparkle_repository" "$sparkle_upstream_v2_public_key"
expect_failure '不能用于其他仓库' sparkle_check_repository_key Example/Wordglide "$sparkle_upstream_v2_public_key"
expect_failure '不能用于其他仓库' sparkle_check_repository_key Example/Wordglide "$sparkle_upstream_public_key"
api_pattern="https://api.github.com/repos/$sparkle_repository/releases?per_page=100&page="
release_list='[{"assets":[{"name":"appcast.xml"},{"name":"appcast-v2.xml"}]}]'
check_build 15 1
release_list='[{"assets":[{"name":"appcast-v3.xml"}]}]'
expect_failure '该通道已经发布' check_build 15 1

print -- 'PASS: published Sparkle build number and first release preflight'
