package ptbridge

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestXrayLinked(t *testing.T) {
	if XrayVersion() == "" {
		t.Fatal("no Xray version")
	}
}

func TestProberMeasuresThroughOutbound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	prober, err := NewProber(`{
		"log": {"level": "error"},
		"dns": {"servers": [{"type": "udp", "tag": "dns-direct", "server": "1.1.1.1"}], "final": "dns-direct"},
		"outbounds": [
			{"type": "direct", "tag": "server-a"},
			{"type": "socks", "tag": "server-b", "server": "127.0.0.1", "server_port": 1},
			{"type": "direct", "tag": "direct"}
		],
		"route": {"default_domain_resolver": {"server": "dns-direct"}, "final": "direct"}
	}`)
	if err != nil {
		t.Fatal(err)
	}
	defer prober.Close()

	if _, err := prober.Test("server-a", server.URL, 3000); err != nil {
		t.Fatalf("server-a: %v", err)
	}
	if _, err := prober.Test("server-b", server.URL, 3000); err == nil {
		t.Fatal("server-b answered through a closed port")
	}
	if _, err := prober.Test("missing", server.URL, 3000); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("missing: %v", err)
	}
	prober.Close()
	if _, err := prober.Test("server-a", server.URL, 3000); err == nil {
		t.Fatal("closed prober still answers")
	}
}
