package ptbridge

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

	if result := prober.Test("server-a", server.URL, 3000); result.Error != "" || result.Delay < 1 {
		t.Fatalf("server-a: %+v", result)
	}
	if result := prober.Test("server-b", server.URL, 3000); result.Error == "" {
		t.Fatal("server-b answered through a closed port")
	}
	if result := prober.Test("missing", server.URL, 3000); !strings.Contains(result.Error, "not found") {
		t.Fatalf("missing: %+v", result)
	}
	prober.Close()
	if result := prober.Test("server-a", server.URL, 3000); result.Error == "" {
		t.Fatal("closed prober still answers")
	}
}

// The app's probe configurations (written by tunnelcore-fixtures) start the core.
func TestProberStartsOnProbeFixtures(t *testing.T) {
	folder := os.Getenv("PT_PROBE_FIXTURES")
	if folder == "" {
		t.Skip("PT_PROBE_FIXTURES not set")
	}
	files, _ := filepath.Glob(filepath.Join(folder, "probe-*.json"))
	if len(files) == 0 {
		t.Fatalf("no probe-*.json in %s", folder)
	}
	for _, file := range files {
		content, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		prober, err := NewProber(string(content))
		if err != nil {
			t.Fatalf("%s: %v", filepath.Base(file), err)
		}
		prober.Close()
	}
}

func TestSetGCPercent(t *testing.T) {
	previous := SetGCPercent(50)
	defer SetGCPercent(previous)
	if SetGCPercent(50) != 50 {
		t.Fatal("GC percent was not set")
	}
	FreeMemory()
}
