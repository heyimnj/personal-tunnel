import Foundation

/// Lines of the core's log as people read them: sing-box colours its lines with
/// terminal codes (`ESC[31mERROR ESC[0m[0031] [ESC[38;5;134m26394ESC[0m 15.12s] …`);
/// the escape character itself is often already gone, leaving `[31m` behind.
public enum LogText {
    private static let colour = try! NSRegularExpression(pattern: #"\u001B\[[0-9;]*m|\[[0-9][0-9;]*m"#)
    private static let level = try! NSRegularExpression(pattern: #"^(PANIC|FATAL|ERROR|WARN|INFO|DEBUG|TRACE)\s*"#)

    /// Colour codes removed, and the level word the screen shows separately.
    public static func clean(_ text: String) -> String {
        var result = colour.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        result = level.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
