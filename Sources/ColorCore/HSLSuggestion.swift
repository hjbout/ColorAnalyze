import Foundation

/// Per channel of PhotoLab's HSL tool, how far its *Hue* handle should turn so the colors in that channel
/// reach their targets. Only hue is suggested: how much saturation or luminance a color needs is a matter of
/// taste that cannot be read from the photo, and the scale of those fields would be a guess.
public enum HSLSuggestion {
    public struct Input: Sendable {
        /// 1-based number of the color in the list.
        public var number: Int
        public var color: SRGBColor
        /// Share of the photo (0...1); colors that cover more count more.
        public var share: Double
        /// Hue shift the color should get, in sRGB degrees; nil when there is nothing to aim at.
        public var hueShift: Double?
        /// A color that must keep its hue: a handle turns its whole channel, so that channel is not turned at all.
        public var holds: Bool

        public init(number: Int, color: SRGBColor, share: Double, hueShift: Double?, holds: Bool = false) {
            self.number = number
            self.color = color
            self.share = share
            self.hueShift = hueShift
            self.holds = holds
        }
    }

    public struct Channel: Sendable, Equatable {
        public var channel: DxOChannel
        /// Share-weighted mean of the colors' shifts on DxO's ring, degrees; + = counter-clockwise.
        public var hueShift: Double
        /// Numbers of the colors that fall in this channel and were part of the mean.
        public var colors: [Int]
        /// Smallest and largest shift among those colors: far apart means one handle cannot serve them all.
        public var range: ClosedRange<Double>

        /// True when the colors of the channel want clearly different shifts.
        public var isMixed: Bool { range.upperBound - range.lowerBound > HSLSuggestion.mixedSpread }
    }

    /// Mean shifts below this many degrees are not worth a handle.
    public static let minimumShift = 2.0
    /// Colors in one channel whose shifts differ by more than this are reported as mixed.
    public static let mixedSpread = 20.0

    /// The channels that hold a color that must keep its hue.
    private static func heldChannels(in inputs: [Input]) -> Set<DxOChannel> {
        Set(inputs.filter(\.holds).map { DxOMapping.channel(for: $0.color) })
    }

    /// The channels that are not turned although a color in them wants to, because another color there must keep its hue,
    /// in the order of the HSL tool.
    public static func blockedChannels(from inputs: [Input]) -> [DxOChannel] {
        let held = heldChannels(in: inputs)
        let wanted = Set(inputs.filter { abs($0.hueShift ?? 0) >= minimumShift }.map { DxOMapping.channel(for: $0.color) })
        return DxOChannel.allCases.filter { $0 != .neutral && held.contains($0) && wanted.contains($0) }
    }

    /// One entry per channel with something to do, in the order of the HSL tool (red … magenta).
    /// Neutral colors belong to White Balance and Color Grading, not to HSL, and are left out.
    public static func channels(from inputs: [Input]) -> [Channel] {
        var groups: [DxOChannel: [(number: Int, share: Double, shift: Double)]] = [:]
        let held = heldChannels(in: inputs)
        for input in inputs {
            guard let shift = input.hueShift else { continue }
            let channel = DxOMapping.channel(for: input.color)
            guard channel != .neutral, !held.contains(channel) else { continue }
            guard let ring = DxOHue.ringShift(of: input.color, bySRGBShift: shift) else { continue }
            groups[channel, default: []].append((input.number, max(input.share, 1e-4), ring))
        }
        return DxOChannel.allCases.compactMap { channel in
            guard let members = groups[channel], !members.isEmpty else { return nil }
            let weight = members.reduce(0) { $0 + $1.share }
            let mean = members.reduce(0) { $0 + $1.share * $1.shift } / weight
            guard abs(mean) >= minimumShift else { return nil }
            let shifts = members.map(\.shift)
            return Channel(channel: channel, hueShift: mean, colors: members.map(\.number).sorted(),
                           range: shifts.min()!...shifts.max()!)
        }
    }
}
