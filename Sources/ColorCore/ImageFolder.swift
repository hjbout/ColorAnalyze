import Foundation
import UniformTypeIdentifiers

/// Photos in a folder, for analyzing a whole shoot at once.
public enum ImageFolder {
    /// True for files whose type is an image — JPEG, PNG, HEIC, TIFF and camera RAW alike. Judged by the
    /// file extension, so sidecars (`.dop`, `.xmp`, `.json`) are not photos.
    public static func isImage(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// The photos directly in `folder` (subfolders are not searched), sorted the way Finder sorts
    /// names: IMG_2 before IMG_10. Hidden files and packages are skipped.
    public static func images(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        return contents
            .filter { url in
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return !isFolder && isImage(url)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Replaces every folder in `urls` by its photos, keeping the order and dropping duplicates.
    /// Files are passed on as they are.
    public static func expand(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            for photo in isFolder ? images(in: url) : [url] where seen.insert(photo.standardizedFileURL).inserted {
                result.append(photo)
            }
        }
        return result
    }
}
