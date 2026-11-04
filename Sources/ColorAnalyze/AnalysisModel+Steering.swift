import ColorCore
import Foundation

@MainActor
extension AnalysisModel {
    // MARK: Steering toward the intention's contrasts

    /// The steering in use: when it is switched on and the intention asks for contrasts. The last result stays in use
    /// while a new one is being found, so the suggestion does not flicker.
    var activeSteering: ContrastSteering.Result? {
        steerByIntention && !contrastAims.isEmpty ? steering : nil
    }

    /// The style the grading uses: the one chosen for the intention, or the one chosen by hand.
    var effectiveStyle: GradingStyle { activeSteering?.option.style ?? gradingStyle }

    /// What the steering depends on: everything the suggestion depends on except the style, which it chooses, and the aims.
    var steeringRequestKey: Int? {
        let aims = contrastAims
        guard steerByIntention, !aims.isEmpty, let image else { return nil }
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(image.display))
        hasher.combine(markersKey)
        hasher.combine(harmonyChoice?.rawValue)
        hasher.combine(harmonyRotationOverride)
        hasher.combine(gradingAmount)
        hasher.combine(gradingTarget.rawValue)
        for (kind, aim) in aims.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            hasher.combine(kind.rawValue)
            hasher.combine(aim.aim.rawValue)
        }
        return hasher.finalize()
    }

    /// Tries every style with a few levels of HSL Saturation (and tone curves, for light–dark) and keeps the one whose predicted contrasts come
    /// closest to the intention's (see `ContrastSteering`). The gradings are found here; the contrasts in the background.
    func refreshSteering() async {
        guard let key = steeringRequestKey, key != steeringKey, let image else { return }
        let aims = contrastAims.mapValues(\.aim)
        var candidates: [ContrastSteering.Candidate] = []
        for style in GradingStyle.allCases {
            var setup = currentChoices
            setup.style = style
            guard let grading = computeColorGrading(for: setup) else { continue }
            candidates.append(.init(style: style, settings: gradeSettings(for: setup, grading: grading),
                                    hueFitAfter: grading.fit?.after))
        }
        let channels = Set(markers.map { DxOMapping.channel(for: $0.color) })
        let protected = Set(markers.filter { isProtected($0) }.map { DxOMapping.channel(for: $0.color) })
        let accent = accentChannel
        let lab = ContrastSteering.sample(image.analysis.lab)
        let result = await Task.detached(priority: .userInitiated) {
            ContrastSteering.choose(candidates: candidates, lab: lab, aims: aims,
                                    saturationPlans: ContrastSteering.saturationPlans(aims: aims, channels: channels,
                                                                                      protected: protected, accent: accent),
                                    tonePlans: ContrastSteering.tonePlans(aims: aims))
        }.value
        guard !Task.isCancelled, steeringRequestKey == key else { return }
        steering = result
        steeringKey = key
    }

    /// The HSL channel of the photo's accent: a color marked as accent, or else the small vivid patch of the contrast
    /// profile.
    var accentChannel: DxOChannel? {
        if let marker = markers.first(where: \.isAccent) { return DxOMapping.channel(for: marker.color) }
        guard let family = contrastProfile?.accent?.family else { return nil }
        let angle = Float((Double(family) + 0.5) * 30 * .pi / 180)
        return DxOMapping.channel(for: SRGBColor(oklab: SIMD3(0.7, 0.12 * cos(angle), 0.12 * sin(angle))).clamped)
    }

    /// The Light palette sliders of the suggestion, as they are to be set in PhotoLab (the style's Selective Tone plus what was
    /// chosen for the intention), leaving out those at 0.
    var lightPalette: [(name: String, value: Double)] {
        guard let settings = prediction()?.settings else { return [] }
        return [("Blacks", settings.toneBlacks), ("Shadows", settings.toneShadows), ("Midtones", settings.toneMidtones),
                ("Highlights", settings.toneHighlights), ("Whites", settings.toneWhites), ("Contrast", settings.contrast)]
            .filter { abs($0.1) >= 0.5 }
    }
}
