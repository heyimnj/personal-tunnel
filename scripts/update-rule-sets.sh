#!/usr/bin/env bash
# Downloads the current Russian bypass rule sets from runetfreedom/russia-v2ray-rules-dat
# into PacketTunnel/Rules and refreshes SHA256SUMS. Review the diff before committing.
set -euo pipefail
cd "$(dirname "$0")/../PacketTunnel/Rules"
base="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box"
curl -fsSL -o ru-domains.srs "$base/rule-set-geosite/geosite-category-ru.srs"
curl -fsSL -o ru-inside.srs "$base/rule-set-geosite/geosite-ru-available-only-inside.srs"
curl -fsSL -o ru-ip.srs "$base/rule-set-geoip/geoip-ru.srs"
for file in ru-domains.srs ru-inside.srs ru-ip.srs; do
  [[ "$(head -c 3 "$file")" == "SRS" ]] || { echo "error: $file is not a sing-box rule set" >&2; exit 1; }
done
revision="$(git ls-remote https://github.com/runetfreedom/russia-v2ray-rules-dat.git refs/heads/release | cut -f1)"
shasum -a 256 ./*.srs | sed 's#  \./#  #' > SHA256SUMS
echo "runetfreedom release revision: $revision (update README.md in this directory)"
