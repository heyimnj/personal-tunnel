import CoreText
import SwiftUI
import UIKit

/// Imported TTF / OTF fonts. A font is created straight from its file, not
/// looked up by name: a file may carry the name of a system font, which a
/// name lookup would resolve to the system font instead.
enum FontLibrary {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fonts", isDirectory: true)
    }

    private static var descriptors: [String: CTFontDescriptor] = [:]

    enum ImportError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            L("Файл не похож на шрифт TTF или OTF.")
        }
    }

    /// Copies a font file into the library and returns its stored name.
    static func importFont(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        let name = UUID().uuidString.prefix(8) + "-" + source.lastPathComponent
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(String(name))
        try data.write(to: target, options: .atomic)
        guard descriptor(for: String(name)) != nil else {
            try? FileManager.default.removeItem(at: target)
            throw ImportError.unreadable
        }
        return String(name)
    }

    static func store(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        descriptors[name] = nil
    }

    static func files() -> [String: Data] {
        var result: [String: Data] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            result[url.lastPathComponent] = try? Data(contentsOf: url)
        }
        return result
    }

    static func descriptor(for name: String) -> CTFontDescriptor? {
        if let cached = descriptors[name] { return cached }
        let url = directory.appendingPathComponent(name) as CFURL
        guard let list = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], let first = list.first else {
            return nil
        }
        descriptors[name] = first
        return first
    }

    static func displayName(for name: String) -> String? {
        guard let descriptor = descriptor(for: name) else { return nil }
        let font = CTFontCreateWithFontDescriptor(descriptor, 17, nil)
        return CTFontCopyDisplayName(font) as String
    }

    static func uiFont(_ name: String, size: CGFloat) -> UIFont? {
        guard !name.isEmpty, let descriptor = descriptor(for: name) else { return nil }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return font as UIFont
    }

    /// Navigation bar and tab bar text, which SwiftUI fonts do not reach.
    static func applyAppearance(_ settings: AppSettings) {
        let name = settings.fontFile
        let largeSize = UIFont.preferredFont(forTextStyle: .largeTitle).pointSize
        let titleSize = UIFont.preferredFont(forTextStyle: .headline).pointSize
        let tabSize = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        let navigation = UINavigationBar.appearance()
        if let large = uiFont(name, size: largeSize), let title = uiFont(name, size: titleSize) {
            navigation.largeTitleTextAttributes = [.font: large]
            navigation.titleTextAttributes = [.font: title]
        } else if settings.appearance == .material {
            navigation.largeTitleTextAttributes = [.font: UIFont.rounded(size: largeSize, weight: .bold)]
            navigation.titleTextAttributes = [.font: UIFont.rounded(size: titleSize, weight: .semibold)]
        } else {
            navigation.largeTitleTextAttributes = nil
            navigation.titleTextAttributes = nil
        }
        let tab = UITabBarItem.appearance()
        if let font = uiFont(name, size: tabSize) {
            tab.setTitleTextAttributes([.font: font], for: .normal)
        } else {
            tab.setTitleTextAttributes(nil, for: .normal)
        }
    }
}

extension UIFont {
    static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// The interface font for a text style: the imported font when one is set,
/// SF Rounded in Material You, the system font otherwise. Follows Dynamic Type.
func appFont(_ style: Font.TextStyle, weight: Font.Weight = .regular, monospacedDigits: Bool = false) -> Font {
    let settings = AppSettings.shared
    if !settings.fontFile.isEmpty {
        let size = UIFont.preferredFont(forTextStyle: style.uiTextStyle).pointSize
        if let font = FontLibrary.uiFont(settings.fontFile, size: size) {
            var result = Font(font as CTFont)
            if weight == .semibold || weight == .bold || weight == .heavy || weight == .black { result = result.bold() }
            return monospacedDigits ? result.monospacedDigit() : result
        }
    }
    var font = Font.system(style, design: settings.appearance == .material ? .rounded : .default).weight(weight)
    if monospacedDigits { font = font.monospacedDigit() }
    return font
}

extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}
