import Foundation

enum DxOLocations {
    /// The folder PhotoLab reads Color Grading presets from (`~/Library/DxO PhotoLab v10/ColorGradingPresets`),
    /// for the newest PhotoLab version that has one; nil when PhotoLab never created it.
    static func colorGradingPresetsFolder() -> URL? {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: library.path) else { return nil }
        let prefix = "DxO PhotoLab v"
        let candidates = names.compactMap { name -> (version: Int, url: URL)? in
            guard name.hasPrefix(prefix), let version = Int(name.dropFirst(prefix.count)) else { return nil }
            let url = library.appendingPathComponent(name).appendingPathComponent("ColorGradingPresets", isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? (version, url) : nil
        }
        return candidates.max { $0.version < $1.version }?.url
    }
}
