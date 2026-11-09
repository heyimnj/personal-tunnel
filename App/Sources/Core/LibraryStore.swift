import Foundation
import TunnelKit

/// Persists the server library and the network options in the App Group.
enum LibraryStore {
    private static let optionsKey = "tunnel.options"

    static func loadLibrary() -> ServerLibrary? {
        guard let data = try? Data(contentsOf: SharedContainer.libraryURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServerLibrary.self, from: data)
    }

    static func save(_ library: ServerLibrary) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(library) else { return }
        // The previous file survives a write that goes wrong.
        let url = SharedContainer.libraryURL
        if let previous = try? Data(contentsOf: url), !previous.isEmpty {
            try? SharedContainer.write(previous, to: url.appendingPathExtension("previous"), excludedFromBackup: true)
        }
        try? SharedContainer.write(data, to: url, excludedFromBackup: excludesFromBackup)
    }

    /// Library from the previous good write, when the current file is damaged.
    static func loadPreviousLibrary() -> ServerLibrary? {
        let url = SharedContainer.libraryURL.appendingPathExtension("previous")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServerLibrary.self, from: data)
    }

    static func loadOptions() -> TunnelOptions {
        guard let data = SharedContainer.defaults.data(forKey: optionsKey),
              let options = try? JSONDecoder().decode(TunnelOptions.self, from: data)
        else { return TunnelOptions() }
        return options
    }

    static func save(_ options: TunnelOptions) {
        if let data = try? JSONEncoder().encode(options) {
            SharedContainer.defaults.set(data, forKey: optionsKey)
        }
    }

    /// Subscription links and server keys stay out of iPhone / iCloud backups
    /// unless the user turns this off.
    static var excludesFromBackup: Bool {
        SharedContainer.defaults.object(forKey: SharedKey.excludeFromDeviceBackup) as? Bool ?? true
    }

    static func applyBackupExclusion() {
        for url in [SharedContainer.libraryURL, SharedContainer.activeConfigurationURL] {
            var mutable = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = excludesFromBackup
            try? mutable.setResourceValues(values)
        }
    }
}
