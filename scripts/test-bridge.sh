#!/usr/bin/env bash
# Тесты моста core/bridge на текущей системе (Linux в CI): ядро sing-box без туннеля
# измеряет серверы, Xray-core подключён без конфликтов с sing-box.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/core-env.sh
source "$ROOT/scripts/core-env.sh"
fetch_core
fetch_xray
cd "$BRIDGE_DIR"
go vet -tags "$CHECK_TAGS" ./...
go test -trimpath -tags "$CHECK_TAGS" -ldflags "-checklinkname=0" ./...
