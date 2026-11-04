import Foundation

extension GradePreviewSettings {
    /// Where these settings leave what was measured in PhotoLab (see `calibration/`): each entry names a part of the
    /// preview that is extrapolated or only roughly fitted, so the preview is less exact there. Empty = everything is
    /// inside the measured range. The tints count with `amount`, the way the preview applies them.
    public var modelCaveats: [String] {
        var notes: [String] = []
        let wheels = [shadows, midtones, highlights, master]

        let strongest = wheels.map { abs($0.saturation) * amount }.max() ?? 0
        if strongest > 100.5 {
            notes.append("A tint of Saturation \(Int(strongest.rounded())) is beyond the 0–100 that was measured, so the preview extrapolates.")
        }
        if master.saturation != 0 {
            notes.append("The Master wheel is measured per hue and a little less exact (error up to about 2 against an effect of 6–11).")
        }
        if wheels.contains(where: { $0.luminance != 0 }) && balance != 0 {
            notes.append("Luminance together with Balance was not measured.")
        }
        if abs(balance) > 60 {
            notes.append("Balance beyond ±60 is extrapolated (measured at ±59).")
        }
        if let widest = hueShifts.values.map({ abs($0) }).max(), widest > 30 {
            notes.append("An HSL hue turn of \(Int(widest.rounded()))° is larger than the ±29° that was measured.")
        }
        if hslLuminance.values.contains(where: { abs($0) > 0.01 }) {
            notes.append("HSL Luminance is only a rough fit (error about 4 against an effect of 11).")
        }
        if hslSaturation.values.contains(where: { abs($0) > 80 }) {
            notes.append("HSL Saturation beyond ±80 is extrapolated.")
        }
        if toneBlacks < 0 || toneShadows < 0 {
            notes.append("Crushing the blacks or shadows is less exact (error 2–4 against an effect of 16–20).")
        }
        return notes
    }
}
