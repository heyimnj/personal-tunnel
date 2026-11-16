package ptbridge

import (
	"bytes"
	"sync"

	xray "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
)

// XrayInstance runs the servers only Xray-core understands. sing-box reaches
// each of them through an `xray-local` outbound naming this instance (3.3: in
// memory, no local port; TunnelCore's XrayBacked.runtime).
type XrayInstance struct {
	access   sync.Mutex
	name     string
	instance *xray.Instance
}

// StartXray starts Xray-core with a JSON configuration under `name`, the
// instance `xray-local` outbounds name. A new instance under a name replaces the
// old one for new connections.
func StartXray(name string, configJSON string) (*XrayInstance, error) {
	config, err := serial.LoadJSONConfig(bytes.NewBufferString(configJSON))
	if err != nil {
		return nil, err
	}
	instance, err := xray.New(config)
	if err != nil {
		return nil, err
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		return nil, err
	}
	registerInstance(name, instance)
	return &XrayInstance{name: name, instance: instance}, nil
}

// CheckXray reports whether Xray-core accepts a configuration, without starting it.
func CheckXray(configJSON string) error {
	config, err := serial.LoadJSONConfig(bytes.NewBufferString(configJSON))
	if err != nil {
		return err
	}
	instance, err := xray.New(config)
	if err != nil {
		return err
	}
	return instance.Close()
}

// Close stops the instance and takes its name back.
func (x *XrayInstance) Close() {
	if x == nil {
		return
	}
	x.access.Lock()
	defer x.access.Unlock()
	if x.instance != nil {
		unregisterInstance(x.name, x.instance)
		x.instance.Close()
		x.instance = nil
	}
}
