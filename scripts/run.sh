#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
if [[ ! -d "$project_dir/build/Wordglide.app" ]]; then
  "$project_dir/scripts/build-app.sh"
fi
open "$project_dir/build/Wordglide.app"
