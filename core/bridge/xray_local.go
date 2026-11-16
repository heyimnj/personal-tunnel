package ptbridge

// xray-local: a sing-box outbound that hands each connection to the Xray-core
// instance in the same process (3.3, audit PT-01). Before, sing-box reached
// Xray through a SOCKS port on 127.0.0.1, which any app on the device could find
// and, until 3.3 beta 1, use. Now there is no port, no socket and nothing to log
// in to: the connection goes from one core to the other in memory.
//
// Options: {"type": "xray-local", "tag": "…", "instance": "tunnel", "inbound": "in0"}.
// `instance` names the Xray instance (StartXrayNamed); `inbound` is the inbound
// tag Xray's routing sends to this server's outbound.

import (
	"context"
	"net"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	xray "github.com/xtls/xray-core/core"
)

// XrayLocalType is the outbound type TunnelCore writes (XrayBacked.local).
const XrayLocalType = "xray-local"

type xrayLocalOptions struct {
	Instance string `json:"instance"`
	Inbound  string `json:"inbound"`
}

var (
	instancesAccess sync.RWMutex
	instances       = map[string]*xray.Instance{}
)

func registerInstance(name string, instance *xray.Instance) {
	instancesAccess.Lock()
	defer instancesAccess.Unlock()
	instances[name] = instance
}

func unregisterInstance(name string, instance *xray.Instance) {
	instancesAccess.Lock()
	defer instancesAccess.Unlock()
	if instances[name] == instance {
		delete(instances, name)
	}
}

func instanceNamed(name string) *xray.Instance {
	instancesAccess.RLock()
	defer instancesAccess.RUnlock()
	return instances[name]
}

func init() {
	include.ExternalOutbounds = append(include.ExternalOutbounds, func(registry *outbound.Registry) {
		outbound.Register[xrayLocalOptions](registry, XrayLocalType, newXrayLocal)
	})
}

type xrayLocal struct {
	outbound.Adapter
	logger   log.ContextLogger
	instance string
	inbound  string
}

func newXrayLocal(_ context.Context, _ adapter.Router, logger log.ContextLogger, tag string, options xrayLocalOptions) (adapter.Outbound, error) {
	if options.Instance == "" || options.Inbound == "" {
		return nil, E.New("xray-local: instance and inbound are required")
	}
	return &xrayLocal{
		Adapter:  outbound.NewAdapter(XrayLocalType, tag, []string{N.NetworkTCP, N.NetworkUDP}, nil),
		logger:   logger,
		instance: options.Instance,
		inbound:  options.Inbound,
	}, nil
}

// context for Xray: its routing picks the server's outbound by the inbound tag.
// Not derived from the dial's context: Xray ties the link's life to it, and a
// dial context ends (a timeout) while the connection lives on.
func (h *xrayLocal) xrayContext() (context.Context, *xray.Instance, error) {
	instance := instanceNamed(h.instance)
	if instance == nil {
		return nil, nil, E.New("xray-local: Xray-core instance ", h.instance, " is not running")
	}
	return session.ContextWithInbound(context.Background(), &session.Inbound{Tag: h.inbound}), instance, nil
}

func xrayAddress(destination M.Socksaddr) xnet.Address {
	if destination.IsFqdn() {
		return xnet.DomainAddress(destination.Fqdn)
	}
	return xnet.IPAddress(destination.Addr.AsSlice())
}

func (h *xrayLocal) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	xctx, instance, err := h.xrayContext()
	if err != nil {
		return nil, err
	}
	port := xnet.Port(destination.Port)
	switch N.NetworkName(network) {
	case N.NetworkTCP:
		return xray.Dial(xctx, instance, xnet.TCPDestination(xrayAddress(destination), port))
	case N.NetworkUDP:
		return xray.Dial(xctx, instance, xnet.UDPDestination(xrayAddress(destination), port))
	default:
		return nil, E.Extend(N.ErrUnknownNetwork, network)
	}
}

func (h *xrayLocal) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	xctx, instance, err := h.xrayContext()
	if err != nil {
		return nil, err
	}
	conn, err := xray.DialUDP(xctx, instance)
	if err != nil {
		return nil, err
	}
	return &xrayPacketConn{PacketConn: conn}, nil
}

// xrayPacketConn gives Xray's packet connection the addresses it understands:
// it takes *net.UDPAddr only (anything else panics in DestinationFromAddr).
type xrayPacketConn struct {
	net.PacketConn
}

func (c *xrayPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	switch address := addr.(type) {
	case *net.UDPAddr:
		return c.PacketConn.WriteTo(p, address)
	case M.Socksaddr:
		if address.IsFqdn() {
			return 0, E.New("xray-local: a packet to a name, not an address: ", address.Fqdn)
		}
		return c.PacketConn.WriteTo(p, address.UDPAddr())
	default:
		destination := M.SocksaddrFromNet(addr)
		if !destination.IsIP() {
			return 0, E.New("xray-local: unknown packet address ", addr.String())
		}
		return c.PacketConn.WriteTo(p, destination.UDPAddr())
	}
}
