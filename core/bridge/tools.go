//go:build tools

package ptbridge

// gomobile bind needs its own packages among the module's dependencies.
import _ "github.com/sagernet/gomobile"
