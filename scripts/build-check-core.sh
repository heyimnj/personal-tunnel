#!/usr/bin/env bash
# Собирает закреплённое ядро под текущую систему (Linux в CI), чтобы проверять им
# сгенерированные конфигурации: `build/sing-box-check check -c config.json`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/core-env.sh
source "$ROOT/scripts/core-env.sh"
fetch_core
cd "$CORE_CHECKOUT"
go build -trimpath -buildvcs=false \
  -tags "$CHECK_TAGS" \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=${SING_BOX_TAG#v} -checklinkname=0 -s -w" \
  -o "$ROOT/build/sing-box-check" ./cmd/sing-box
"$ROOT/build/sing-box-check" version | head -3
