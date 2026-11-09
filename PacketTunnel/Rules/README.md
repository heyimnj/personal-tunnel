# Bundled rule sets

Compiled sing-box rule sets loaded by the packet tunnel. They ship inside the
extension, so ad blocking and the Russian bypass work offline and nothing is
downloaded at runtime.

| File | Source | Revision |
|---|---|---|
| `ad-block.srs` | SagerNet/sing-geosite `geosite-category-ads-all.srs` (data: v2fly/domain-list-community) | `c04f75d2272d2f32426dbc79a76641349291c9e0` |
| `ru-domains.srs` | runetfreedom/russia-v2ray-rules-dat `sing-box/rule-set-geosite/geosite-category-ru.srs` | `af4bdd166fc2f16254da756be380c8bbca167d50` |
| `ru-inside.srs` | runetfreedom/russia-v2ray-rules-dat `sing-box/rule-set-geosite/geosite-ru-available-only-inside.srs` | `af4bdd166fc2f16254da756be380c8bbca167d50` |
| `ru-ip.srs` | runetfreedom/russia-v2ray-rules-dat `sing-box/rule-set-geoip/geoip-ru.srs` | `af4bdd166fc2f16254da756be380c8bbca167d50` |

`SHA256SUMS` lists the expected hashes; the build checks them. Refresh the
Russian lists with `scripts/update-rule-sets.sh`. Licences: `ad-block.NOTICE.txt`
(GPL-3.0 / MIT); the runetfreedom lists are published under GPL-3.0.
