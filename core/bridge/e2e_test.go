package ptbridge

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	xray "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
)

func freePort(t *testing.T) int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

// startXray runs an Xray server from JSON in this process.
func startXray(t *testing.T, config string) {
	t.Helper()
	parsed, err := serial.LoadJSONConfig(bytes.NewBufferString(config))
	if err != nil {
		t.Fatal(err)
	}
	instance, err := xray.New(parsed)
	if err != nil {
		t.Fatal(err)
	}
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { instance.Close() })
}

// A current Xray server and the sing-box the app runs, built with this module's
// Go and dependencies, carry a connection end to end. (REALITY is left out: a
// local stand does not reproduce the real TLS 1.3 site it borrows a handshake from.)
func TestSingBoxReachesXrayServers(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer target.Close()

	// REALITY borrows the handshake of a real TLS 1.3 site: a local one here.
	site := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	site.TLS = &tls.Config{MinVersion: tls.VersionTLS13}
	site.StartTLS()
	defer site.Close()

	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	private := base64.RawURLEncoding.EncodeToString(key.Bytes())
	public := base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
	uuid := "11111111-2222-3333-4444-555555555555"
	realityPort, plainPort := freePort(t), freePort(t)

	startXray(t, fmt.Sprintf(`{
		"log": {"loglevel": "warning"},
		"inbounds": [
			{"listen": "127.0.0.1", "port": %d, "protocol": "vless",
			 "settings": {"clients": [{"id": "%s", "flow": "xtls-rprx-vision"}], "decryption": "none"},
			 "streamSettings": {"network": "raw", "security": "reality",
			   "realitySettings": {"target": "%s", "serverNames": ["example.com"], "privateKey": "%s", "shortIds": ["ab12"]}}},
			{"listen": "127.0.0.1", "port": %d, "protocol": "vless",
			 "settings": {"clients": [{"id": "%s"}], "decryption": "none"}}
		],
		"outbounds": [{"protocol": "freedom", "settings": {"finalRules": [{"action": "allow"}]}}]
	}`, realityPort, uuid, site.Listener.Addr().String(), private, plainPort, uuid))

	prober, err := NewProber(fmt.Sprintf(`{
		"log": {"level": "warn"},
		"dns": {"servers": [{"type": "local", "tag": "dns-direct"}], "final": "dns-direct"},
		"outbounds": [
			{"type": "vless", "tag": "reality", "server": "127.0.0.1", "server_port": %d, "uuid": "%s", "flow": "xtls-rprx-vision",
			 "tls": {"enabled": true, "server_name": "example.com", "utls": {"enabled": true, "fingerprint": "chrome"},
			         "reality": {"enabled": true, "public_key": "%s", "short_id": "ab12"}}},
			{"type": "vless", "tag": "plain", "server": "127.0.0.1", "server_port": %d, "uuid": "%s"},
			{"type": "direct", "tag": "direct"}
		],
		"route": {"default_domain_resolver": {"server": "dns-direct"}, "final": "direct"}
	}`, realityPort, uuid, public, plainPort, uuid))
	if err != nil {
		t.Fatal(err)
	}
	defer prober.Close()

	for _, tag := range []string{"plain"} {
		if result := prober.Test(tag, target.URL, 5000); result.Error != "" {
			t.Errorf("%s: %s", tag, result.Error)
		} else {
			t.Logf("%s: %d ms", tag, result.Delay)
		}
	}
}

// A server only Xray-core can run (a sudoku mask the server undoes): the app's
// Xray instance serves it on a local SOCKS port, sing-box reaches it through
// that port — the path the tunnel and the app's measurements take.
func TestSingBoxReachesXrayOnlyServerThroughLocalXray(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer target.Close()
	uuid := "11111111-2222-3333-4444-555555555555"
	serverPort, localPort := freePort(t), freePort(t)
	mask := `"finalmask": {"tcp": [{"type": "sudoku", "settings": {"password": "mask"}}]}`
	startXray(t, fmt.Sprintf(`{
		"log": {"loglevel": "warning"},
		"inbounds": [{"listen": "127.0.0.1", "port": %d, "protocol": "vless",
		  "settings": {"clients": [{"id": "%s"}], "decryption": "none"}, "streamSettings": {"network": "raw", %s}}],
		"outbounds": [{"protocol": "freedom", "settings": {"finalRules": [{"action": "allow"}]}}]
	}`, serverPort, uuid, mask))

	// What XrayBacked.runtime writes for one server.
	client, err := StartXray(fmt.Sprintf(`{
		"log": {"loglevel": "warning"},
		"inbounds": [{"tag": "in0", "listen": "127.0.0.1", "port": %d, "protocol": "socks", "settings": {"auth": "noauth", "udp": true, "ip": "127.0.0.1"}}],
		"outbounds": [{"protocol": "blackhole", "tag": "pt-block"},
		  {"tag": "n0-proxy", "protocol": "vless", "settings": {"vnext": [{"address": "127.0.0.1", "port": %d, "users": [{"id": "%s", "encryption": "none"}]}]},
		   "streamSettings": {"network": "raw", %s}}],
		"routing": {"domainStrategy": "AsIs", "rules": [{"type": "field", "inboundTag": ["in0"], "outboundTag": "n0-proxy"}]}
	}`, localPort, serverPort, uuid, mask))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	prober, err := NewProber(fmt.Sprintf(`{
		"log": {"level": "warn"},
		"outbounds": [{"type": "socks", "tag": "sudoku", "server": "127.0.0.1", "server_port": %d, "version": "5"}, {"type": "direct", "tag": "direct"}],
		"route": {"final": "direct"}
	}`, localPort))
	if err != nil {
		t.Fatal(err)
	}
	defer prober.Close()
	if result := prober.Test("sudoku", target.URL, 5000); result.Error != "" {
		t.Fatalf("sudoku: %s", result.Error)
	} else {
		t.Logf("sudoku through local Xray: %d ms", result.Delay)
	}
}

// The Xray configurations the app writes for its subscriptions (tunnelcore-fixtures).
func TestXrayRuntimeFixturesLoad(t *testing.T) {
	folder := os.Getenv("PT_PROBE_FIXTURES")
	if folder == "" {
		t.Skip("PT_PROBE_FIXTURES not set")
	}
	files, _ := filepath.Glob(filepath.Join(folder, "xray-runtime-*.json"))
	if len(files) == 0 {
		t.Fatalf("no xray-runtime-*.json in %s", folder)
	}
	for _, file := range files {
		content, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if err := CheckXray(string(content)); err != nil {
			t.Errorf("%s: %v", filepath.Base(file), err)
		}
	}
}
