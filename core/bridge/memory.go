package ptbridge

import "runtime/debug"

// SetGCPercent sets how much the Go heap may grow between collections. The
// extension passes its own memory limit to the core, and then the core leaves
// this at Go's default of 100 (it lowers it to 50 only when it picks the limit
// itself): a burst of traffic could double the heap before a collection, on a
// process the system ends at about 50 MiB. Returns the previous setting.
func SetGCPercent(percent int) int {
	return debug.SetGCPercent(percent)
}

// FreeMemory collects garbage and returns free memory to the system at once,
// for when the extension is close to its limit.
func FreeMemory() {
	debug.FreeOSMemory()
}
