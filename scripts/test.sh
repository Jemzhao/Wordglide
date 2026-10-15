#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && "$(/usr/bin/xcode-select -p)" == /Library/Developer/CommandLineTools &&
      -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift test
swift run Wordglide --self-test
