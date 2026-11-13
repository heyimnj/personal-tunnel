//go:build tools

package ptbridge

// gomobile bind builds libbox from this module as well: its packages and
// gomobile's own must be among the module's dependencies (go.sum).
import (
	_ "github.com/sagernet/gomobile"
	_ "github.com/sagernet/sing-box/experimental/libbox"
)
