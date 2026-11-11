import Foundation
import TunnelCore

// Writes one sing-box configuration per sample into the given folder, so CI can
// check them with the pinned core: `sing-box check -c <file>`.
//
//   tunnelcore-fixtures <output folder> <rule set folder>

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: tunnelcore-fixtures <output> <rules>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
let rules = arguments[2]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let key = "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"
let wgPrivate = "YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
let wgPublic = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="
let extra = TextCoding.percentEncode(#"{"xPaddingBytes":"100-1000","noGRPCHeader":true,"scMaxEachPostBytes":"1000000","scMinPostsIntervalMs":"30","xmux":{"maxConcurrency":"16-32","cMaxReuseTimes":"64-128","hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":30}}"#)

let samples: [(String, [String])] = [
    ("vless-reality-vision", ["vless://11111111-2222-3333-4444-555555555555@example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=\(key)&sid=6ba85179e30d4fc2&type=tcp#Reality"]),
    ("vless-ws-tls", ["vless://11111111-2222-3333-4444-555555555555@1.2.3.4:8443?security=tls&sni=cdn.example.org&type=ws&host=cdn.example.org&path=%2Fws%3Fed%3D2048&alpn=h2%2Chttp%2F1.1&fp=firefox#WS"]),
    ("vless-grpc-reality", ["vless://11111111-2222-3333-4444-555555555555@h.example:443?security=reality&pbk=\(key)&sid=ab&sni=h.example&type=grpc&serviceName=grpc-svc#gRPC"]),
    ("vless-xhttp", ["vless://11111111-2222-3333-4444-555555555555@h.example:443?security=tls&sni=h.example&type=xhttp&host=h.example&path=%2Fxh&mode=packet-up&extra=\(extra)#XHTTP",
                     "vless://11111111-2222-3333-4444-555555555555@h2.example:443?security=reality&pbk=\(key)&sid=&sni=h2.example&type=xhttp&path=%2Fxh&mode=stream-one#XHTTP Reality"]),
    ("vless-httpupgrade-quic", ["vless://11111111-2222-3333-4444-555555555555@h.example:443?security=tls&type=httpupgrade&host=h.example&path=%2Fup#HTTPUpgrade",
                                "vless://11111111-2222-3333-4444-555555555555@q.example:443?security=tls&sni=q.example&type=quic#QUIC",
                                "vless://11111111-2222-3333-4444-555555555555@t.example:80?type=tcp&headerType=http&host=t.example&path=%2F#HTTP header"]),
    ("vmess", ["vmess://" + Data(#"{"v":"2","ps":"VMess","add":"vm.example.com","port":"443","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","aid":"0","scy":"auto","net":"ws","type":"none","host":"vm.example.com","path":"/vm","tls":"tls","sni":"vm.example.com"}"#.utf8).base64EncodedString()]),
    ("trojan", ["trojan://password@tr.example.com:443?type=grpc&serviceName=svc#Trojan gRPC", "trojan://password@tr2.example.com:443#Trojan"]),
    ("shadowsocks", ["ss://" + Data("aes-256-gcm:secret".utf8).base64EncodedString() + "@ss.example.com:8388#SS",
                     "ss://2022-blake3-aes-128-gcm:MTIzNDU2Nzg5MDEyMzQ1Ng%3D%3D@ss2.example.com:8443#SS2022"]),
    ("hysteria2", ["hysteria2://pass@hy.example.com:443,20000-30000?sni=hy.example.com&insecure=1&obfs=salamander&obfs-password=obfs#Hy2",
                   "hy2://pass@hy2.example.com:8443#Hy2 plain"]),
    ("tuic", ["tuic://11111111-2222-3333-4444-555555555555:secret@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=tuic.example.com#TUIC"]),
    ("wireguard", ["wireguard://\(TextCoding.percentEncode(wgPrivate))@wg.example.com:51820?publickey=\(TextCoding.percentEncode(wgPublic))&address=10.7.0.2,fd00::2&mtu=1280&reserved=1,2,3&keepalive=25#WG"]),
    ("amneziawg", ["awg://\(TextCoding.percentEncode(wgPrivate))@awg.example.com:51820?publickey=\(TextCoding.percentEncode(wgPublic))&address=10.8.0.2&jc=4&jmin=40&jmax=70&s1=15&s2=25&h1=1234567&h2=2345678&h3=3456789&h4=4567890#AWG"]),
    ("simple", ["socks5://user:pass@socks.example.com:1080#SOCKS", "anytls://password@any.example.com:443#AnyTLS", "hysteria://hy1.example.com:443?auth=secret&upmbps=20&downmbps=100#Hy1"]),
]

let xray = """
[
  {"remarks": "Reality", "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "us.example.net", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
     "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "www.apple.com", "publicKey": "\(key)", "shortId": "abcd", "fingerprint": "chrome"}}},
    {"tag": "direct", "protocol": "freedom"}]},
  {"remarks": "Авто", "outbounds": [
    {"tag": "a", "protocol": "vless", "settings": {"address": "a.example.net", "port": 443, "id": "aaaaaaaa-2222-3333-4444-555555555555", "encryption": "none"},
     "streamSettings": {"network": "ws", "security": "tls", "tlsSettings": {"serverName": "a.example.net"}, "wsSettings": {"path": "/ws", "headers": {"Host": "a.example.net"}}}},
    {"tag": "b", "protocol": "trojan", "settings": {"servers": [{"address": "b.example.net", "port": 443, "password": "pw"}]},
     "streamSettings": {"network": "grpc", "security": "tls", "tlsSettings": {"serverName": "b.example.net"}, "grpcSettings": {"serviceName": "svc"}}}]},
  {"remarks": "XHTTP", "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "x.example.net", "port": 443, "users": [{"id": "cccccccc-2222-3333-4444-555555555555", "encryption": "none"}]}]},
     "streamSettings": {"network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "x.example.net", "alpn": ["h2"]},
       "xhttpSettings": {"host": "x.example.net", "path": "/xh", "mode": "auto", "extra": {"xPaddingBytes": "100-1000", "scMaxEachPostBytes": {"from": 500000, "to": 1000000}}}}}]},
  {"remarks": "Hy2", "outbounds": [
    {"tag": "proxy", "protocol": "hysteria", "settings": {"address": "hy.example.net", "port": 443, "version": 2},
     "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "hy.example.net", "alpn": ["h3"]}, "hysteriaSettings": {"version": 2, "auth": "secret"},
       "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "mask"}}], "quicParams": {"udpHop": {"ports": "20000-30000", "interval": 30}, "brutalUp": "50 mbps", "brutalDown": "200 mbps"}}}}]}
]
"""

// What 1.x stored: locations are selectors over leaves, every leaf resolves through
// `dns-local`, some use the removed `domain_strategy` or detour through outbounds that
// are gone. Migrated servers keep those fields; the built configuration must not.
let legacy = """
{"dns": {"servers": [{"type": "udp", "tag": "dns-remote", "server": "1.1.1.1"}, {"type": "local", "tag": "dns-local"}], "final": "dns-remote"},
 "outbounds": [
  {"type": "selector", "tag": "proxy", "outbounds": ["auto", "США", "Эстония", "Финляндия", "WG", "Лучший"], "default": "auto"},
  {"type": "urltest", "tag": "auto", "outbounds": ["США", "Эстония", "Финляндия", "WG", "Лучший"], "interval": "3m", "tolerance": 150},
  {"type": "vless", "tag": "США-1", "server": "us.example.net", "server_port": 443, "uuid": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision",
   "tls": {"enabled": true, "server_name": "www.microsoft.com", "utls": {"enabled": true, "fingerprint": "chrome"},
           "reality": {"enabled": true, "public_key": "\(key)", "short_id": "6ba85179e30d4fc2"}},
   "domain_resolver": {"server": "dns-local", "strategy": "prefer_ipv4"}, "detour": "fragment"},
  {"type": "trojan", "tag": "Эстония-1", "server": "ee.example.net", "server_port": 443, "password": "p", "domain_strategy": "ipv4_only",
   "tls": {"enabled": true, "server_name": "ee.example.net"}, "transport": {"type": "grpc", "service_name": "svc"}},
  {"type": "hysteria2", "tag": "Финляндия-1", "server": "fi.example.net", "server_port": 443, "password": "p",
   "tls": {"enabled": true, "server_name": "fi.example.net", "alpn": ["h3"]}, "domain_resolver": "dns-local"},
  {"type": "selector", "tag": "США", "outbounds": ["США-1"], "default": "США-1"},
  {"type": "selector", "tag": "Эстония", "outbounds": ["Эстония-1", "Эстония-gone"], "default": "Эстония-gone"},
  {"type": "selector", "tag": "Финляндия", "outbounds": ["Финляндия-1"], "default": "Финляндия-1"},
  {"type": "selector", "tag": "WG", "outbounds": ["WG-1"], "default": "WG-1"},
  {"type": "urltest", "tag": "Лучший", "outbounds": ["США", "Эстония", "Финляндия"]},
  {"type": "direct", "tag": "direct"}
 ],
 "endpoints": [{"type": "wireguard", "tag": "WG-1", "address": ["10.7.0.2/32"], "private_key": "\(wgPrivate)", "mtu": 1280,
                "peers": [{"address": "wg.example.net", "port": 51820, "public_key": "\(wgPublic)", "allowed_ips": ["0.0.0.0/0", "::/0"]}],
                "domain_resolver": {"server": "dns-local"}}],
 "route": {"default_domain_resolver": {"server": "dns-local", "strategy": "prefer_ipv4"}, "final": "proxy"}}
"""

var written = 0
func write(_ name: String, _ parsed: [ParsedNode], _ configure: (inout TunnelOptions) -> Void = { _ in }) throws {
    try write(name, Subscription(id: 1, name: name, nodes: NodeAssembler.assemble(parsed)), configure)
}

func write(_ name: String, _ subscription: Subscription, _ configure: (inout TunnelOptions) -> Void = { _ in }) throws {
    var options = TunnelOptions()
    configure(&options)
    let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
    let text = ConfigBuilder.relocateRuleSets(in: config, directory: rules).serialized(pretty: true)
    try text.write(to: output.appendingPathComponent(name + ".json"), atomically: true, encoding: .utf8)
    written += 1
}

for (name, links) in samples {
    try write(name, try links.map(ShareLink.parse))
}
try write("xray-subscription", try ContentImporter.parse(xray).nodes)
try write("all-together", try samples.flatMap { try $0.1.map(ShareLink.parse) } + ContentImporter.parse(xray).nodes)
try write("no-routing-options", try samples[0].1.map(ShareLink.parse)) { options in
    options.adBlocking = false
    options.bypassRussia = false
    options.bypassPrivate = false
}
let migrated = LegacyMigration.library(from: [LegacyProfile(id: 1, name: "1.x", order: 0, remoteURL: nil, lastUpdated: nil, config: legacy)],
                                        selectedProfileID: 1, preferredTag: "Эстония")
guard let carried = migrated.subscriptions.first, carried.nodes.count == 5 else {
    FileHandle.standardError.write(Data("legacy sample: migration lost servers\n".utf8))
    exit(1)
}
try write("legacy-1x-subscription", carried)
try write("auto-select", try samples.prefix(3).flatMap { try $0.1.map(ShareLink.parse) }) { $0.autoSelect = true }
print("written \(written) configurations to \(output.path)")
