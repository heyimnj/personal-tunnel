#!/usr/bin/env bash
# Обновляет списки блокировки рекламы в PacketTunnel/Rules и пересчитывает SHA256SUMS (3.0.5).
#   ad-light.srs    — HaGeZi Light   («Базовый»)
#   ad-standard.srs — HaGeZi Pro     («Стандартный», по умолчанию)
#   ad-extended.srs — HaGeZi Pro++   («Расширенный»)
#   doh.srs         — HaGeZi Encrypted DNS Bypass (DoH/DoT серверы, iCloud Private Relay)
#   ad-ru.srs       — рекламные серверы из российских и мобильных разделов AdGuard Filters:
#                     только правила целого домена (||domain^) без привязки к сайтам,
#                     домены из списков исключений тех же фильтров выкидываются.
# HaGeZi DNS Blocklists и AdGuard Filters — GPL-3.0.
# ad-block.srs (geosite category-ads-all) входит во все уровни и не меняется здесь.
# Нужен build/sing-box-check (scripts/build-check-core.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULES="$ROOT/PacketTunnel/Rules"
CHECK="$ROOT/build/sing-box-check"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$CHECK" ] || { echo "нет $CHECK: сначала scripts/build-check-core.sh" >&2; exit 1; }

# Список доменов (по одному в строке, # — комментарий) → rule-set с domain_suffix.
compile_domains() { # <domains file> <output name>
  python3 -I - "$1" "$WORK/$2.json" <<'PY'
import json, re, sys
domains = set()
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip().lower()
    if line and not line.startswith("#") and re.fullmatch(r"[a-z0-9.-]+", line):
        domains.add(line)
json.dump({"version": 3, "rules": [{"domain_suffix": sorted(domains)}]}, open(sys.argv[2], "w"))
print(len(domains), "domains")
PY
  "$CHECK" rule-set compile --output "$RULES/$2.srs" "$WORK/$2.json"
}

hagezi() { # <hagezi list> <output name>
  local list="$1" name="$2"
  curl -fsSL "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/$list-onlydomains.txt" -o "$WORK/$list.txt"
  local version
  version="$(grep -m1 '^# Version:' "$WORK/$list.txt" | cut -d: -f2- | tr -d ' ')"
  compile_domains "$WORK/$list.txt" "$name"
  echo "$name.srs: HaGeZi $list $version"
  echo "$name.srs: HaGeZi DNS Blocklists, $list, version $version" >> "$WORK/sources.txt"
}

hagezi light ad-light
hagezi pro ad-standard
hagezi pro.plus ad-extended
hagezi doh doh

# AdGuard Filters: только нужные разделы, без истории.
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/AdguardTeam/AdguardFilters.git "$WORK/agf"
git -C "$WORK/agf" sparse-checkout set CyrillicFilters MobileFilter
REVISION="$(git -C "$WORK/agf" rev-parse HEAD)"
A="$WORK/agf"
python3 -I - "$WORK/ru.txt" \
  "$A/CyrillicFilters/common-sections/adservers.txt" \
  "$A/CyrillicFilters/common-sections/adservers_firstparty.txt" \
  "$A/CyrillicFilters/RussianFilter/sections/adservers_firstparty.txt" \
  "$A/MobileFilter/sections/adservers.txt" \
  "$A/CyrillicFilters/common-sections/allowlist.txt" \
  "$A/CyrillicFilters/RussianFilter/sections/allowlist.txt" \
  "$A/MobileFilter/sections/allowlist_app.txt" <<'PY'
import re, sys
# A file whose name has "firstparty" lists ad subdomains of ordinary sites: a rule
# there that is limited to third-party use (the site itself stays usable) cannot
# become a DNS block, which knows no context, so it is left out.
OK = {"important", "all", "popup", "script", "image", "subdocument", "xmlhttprequest", "media", "other",
      "object", "ping", "websocket", "font", "stylesheet", "match-case"}
THIRD = {"third-party", "3p"}
rule = re.compile(r"^\|\|([a-z0-9][a-z0-9.-]*\.[a-z0-9-]+)\^(?:\$(.*))?$")
allow = re.compile(r"^@@\|\|([a-z0-9][a-z0-9.-]*\.[a-z0-9-]+)\^")
blocked, allowed = set(), set()
for path in sys.argv[2:]:
    firstparty = "firstparty" in path
    for line in open(path, encoding="utf-8"):
        line = line.strip().lower()
        m = allow.match(line)
        if m:
            allowed.add(m.group(1))
            continue
        m = rule.match(line)
        if not m:
            continue
        opts = {o.strip() for o in (m.group(2) or "").split(",") if o.strip()}
        if firstparty and opts & THIRD:
            continue
        if opts <= OK | THIRD:
            blocked.add(m.group(1))
def covered(domain, names):
    parts = domain.split(".")
    return any(".".join(parts[i:]) in names for i in range(len(parts)))
kept = sorted(d for d in blocked if not covered(d, allowed))
open(sys.argv[1], "w").write("\n".join(kept) + "\n")
print(len(kept), "regional ad servers")
PY
# 3.1.4: рекламные сети мобильных игр, которых нет в этих фильтрах.
cat "$ROOT/scripts/ad-games.txt" >> "$WORK/ru.txt"
compile_domains "$WORK/ru.txt" ad-ru

{
  echo "Personal Tunnel ad-block lists from HaGeZi DNS Blocklists"
  echo "https://github.com/hagezi/dns-blocklists — GNU General Public License v3.0"
  echo
  cat "$WORK/sources.txt"
} > "$RULES/ad-hagezi.NOTICE.txt"
{
  echo "Personal Tunnel regional ad-block list (ad-ru.srs)"
  echo
  echo "Whole-domain ad server rules (\"||domain^\", without per-site context) from AdGuard Filters:"
  echo "CyrillicFilters/common-sections/adservers.txt, adservers_firstparty.txt,"
  echo "CyrillicFilters/RussianFilter/sections/adservers_firstparty.txt, MobileFilter/sections/adservers.txt;"
  echo "domains allowlisted in the same filters are left out."
  echo "https://github.com/AdguardTeam/AdguardFilters — GNU General Public License v3.0"
  echo "Revision: $REVISION"
} > "$RULES/ad-ru.NOTICE.txt"
(cd "$RULES" && sha256sum *.srs > SHA256SUMS)
cat "$RULES/SHA256SUMS"
