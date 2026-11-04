import ColorCore
import Foundation

@MainActor
extension AnalysisModel {
    // MARK: Contrast profile (Itten)

    /// What the intention asks of the contrasts (*dramatic*: light–dark high, …), with the words that ask.
    var contrastAims: [ContrastProfile.Kind: (aim: Intention.ContrastAim, words: [String])] {
        Intention.contrastAims(for: intention)
    }

    /// What the contrast profile depends on: the photo, and the graded version or the predicted grading.
    var contrastRequestKey: Int? {
        guard let image else { return nil }
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(image.display))
        if let afterImage {
            hasher.combine(ObjectIdentifier(afterImage.display))
        } else if isPreviewActive {
            hasher.combine(suggestionKey)
        }
        return hasher.finalize()
    }

    /// Measures the contrasts of the photo (once) and of the graded version or the prediction, in the background.
    func refreshContrastProfile() async {
        guard let key = contrastRequestKey, key != contrastKey, let image else { return }
        let before = contrastProfile
        let lab = image.analysis.lab
        let graded = afterImage?.analysis.lab
        let plan = afterImage == nil && isPreviewActive ? prediction()?.plan : nil
        let result = await Task.detached(priority: .userInitiated) {
            let photo = before ?? ContrastProfile(lab: lab)
            let after = graded.map { ContrastProfile(lab: $0) } ?? plan.map { plan in ContrastProfile(lab: lab.map { plan.apply($0) }) }
            return (photo, after)
        }.value
        guard !Task.isCancelled, contrastRequestKey == key else { return }
        contrastProfile = result.0
        afterContrastProfile = result.1
        contrastKey = key
    }
}
