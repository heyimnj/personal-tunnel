#!/usr/bin/env bash
# Тесты моста core/bridge на текущей системе (Linux в CI): ядро sing-box без туннеля
# измеряет серверы, Xray-core подключён без конфликтов с sing-box.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/core-env.sh
source "$ROOT/scripts/core-env.sh"
fetch_core
fetch_xray
# Personal Tunnel's own patches to the core carry their tests (core/patches):
# the certificate pin (PT-03) in both TLS engines.
(cd "$CORE_CHECKOUT" && go test -count=1 -trimpath -tags "$CHECK_TAGS" -ldflags "-checklinkname=0" -run 'CertificateSHA256' ./common/tls/)
# The DNS group's `ordered` mode (0006): HTTPS first, plain DNS while it fails.
(cd "$CORE_CHECKOUT" && go test -count=1 -trimpath -tags "$CHECK_TAGS" -ldflags "-checklinkname=0" -run 'Ordered' ./dns/transport/group/)
# The service's traffic read in process (0008), for the extension's session history.
(cd "$CORE_CHECKOUT" && go test -count=1 -trimpath -tags "$CHECK_TAGS" -ldflags "-checklinkname=0" -run 'TrafficTotalWithoutServiceLX' ./experimental/libbox/)
# Closed connections no longer listed come back by route in a new stream's snapshot (0009).
(cd "$CORE_CHECKOUT" && go test -count=1 -trimpath -tags "$CHECK_TAGS" -ldflags "-checklinkname=0" -run 'EvictedRoutesLX' ./common/trafficcontrol/)
# A query in a WebSocket/HTTP path reaches the server as the query (0007).
(cd "$CORE_CHECKOUT" && go test -count=1 -trimpath -tags "$CHECK_TAGS" -ldflags "-checklinkname=0" -run 'PathQueryLX' ./transport/v2raywebsocket/)
cd "$BRIDGE_DIR"
go vet -tags "$CHECK_TAGS" ./...
# Конфигурации проверки серверов из tunnelcore-fixtures, если они уже записаны.
if [ -d "$ROOT/build/fixtures" ]; then export PT_PROBE_FIXTURES="$ROOT/build/fixtures"; fi
go test -trimpath -tags "$CHECK_TAGS" -ldflags "-checklinkname=0" ./...
