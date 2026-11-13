package ptbridge

import (
	"bytes"
	"sync"

	xray "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
)

// XrayInstance runs the servers only Xray-core understands, each behind a local
// SOCKS port that sing-box connects to (TunnelCore's XrayBacked.runtime).
type XrayInstance struct {
	access   sync.Mutex
	instance *xray.Instance
}

// StartXray starts Xray-core with a JSON configuration.
func StartXray(configJSON string) (*XrayInstance, error) {
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
	return &XrayInstance{instance: instance}, nil
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

// Close stops the instance; its ports are free afterwards.
func (x *XrayInstance) Close() {
	if x == nil {
		return
	}
	x.access.Lock()
	defer x.access.Unlock()
	if x.instance != nil {
		x.instance.Close()
		x.instance = nil
	}
}
