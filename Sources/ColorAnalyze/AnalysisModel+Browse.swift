import ColorCore
import Foundation

@MainActor
extension AnalysisModel {
    // MARK: Previous / next photo in the folder

    /// The photos next to the open one, in Finder order, and the position of the open one among them.
    private func folderPosition() -> (photos: [URL], index: Int)? {
        guard let url = image?.url else { return nil }
        let photos = ImageFolder.images(in: url.deletingLastPathComponent())
        guard let index = photos.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return nil }
        return (photos, index)
    }

    /// Opens the photo `offset` places further in the folder (-1 = previous, 1 = next). Unsaved changes are saved
    /// as the session first, so they are there when the photo is opened again.
    func stepPhoto(_ offset: Int) {
        guard !isAnalyzing, let (photos, index) = folderPosition() else { return }
        let target = index + offset
        guard photos.indices.contains(target) else {
            showNotice(offset < 0 ? "This is the first photo in the folder" : "This is the last photo in the folder")
            return
        }
        if isDirty { saveSession() }
        open(photos[target])
        showNotice("\(target + 1) / \(photos.count)  \(photos[target].lastPathComponent)")
    }
}
