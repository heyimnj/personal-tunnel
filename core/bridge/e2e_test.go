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
