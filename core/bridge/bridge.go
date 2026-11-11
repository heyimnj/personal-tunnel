// Package ptbridge is Personal Tunnel's own part of the core library. It is
// bound together with sing-box's libbox into one framework, so the app and the
// extension share a single Go runtime, and it links Xray-core in beside sing-box.
package ptbridge

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	N "github.com/sagernet/sing/common/network"

	xray "github.com/xtls/xray-core/core"
	// Every Xray protocol, transport and mask, so any server Xray understands can run.
	_ "github.com/xtls/xray-core/main/distro/all"
)

// XrayVersion is the version of the linked Xray-core.
func XrayVersion() string { return xray.Version() }

// Prober runs sing-box without a tunnel and measures servers the way a
// connection would use them: a URL fetched through each server's outbound.
// It lives in the app, outside the extension's memory limit.
type Prober struct {
	instance *box.Box
	ctx      context.Context
	cancel   context.CancelFunc
	once     sync.Once
}

// NewProber starts the core with a configuration that has outbounds but no inbounds.
func NewProber(configJSON string) (*Prober, error) {
	ctx, cancel := context.WithCancel(include.Context(context.Background()))
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		cancel()
		return nil, err
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		cancel()
		return nil, err
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		cancel()
		return nil, err
	}
	return &Prober{instance: instance, ctx: ctx, cancel: cancel}, nil
}

// ProbeResult is one measurement: Delay in milliseconds, or Error.
type ProbeResult struct {
	Delay int32
	Error string
}

// Test fetches link through the outbound or endpoint tagged tag. It blocks;
// callers run several at once.
func (p *Prober) Test(tag string, link string, timeoutMs int32) *ProbeResult {
	delay, err := p.test(tag, link, timeoutMs)
	if err != nil {
		return &ProbeResult{Error: err.Error()}
	}
	if delay < 1 {
		delay = 1
	}
	return &ProbeResult{Delay: delay}
}

func (p *Prober) test(tag string, link string, timeoutMs int32) (int32, error) {
	if p == nil || p.instance == nil || p.ctx.Err() != nil {
		return 0, errors.New("prober closed")
	}
	var dialer N.Dialer
	if outbound, found := p.instance.Outbound().Outbound(tag); found {
		dialer = outbound
	} else if endpoint, found := p.instance.Endpoint().Get(tag); found {
		dialer = endpoint
	} else {
		return 0, errors.New("outbound not found: " + tag)
	}
	ctx, cancel := context.WithTimeout(p.ctx, time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	delay, err := urltest.URLTest(ctx, strings.TrimSpace(link), dialer)
	return int32(delay), err
}

// Close stops the core. Tests still running end with an error.
func (p *Prober) Close() {
	if p == nil {
		return
	}
	p.once.Do(func() {
		p.cancel()
		if p.instance != nil {
			p.instance.Close()
		}
	})
}
