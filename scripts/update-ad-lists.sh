#!/usr/bin/env bash
# Обновляет списки блокировки рекламы в PacketTunnel/Rules из HaGeZi DNS Blocklists
# (GPL-3.0, https://github.com/hagezi/dns-blocklists) и пересчитывает SHA256SUMS.
#   ad-standard.srs — HaGeZi Light   («Стандартный», по умолчанию)
#   ad-extended.srs — HaGeZi Normal  («Расширенный»)
# ad-block.srs (geosite category-ads-all, «Базовый») входит во все уровни и не меняется здесь.
# Нужен build/sing-box-check (scripts/build-check-core.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULES="$ROOT/PacketTunnel/Rules"
CHECK="$ROOT/build/sing-box-check"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$CHECK" ] || { echo "нет $CHECK: сначала scripts/build-check-core.sh" >&2; exit 1; }

compile() { # <hagezi list> <output name>
  local list="$1" name="$2"
  curl -fsSL "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/$list-onlydomains.txt" -o "$WORK/$list.txt"
  local version
  version="$(grep -m1 '^# Version:' "$WORK/$list.txt" | cut -d: -f2- | tr -d ' ')"
  python3 -I - "$WORK/$list.txt" "$WORK/$name.json" <<'PY'
import json, re, sys
domains = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if re.fullmatch(r"[a-z0-9.-]+", line):
        domains.append(line)
json.dump({"version": 3, "rules": [{"domain_suffix": sorted(set(domains))}]}, open(sys.argv[2], "w"))
print(len(set(domains)), "domains")
PY
  "$CHECK" rule-set compile --output "$RULES/$name.srs" "$WORK/$name.json"
  echo "$name.srs: HaGeZi $list $version"
  echo "$name.srs: HaGeZi DNS Blocklists, $list, version $version" >> "$WORK/sources.txt"
}

compile light ad-standard
compile multi ad-extended
{
  echo "Personal Tunnel ad-block lists from HaGeZi DNS Blocklists"
  echo "https://github.com/hagezi/dns-blocklists — GNU General Public License v3.0"
  echo
  cat "$WORK/sources.txt"
} > "$RULES/ad-hagezi.NOTICE.txt"
(cd "$RULES" && sha256sum *.srs > SHA256SUMS)
cat "$RULES/SHA256SUMS"
