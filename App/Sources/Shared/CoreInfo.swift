import Libbox

enum CoreInfo {
    static var version: String { LibboxVersion() }
    static var xrayVersion: String { PtbridgeXrayVersion() }
}
