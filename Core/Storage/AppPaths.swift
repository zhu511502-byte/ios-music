import Foundation

enum AppPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("LxPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var sourcesDirectory: URL {
        let url = root.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var pluginsDirectory: URL {
        let url = root.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var libraryFile: URL { root.appendingPathComponent("library.json") }
    static var sourcesFile: URL { root.appendingPathComponent("sources.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }
}
