import ColorCore
import Foundation

@MainActor
extension AnalysisModel {
    // MARK: Contrast profile (Itten)

    /// What the intention asks of the contrasts (*dramatic*: light–dark high, …), with the words that ask.
    var contrastAims: [ContrastProfile.Kind: (aim: Intention.ContrastAim, words: [String])] {
        let text = intention
        if let cache = contrastAimsCache, cache.text == text { return cache.aims }
        let aims = Intention.contrastAims(for: text)
        contrastAimsCache = (text, aims)
        return aims
    }

    /// Waits for a drag to come to rest; false when a newer request replaced this one in the meantime. For the measurements
    /// of a whole photo that run from a `.task(id:)`: their background work cannot be stopped once it has started, so without
    /// this every step of a drag would start one more of each.
    func settled() async -> Bool {
        try? await Task.sleep(for: .milliseconds(120))
        return !Task.isCancelled
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

    // MARK: Tone check

    /// Measures clipping, black and white point of the photo (once) and of the graded version or the prediction, from every
    /// other pixel of the sampling copy (small clipped areas get lost in the analysis copy).
    func refreshToneCheck() async {
        guard let key = contrastRequestKey, key != toneKey, let image else { return }
        let before = toneCheck
        let source = image.sampling
        let graded = afterImage?.sampling
        let plan = afterImage == nil && isPreviewActive ? prediction()?.plan : nil
        let result = await Task.detached(priority: .userInitiated) {
            let photo = before ?? ToneCheck.check(source)
            var after: ToneCheck?
            if let graded {
                after = ToneCheck.check(graded)
            } else if let plan {
                after = ToneCheck.check(source) { plan.applyLinear(linear: $0, lab: $1) }
            }
            return (photo, after)
        }.value
        guard !Task.isCancelled, contrastRequestKey == key else { return }
        toneCheck = result.0
        afterToneCheck = result.1
        toneKey = key
    }

    /// True when the intention asks for soft tones (a low light–dark contrast): a lifted black is then no fault.
    var wantsSoftTones: Bool { contrastAims[.lightDark]?.aim == .low }

    /// The tone check's verdict for this photo and intention; unknown until it has run.
    var toneVerdict: ToneCheck.Verdict { toneCheck?.verdict(softTones: wantsSoftTones) ?? .unknown }
}
