@testable import TunnelCore
import XCTest

/// 3.0.6: the extension's Russian lines are shown in the interface language.
final class TunnelTextTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized

    /// String literals of a Swift source, each interpolation as `%@`.
    private func literals(_ source: String) -> [String] {
        var result: [String] = []
        let characters = Array(source)
        var index = 0
        func skipLineComment() { while index < characters.count, characters[index] != "\n" { index += 1 } }
        while index < characters.count {
            let character = characters[index]
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" { skipLineComment(); continue }
            guard character == "\"" else { index += 1; continue }
            index += 1
            var text = ""
            while index < characters.count, characters[index] != "\"" {
                if characters[index] == "\\", index + 1 < characters.count {
                    if characters[index + 1] == "(" {
                        // An interpolation: skip to its closing parenthesis, strings inside included.
                        var depth = 0
                        index += 1
                        var inString = false
                        repeat {
                            let current = characters[index]
                            if current == "\"" { inString.toggle() }
                            if !inString { if current == "(" { depth += 1 } else if current == ")" { depth -= 1 } }
                            index += 1
                        } while depth > 0 && index < characters.count
                        text += "%@"
                        continue
                    }
                    text.append(characters[index + 1])
                    index += 2
                    continue
                }
                text.append(characters[index])
                index += 1
            }
            index += 1
            result.append(text)
        }
        return result
    }

    private func cyrillic(_ text: String) -> Bool { text.unicodeScalars.contains { (0x400 ... 0x4FF).contains($0.value) } }

    func testEveryRussianTextOfTheExtensionIsListed() throws {
        let folder = root.appendingPathComponent("PacketTunnel")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let listed = Set(TunnelText.all)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for text in literals(source) where cyrillic(text) {
                XCTAssertTrue(listed.contains(text), "\(file.lastPathComponent): «\(text)» is not in TunnelText")
            }
        }
    }

    func testEveryListedTextIsTranslated() throws {
        let strings = try String(contentsOf: root.appendingPathComponent("App/Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        for text in TunnelText.all {
            let key = "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\" ="
            XCTAssertTrue(strings.contains(key), "«\(text)» has no English translation")
        }
    }

    func testLinesAreTranslatedWhenShown() {
        let saved = (CoreText.translate, CoreText.russian)
        defer { CoreText.translate = saved.0; CoreText.russian = saved.1 }
        let english = [
            "остановка, причина %@": "stop, reason %@",
            "запуск не удался: %@": "start failed: %@",
            "Нет сохранённой конфигурации. Откройте Personal Tunnel и выберите сервер.": "No saved configuration.",
            "[mem] занято %@ МиБ, пик %@ МиБ, доступно %@ МиБ": "[mem] used %@ MiB, peak %@ MiB, available %@ MiB",
            "[mem] занято %@ МиБ, пик %@ МиБ": "[mem] used %@ MiB, peak %@ MiB",
            "SSH-агент недоступен": "SSH agent not available",
            "SSH недоступен": "SSH not available",
            "<адрес>": "<address>",
        ]
        CoreText.translate = { english[$0] ?? $0 }

        // A Russian interface keeps the lines as they are.
        CoreText.russian = true
        XCTAssertEqual(TunnelText.localize("2026-11-14T01:02:03Z остановка, причина 1"), "2026-11-14T01:02:03Z остановка, причина 1")

        CoreText.russian = false
        XCTAssertEqual(TunnelText.localize("2026-11-14T01:02:03Z остановка, причина 1"), "2026-11-14T01:02:03Z stop, reason 1")
        XCTAssertEqual(TunnelText.localize("(tunnel) запуск не удался: Нет сохранённой конфигурации. Откройте Personal Tunnel и выберите сервер."),
                       "(tunnel) start failed: No saved configuration.")
        XCTAssertEqual(TunnelText.localize("2026-11-14T01:02:03Z [mem] занято 34.9 МиБ, пик 35.9 МиБ, доступно 15.1 МиБ"),
                       "2026-11-14T01:02:03Z [mem] used 34.9 MiB, peak 35.9 MiB, available 15.1 MiB")
        XCTAssertEqual(TunnelText.localize("[mem] занято 34.9 МиБ, пик 35.9 МиБ"), "[mem] used 34.9 MiB, peak 35.9 MiB")
        XCTAssertEqual(TunnelText.localize("start service: SSH-агент недоступен; SSH недоступен"), "start service: SSH agent not available; SSH not available")
        XCTAssertEqual(TunnelText.localize("dial tcp <адрес>:443: i/o timeout"), "dial tcp <address>:443: i/o timeout")
        // The core's own English lines pass untouched.
        XCTAssertEqual(TunnelText.localize("outbound/vless[x]: EOF"), "outbound/vless[x]: EOF")
        // So does the memory line the app writes itself.
        XCTAssertEqual(MemorySample(used: 21.44, peak: 25, available: 0).line, "[mem] used 21.4 MiB, peak 25.0 MiB")
    }
}
