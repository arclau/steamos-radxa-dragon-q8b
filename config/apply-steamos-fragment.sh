#!/bin/bash
# Apply config/steamos-sc8280xp.config onto build/kernel/.config via kernel scripts/config.
set -euo pipefail
# 仓库根 = 本脚本所在目录（config/）的上一级；不硬编码主机路径（CI/fork 可移植）。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
CFG="${CFG:-build/kernel/.config}"
SC="${SC:-upstream/radxa-kernel/scripts/config}"
n=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  key="${line%%=*}"; val="${line#*=}"
  name="${key#CONFIG_}"
  case "$val" in
    y)     $SC --file "$CFG" --enable "$name" ;;
    m)     $SC --file "$CFG" --module "$name" ;;
    n)     $SC --file "$CFG" --disable "$name" ;;
    \"*\") $SC --file "$CFG" --set-str "$name" "$(eval echo "$val")" ;;
    *)     $SC --file "$CFG" --set-val "$name" "$val" ;;
  esac
  n=$((n+1))
done < config/steamos-sc8280xp.config
echo "applied $n options"
