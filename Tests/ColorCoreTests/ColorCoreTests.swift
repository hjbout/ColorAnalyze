import CoreGraphics
import Foundation
import Testing
@testable import ColorCore

@Suite struct ColorSpaceTests {
    @Test func okLabRoundTrip() {
        for color in [SRGBColor(r: 0.9, g: 0.2, b: 0.1), SRGBColor(r: 0.1, g: 0.5, b: 0.8), SRGBColor(r: 0.5, g: 0.5, b: 0.5)] {
            let back = SRGBColor(oklab: color.oklab)
            #expect(abs(back.r - color.r) < 1e-3)
            #expect(abs(back.g - color.g) < 1e-3)
            #expect(abs(back.b - color.b) < 1e-3)
        }
    }

    @Test func whiteIsLightnessOne() {
        let white = SRGBColor(r: 1, g: 1, b: 1)
        #expect(abs(white.oklab.x - 1) < 1e-3)
        #expect(white.chroma < 1e-3)
        #expect(abs(white.lightness - 100) < 0.1)
    }

    @Test func hsbAndHexAgree() {
        let orange = SRGBColor.fromHSB(h: 30, s: 1, b: 1)
        #expect(orange.hex == "#FF8000")
        #expect(abs(orange.hsb.h - 30) < 0.5)
        #expect(abs(orange.hsl.l - 0.5) < 1e-6)
    }
}

@Suite struct AnalyzerTests {
    /// 100×100 image: left 60% red, then 30% blue, then 10% yellow.
    static let blocks: PixelBuffer = {
        let colors = [SRGBColor(r: 0.85, g: 0.15, b: 0.1), SRGBColor(r: 0.1, g: 0.3, b: 0.8), SRGBColor(r: 0.95, g: 0.85, b: 0.2)]
        var linear: [SIMD3<Float>] = []
        for _ in 0..<100 {
            for x in 0..<100 {
                linear.append(colors[x < 60 ? 0 : x < 90 ? 1 : 2].linear)
            }
        }
        return PixelBuffer(width: 100, height: 100, linear: linear)
    }()

    @Test func findsBlockColorsSharesAndLocations() {
        let result = DominantColorAnalyzer.analyze(Self.blocks, count: 3)
        #expect(result.count == 3)
        let expected: [(share: Double, xRange: ClosedRange<Double>, color: SRGBColor)] = [
            (0.6, 0...0.6, SRGBColor(r: 0.85, g: 0.15, b: 0.1)),
            (0.3, 0.6...0.9, SRGBColor(r: 0.1, g: 0.3, b: 0.8)),
            (0.1, 0.9...1, SRGBColor(r: 0.95, g: 0.85, b: 0.2)),
        ]
        for (found, exp) in zip(result, expected) {
            #expect(abs(found.share - exp.share) < 0.01)
            #expect(exp.xRange.contains(found.location.x))
            #expect(ColorMath.distanceSquared(found.centroid, exp.color.oklab) < 1e-4)
        }
    }

    @Test func sharesSumToOne() {
        let colors = [SRGBColor(r: 0.85, g: 0.15, b: 0.1).oklab, SRGBColor(r: 0.1, g: 0.3, b: 0.8).oklab]
        let shares = DominantColorAnalyzer.shares(of: colors, in: Self.blocks)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        // The yellow block is nearer to red than to blue.
        #expect(abs(shares[0] - 0.7) < 1e-9)
    }

    @Test func regionMaskMatchesCoverage() throws {
        let colors = [SRGBColor(r: 0.85, g: 0.15, b: 0.1).oklab, SRGBColor(r: 0.1, g: 0.3, b: 0.8).oklab]
        let mask = RegionMask(colorAt: 1, of: colors, in: Self.blocks)
        let shares = DominantColorAnalyzer.shares(of: colors, in: Self.blocks)
        #expect(abs(mask.coverage - shares[1]) < 1e-9)
        #expect(mask.inside[50 * 100 + 70])   // blue block
        #expect(!mask.inside[50 * 100 + 10])  // red block
        let image = try #require(mask.overlayImage())
        #expect(image.width == 100 && image.height == 100)
    }

    @Test func regionMaskOutOfRangeIsEmpty() {
        let mask = RegionMask(colorAt: 5, of: [], in: Self.blocks)
        #expect(mask.coverage == 0)
    }

    @Test func sampleAveragesNeighborhood() {
        let c = Self.blocks.sample(at: CGPoint(x: 0.3, y: 0.5), radius: 0.05)
        #expect(abs(c.r - 0.85) < 0.002 && abs(c.g - 0.15) < 0.002 && abs(c.b - 0.1) < 0.002)
    }
}

@Suite struct DxOMappingTests {
    @Test func channels() {
        #expect(DxOMapping.channel(for: .fromHSB(h: 25, s: 0.8, b: 0.9)) == .orange)
        #expect(DxOMapping.channel(for: .fromHSB(h: 180, s: 0.8, b: 0.9)) == .cyan)
        #expect(DxOMapping.channel(for: .fromHSB(h: 350, s: 0.8, b: 0.9)) == .red)
        #expect(DxOMapping.channel(for: SRGBColor(r: 0.5, g: 0.5, b: 0.5)) == .neutral)
    }

    @Test func tonalRanges() {
        #expect(DxOMapping.tonalRange(lightness: 20) == .shadows)
        #expect(DxOMapping.tonalRange(lightness: 50) == .midtones)
        #expect(DxOMapping.tonalRange(lightness: 80) == .highlights)
    }
}

@Suite struct HarmonyTests {
    @Test func detectsComplementary() {
        let fit = HarmonyDetector.detect([HarmonyInput(hue: 30, weight: 1), HarmonyInput(hue: 210, weight: 1)])
        #expect(fit?.kind == .complementary)
        #expect((fit?.deviation ?? 99) < 1)
    }

    @Test func detectsTriadic() {
        let fit = HarmonyDetector.detect([0, 120, 240].map { HarmonyInput(hue: $0, weight: 1) })
        #expect(fit?.kind == .triadic)
    }

    @Test func detectsTetradic() {
        // Two complementary pairs 60° apart: a rectangle, which a square (90°) fits worse.
        let fit = HarmonyDetector.detect([20, 80, 200, 260].map { HarmonyInput(hue: $0, weight: 1) })
        #expect(fit?.kind == .tetradic)
        #expect((fit?.deviation ?? 99) < 1)
        #expect(HarmonyKind.tetradic.offsets == [0, 60, 180, 240])
    }

    @Test func detectsAnalogousWithAnAccent() {
        // Warm neighbours with one cool complement: more than analogous, less than a full complementary pair.
        let inputs = [(15.0, 1.0), (45.0, 2.0), (75.0, 1.0), (225.0, 0.6)].map { HarmonyInput(hue: $0.0, weight: $0.1) }
        let fit = HarmonyDetector.detect(inputs)
        #expect(fit?.kind == .analogousAccent)
        #expect(Set(HarmonyKind.allCases.map(\.rawValue)).count == HarmonyKind.allCases.count)
        #expect(HarmonyKind.analogousAccent.offsets == [-30, 0, 30, 180])
    }

    @Test func detectsMonochromatic() {
        let fit = HarmonyDetector.detect([20, 28, 35].map { HarmonyInput(hue: $0, weight: 1) })
        #expect(fit?.kind == .monochromatic)
    }

    @Test func shiftIsSignedTowardNearestTarget() {
        let fit = HarmonyFit(kind: .complementary, rotation: 30, deviation: 0)
        #expect(fit.shift(for: 22) == 8)
        #expect(fit.shift(for: 220) == -10)
        #expect(fit.shift(for: 355) == 35)
    }

    @Test func neutralsAreIgnored() {
        #expect(HarmonyDetector.detect([HarmonyInput(hue: 10, weight: 0)]) == nil)
    }
}

@Suite struct SessionTests {
    static func sample() -> Session {
        Session(savedAt: Date(timeIntervalSince1970: 1_800_000_000), photo: "IMG_1.CR3",
                graded: "/tmp/IMG_1-graded.jpg", colorCount: 5,
                markers: [.init(x: 0.25, y: 0.5, hex: "#B791E3"), .init(x: 0.9, y: 0.1, hex: "#7787FF")],
                harmony: HarmonyKind.triadic.rawValue, harmonyRotation: 42,
                compareMode: "Split", splitPosition: 0.35)
    }

    @Test func sidecarSitsNextToPhoto() {
        let url = Session.sidecarURL(for: URL(fileURLWithPath: "/photos/IMG_1.CR3"))
        #expect(url.path == "/photos/IMG_1.CR3.coloranalyze.json")
    }

    @Test func roundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.sample().write(to: file)
        #expect(try Session.read(from: file) == Self.sample())
    }

    @Test func rejectsNewerFormat() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var session = Self.sample()
        session.version = Session.currentVersion + 1
        try session.write(to: file)
        #expect(throws: Session.SessionError.self) { try Session.read(from: file) }
    }

    @Test func missingOptionalFieldsDecode() throws {
        let json = #"{"version":1,"savedAt":"2026-10-10T10:00:00Z","photo":"a.jpg","colorCount":6,"markers":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        #expect(session.graded == nil && session.harmony == nil && session.markers.isEmpty)
    }

    @Test func theReferencePhotoSurvivesASaveAndFallsBackToTheFolder() throws {
        var session = Self.sample()
        session.reference = "/looks/sunset.jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString).coloranalyze.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try session.write(to: url)
        let back = try Session.read(from: url)
        #expect(back.reference == "/looks/sunset.jpg")

        let folder = URL(fileURLWithPath: "/new/place")
        #expect(back.referenceURL(photoFolder: folder) { $0.path == "/looks/sunset.jpg" }?.path == "/looks/sunset.jpg")
        #expect(back.referenceURL(photoFolder: folder) { $0.path == "/new/place/sunset.jpg" }?.path == "/new/place/sunset.jpg")
        #expect(back.referenceURL(photoFolder: folder) { _ in false } == nil)
        #expect(Self.sample().referenceURL(photoFolder: folder) { _ in true } == nil)   // no reference saved
    }

    @Test func sessionsFromBeforeReferencePhotosStillLoad() throws {
        let json = """
        {"version":1,"savedAt":"2026-01-01T00:00:00Z","photo":"a.jpg","colorCount":6,"markers":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        #expect(session.reference == nil && session.colorCount == 6)
    }

    @Test func gradedFallsBackToPhotoFolder() {
        let session = Self.sample()
        let folder = URL(fileURLWithPath: "/new/place")
        // Saved path is gone, but the file sits next to the photo now.
        let found = session.gradedURL(photoFolder: folder) { $0.path == "/new/place/IMG_1-graded.jpg" }
        #expect(found?.path == "/new/place/IMG_1-graded.jpg")
        #expect(session.gradedURL(photoFolder: folder) { _ in false } == nil)
    }
}

@Suite struct ColorExportTests {
    static let purple = SRGBColor(r: 183 / 255, g: 145 / 255, b: 227 / 255)
    static let afterPurple = SRGBColor.fromHSB(h: 291, s: 0.4, b: 0.9)

    static func record(after: SRGBColor? = nil, harmony: HarmonyFit? = nil) -> ColorRecord {
        ColorRecord(number: 1, location: CGPoint(x: 0.25, y: 0.5), color: purple, share: 0.1534,
                    after: after, harmony: harmony)
    }

    @Test func recordHoldsDisplayedValues() {
        let r = Self.record()
        #expect(r.hex == "#B791E3")
        #expect((r.red, r.green, r.blue) == (183, 145, 227))
        #expect(r.coveragePercent == 15.34)
        #expect(r.dxoChannel == "Purple")
        #expect(r.tonalRange == "Highlights")
        #expect(r.harmonyShift == nil && r.after == nil)
    }

    @Test func harmonyShiftPointsAtNearestTarget() {
        let fit = HarmonyFit(kind: .complementary, rotation: 258, deviation: 0)
        let r = Self.record(harmony: fit)
        #expect(r.harmonyShift == -9.8)      // 267.8° → 258°
        #expect(r.harmonyTargetHue == 258)
    }

    @Test func neutralColorHasNoHarmonyOrHueChange() {
        let grey = SRGBColor(r: 0.5, g: 0.5, b: 0.5)
        let fit = HarmonyFit(kind: .complementary, rotation: 0, deviation: 0)
        let r = ColorRecord(number: 2, location: .zero, color: grey, share: 0.5, after: grey, harmony: fit)
        #expect(r.dxoChannel == "Neutral")
        #expect(r.harmonyShift == nil)
        #expect(r.after?.hueChange == nil)
    }

    @Test func afterDeltas() {
        let r = Self.record(after: Self.afterPurple)
        #expect(r.after?.hex == Self.afterPurple.hex)
        #expect(r.after?.hueChange == 23.2)  // 267.8° → 291°
    }

    @Test func csvOmitsAfterColumnsWithoutGradedVersion() {
        let csv = ColorExport(photo: "a.jpg", colors: [Self.record()]).csv()
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 3 && lines[2].isEmpty)
        #expect(lines[0].hasPrefix("number,hex,red,green,blue,hue,"))
        #expect(!lines[0].contains("after_"))
        #expect(lines[1] == "1,#B791E3,183,145,227,267.8,59.4,72.9,66.4,15.34,0.25,0.5,Purple,Highlights,,")
        #expect(lines[0].split(separator: ",").count == lines[1].components(separatedBy: ",").count)
    }

    @Test func csvKeepsRowsAlignedWithAfterColumns() {
        let export = ColorExport(photo: "a.jpg", colors: [Self.record(after: Self.afterPurple), Self.record()])
        let lines = export.csv().components(separatedBy: "\r\n")
        let columns = lines[0].components(separatedBy: ",").count
        #expect(lines[0].hasSuffix("after_harmony_shift"))
        #expect(lines[1].components(separatedBy: ",").count == columns)
        #expect(lines[2].components(separatedBy: ",").count == columns) // blank after cells
    }

    @Test func csvQuotesSpecialCharacters() {
        #expect(ColorExport.field("plain") == "plain")
        #expect(ColorExport.field("a,b") == "\"a,b\"")
        #expect(ColorExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(ColorExport.num(12.5) == "12.5" && ColorExport.num(3) == "3" && ColorExport.num(-0.00001) == "0")
        #expect(ColorExport.num(nil) == "")
    }

    @Test func dutchExcelStyleUsesSemicolonAndDecimalComma() {
        let export = ColorExport(photo: "a.jpg", colors: [Self.record(after: Self.afterPurple)])
        let lines = export.csv(style: .europeanExcel).components(separatedBy: "\r\n")
        #expect(lines[0].hasPrefix("number;hex;red;green;blue;hue;"))
        #expect(!lines[0].contains(","))
        #expect(lines[1].hasPrefix("1;#B791E3;183;145;227;267,8;59,4;72,9;66,4;15,34;0,25;0,5;Purple;Highlights;;"))
        // Same shape as the standard variant, only the separators differ.
        let standard = export.csv().components(separatedBy: "\r\n")
        #expect(lines[1].components(separatedBy: ";").count == standard[1].components(separatedBy: ",").count)
        #expect(lines[1].replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: ";", with: ",") == standard[1])
    }

    @Test func fieldsAreQuotedForTheActiveDelimiter() {
        #expect(ColorExport.field("a;b", delimiter: ";") == "\"a;b\"")
        #expect(ColorExport.field("a,b", delimiter: ";") == "a,b")
        #expect(ColorExport.num(267.8, decimalSeparator: ",") == "267,8")
        #expect(ColorExport.num(-0.00001, decimalSeparator: ",") == "0")
        #expect(ColorExport.num(nil, decimalSeparator: ",") == "")
    }

    @Test func jsonRoundTrips() throws {
        let fit = HarmonyFit(kind: .triadic, rotation: 40, deviation: 12.34)
        let export = ColorExport(
            photo: "a.jpg", graded: "/x/b.jpg", exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            harmony: .init(fit: fit, autoDetected: true, fitAfter: nil),
            colors: [Self.record(after: Self.afterPurple, harmony: fit)])
        let data = try export.json()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ColorExport.self, from: data) == export)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"graded\" : \"/x/b.jpg\""))   // slashes not escaped
        #expect(text.contains("\"targetHues\""))
    }
}

@Suite struct WeightedAnalysisTests {
    /// 100×100: left half red, right half blue.
    static let halves: PixelBuffer = {
        let red = SRGBColor(r: 0.85, g: 0.15, b: 0.1).linear, blue = SRGBColor(r: 0.1, g: 0.3, b: 0.8).linear
        var linear: [SIMD3<Float>] = []
        for _ in 0..<100 { for x in 0..<100 { linear.append(x < 50 ? red : blue) } }
        return PixelBuffer(width: 100, height: 100, linear: linear)
    }()

    /// Weight 1 on the left half, 9 on the right half (the "subject").
    static let rightHeavy: [Float] = (0..<10_000).map { ($0 % 100) < 50 ? 1 : 9 }

    @Test func unweightedMatchesPixelCounts() {
        let plain = DominantColorAnalyzer.analyze(Self.halves, count: 2)
        let ones = DominantColorAnalyzer.analyze(Self.halves, count: 2, weights: [Float](repeating: 1, count: 10_000))
        #expect(plain.map(\.share) == ones.map(\.share))
        #expect(plain.allSatisfy { abs($0.share - 0.5) < 1e-9 })
    }

    @Test func weightsShiftSharesTowardTheSubject() {
        let result = DominantColorAnalyzer.analyze(Self.halves, count: 2, weights: Self.rightHeavy)
        #expect(result.count == 2)
        #expect(abs(result[0].share - 0.9) < 1e-6)          // blue is the heavy half and sorts first
        #expect(result[0].location.x > 0.5)
        #expect(abs(result[1].share - 0.1) < 1e-6)
    }

    @Test func weightedSharesSumToOne() {
        let colors = [SRGBColor(r: 0.85, g: 0.15, b: 0.1).oklab, SRGBColor(r: 0.1, g: 0.3, b: 0.8).oklab]
        let shares = DominantColorAnalyzer.shares(of: colors, in: Self.halves, weights: Self.rightHeavy)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        #expect(abs(shares[1] - 0.9) < 1e-9)
    }

    @Test func markerLandsOnTheSalientPartOfASingleColor() {
        // One flat color everywhere; only the weights say where the subject is.
        let green = SRGBColor(r: 0.2, g: 0.6, b: 0.2).linear
        let buffer = PixelBuffer(width: 100, height: 100, linear: [SIMD3<Float>](repeating: green, count: 10_000))
        let right = DominantColorAnalyzer.analyze(buffer, count: 1, weights: Self.rightHeavy)[0].location
        let left = DominantColorAnalyzer.analyze(buffer, count: 1, weights: Self.rightHeavy.map { $0 > 1 ? 1 : 9 })[0].location
        #expect(right.x > 0.5 && left.x < 0.5)
    }

    @Test func weightsFromSaliency() {
        #expect(Saliency.weights(for: [0, 0.5, 1], strength: 4) == [1, 3, 5])
    }

    @Test func resampleIsBilinearAndNormalized() {
        let out = Saliency.resample(grid: [0, 0.5, 0, 0.5], gridWidth: 2, gridHeight: 2, width: 4, height: 4)
        #expect(out.count == 16 && out.max() == 1 && out.min() == 0)
        #expect(out[0] < out[3])                            // grows toward the brighter column
        #expect(Saliency.resample(grid: [0, 0], gridWidth: 2, gridHeight: 1, width: 3, height: 3) == [Float](repeating: 0, count: 9))
        #expect(Saliency.resample(grid: [], gridWidth: 0, gridHeight: 0, width: 2, height: 2) == [0, 0, 0, 0])
    }

    @Test func spotlightDarkensOnlyTheBackground() throws {
        let image = try #require(Saliency.spotlightImage(map: [1, 0], width: 2, height: 1))
        #expect(image.width == 2 && image.height == 1)
    }
}

@Suite struct VisionSaliencyTests {
    /// Flat grey photo with one bright, saturated square in the top-left corner.
    static func photo() -> CGImage {
        let size = 256
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.36, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 256 - 100, width: 70, height: 70)) // CG origin is bottom-left
        return ctx.makeImage()!
    }

    @Test func attentionMapPeaksOnTheObjectInTopLeft() throws {
        let map = try Saliency.attentionMap(for: Self.photo(), width: 64, height: 64)
        #expect(map.count == 64 * 64)
        #expect(map.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(map.max() == 1)
        let object = map[16 * 64 + 16]       // inside the square (≈ x 30–100 → 7–25, y 30–100 → 7–25)
        let corner = map[60 * 64 + 60]       // bottom-right, plain background
        #expect(object > corner)
    }
}

@Suite struct WeightingExportTests {
    @Test func csvAddsAreaColumnOnlyWhenWeighted() {
        let color = SRGBColor(r: 0.2, g: 0.6, b: 0.2)
        let plain = ColorRecord(number: 1, location: .zero, color: color, share: 0.5)
        let weighted = ColorRecord(number: 1, location: .zero, color: color, share: 0.8, areaShare: 0.5)
        let off = ColorExport(photo: "a.jpg", colors: [plain]).csv().components(separatedBy: "\r\n")
        let on = ColorExport(photo: "a.jpg", weighting: "moderate", colors: [weighted]).csv().components(separatedBy: "\r\n")
        #expect(!off[0].contains("area_pct"))
        #expect(on[0].contains("coverage_pct,area_pct,x,y"))
        #expect(on[1].contains(",80,50,0,0,"))                       // coverage 80 %, area 50 %, then x and y
        #expect(on[0].components(separatedBy: ",").count == off[0].components(separatedBy: ",").count + 1)
        #expect(on[1].components(separatedBy: ",").count == on[0].components(separatedBy: ",").count)
    }

    @Test func jsonCarriesWeighting() throws {
        let color = SRGBColor(r: 0.2, g: 0.6, b: 0.2)
        let export = ColorExport(photo: "a.jpg", weighting: "strong",
                                 colors: [ColorRecord(number: 1, location: .zero, color: color, share: 0.8, areaShare: 0.5)])
        let text = String(decoding: try export.json(), as: UTF8.self)
        #expect(text.contains("\"weighting\" : \"strong\"") && text.contains("\"areaPercent\" : 50"))
        let off = String(decoding: try ColorExport(photo: "a.jpg", colors: []).json(), as: UTF8.self)
        #expect(!off.contains("weighting"))
    }

    @Test func sessionKeepsWeighting() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let session = Session(savedAt: Date(timeIntervalSince1970: 1_800_000_000), photo: "a.jpg", colorCount: 6,
                              weighting: "moderate", markers: [])
        try session.write(to: file)
        #expect(try Session.read(from: file).weighting == "moderate")
    }
}

@Suite struct IntentionStyleTests {
    @Test func warmWordsPointToWarmHighlightsAndCoolWordsToTheReverse() {
        #expect(Intention.suggestedStyle(for: "Rustige, warme avond")?.style == .warmHighlights)
        #expect(Intention.suggestedStyle(for: "Rustige, warme avond")?.words == ["warme", "avond"])
        #expect(Intention.suggestedStyle(for: "a golden evening, calm")?.style == .warmHighlights)
        #expect(Intention.suggestedStyle(for: "Koele ochtend, mist")?.style == .coolHighlights)
        #expect(Intention.suggestedStyle(for: "icy winter light")?.style == .coolHighlights)
        #expect(Intention.suggestedStyle(for: "Warm")?.style == .warmHighlights)
    }

    @Test func wordsForTheOtherStylesCountWhenThereIsNoTemperatureWord() {
        #expect(Intention.suggestedStyle(for: "cinematic, dramatic")?.style == .tealOrange)
        #expect(Intention.suggestedStyle(for: "Filmisch")?.style == .tealOrange)
        #expect(Intention.suggestedStyle(for: "vintage, nostalgic")?.style == .faded)
        #expect(Intention.suggestedStyle(for: "nostalgisch en vervaagd")?.style == .faded)
        #expect(Intention.suggestedStyle(for: "cinematic and faded") == nil)            // two kinds: no decision
        #expect(Intention.suggestedStyle(for: "warme, nostalgische avond")?.style == .warmHighlights)   // temperature first
        #expect(Intention.suggestedStyle(for: "matig licht") == nil)
    }

    @Test func noWordOrMixedWordsDoNotDecide() {
        #expect(Intention.suggestedStyle(for: "") == nil)
        #expect(Intention.suggestedStyle(for: "calm, dramatic, soft") == nil)
        #expect(Intention.suggestedStyle(for: "warm light, cool shadows") == nil)
        // Only whole beginnings count: "swarm" is not warm.
        #expect(Intention.suggestedStyle(for: "a swarm of birds") == nil)
    }

    @Test func theMoodWordsOfTheMenuAreHandled() {
        #expect(Intention.suggestedStyle(for: Intention.toggling("warm", in: ""))?.style == .warmHighlights)
        #expect(Intention.suggestedStyle(for: Intention.toggling("cool", in: ""))?.style == .coolHighlights)
        #expect(Intention.suggestedStyle(for: Intention.toggling("fresh", in: ""))?.style == .coolHighlights)
    }
}

@Suite struct HueTurnDirectionTests {
    @Test func aPlusTurnMovesTowardTheNextChannelAndAMinusTurnTheOneBefore() {
        #expect(DxOChannel.red.direction(of: 29) == .orange)
        #expect(DxOChannel.red.direction(of: -10) == .magenta)          // wraps around the ring
        #expect(DxOChannel.magenta.direction(of: 5) == .red)
        #expect(DxOChannel.blue.direction(of: -20) == .cyan)
        #expect(DxOChannel.green.direction(of: 0) == nil)
        #expect(DxOChannel.neutral.direction(of: 10) == nil)
    }
}

@Suite struct DxOWheelTests {
    @Test func positionsAreThePhotoLabHueOfThePureColor() {
        // Measured with PhotoLab 10.1: pure sRGB red 13.8°, orange (sRGB 30°) 32.1°, yellow 61.3°, green 93.5°, cyan 184°, blue 248.7°.
        for (rgb, dxo) in [(0.0, 13.8), (30.0, 32.1), (60.0, 61.3), (120.0, 93.5), (180.0, 184.0), (240.0, 248.7)] {
            #expect(abs(HueSpace.dxo.position(ofRGBHue: rgb) - dxo) < 0.7)
        }
    }

    @Test func roundTripsAroundTheWholeCircle() {
        for h in stride(from: 0.0, to: 360.0, by: 7.3) {
            let back = HueSpace.dxo.rgbHue(atPosition: HueSpace.dxo.position(ofRGBHue: h))
            #expect(abs(ColorMath.signedAngle(from: h, to: back)) < 0.05)
        }
        // Positions below the first anchor (0°…13.8°) belong to the magenta-red end of the circle.
        let low = HueSpace.dxo.rgbHue(atPosition: 5)
        #expect(low > 330 && low < 360)
        #expect(HueSpace.dxo.position(ofRGBHue: 360) == HueSpace.dxo.position(ofRGBHue: 0))
    }

    @Test func positionsRiseMonotonically() {
        var last = -1.0
        let start = HueSpace.dxo.position(ofRGBHue: 0)
        for h in stride(from: 0.0, through: 359.0, by: 1) {
            let p = HueSpace.dxo.position(ofRGBHue: h)
            let unwrapped = p < start - 1e-9 ? p + 360 : p
            #expect(unwrapped > last - 1e-9)
            last = unwrapped
        }
    }

    @Test func aHarmonyOnPhotoLabsAxisIsOneThere() {
        // Two colors 180° apart on PhotoLab's axis: a complement there (not necessarily in sRGB degrees).
        let inputs = [HarmonyInput(hue: HueSpace.dxo.rgbHue(atPosition: 40), weight: 1),
                      HarmonyInput(hue: HueSpace.dxo.rgbHue(atPosition: 220), weight: 1)]
        let fit = HarmonyDetector.fit(.complementary, to: inputs, space: .dxo)
        #expect((fit?.deviation ?? 99) < 2)
        #expect(HueSpace(rawValue: "dxo") == .dxo && HueSpace.dxo.displayName == "DxO")
    }
}

@Suite struct OKLCHWheelTests {
    @Test func positionsAreTheOKLabHueOfThePureColor() {
        // OKLab hue angles of the sRGB primaries and secondaries.
        for (rgb, oklch) in [(0.0, 29.2), (60.0, 109.8), (120.0, 142.5), (180.0, 194.8), (240.0, 264.1), (300.0, 328.4)] {
            #expect(abs(HueSpace.oklch.position(ofRGBHue: rgb) - oklch) < 0.7)
        }
    }

    @Test func roundTripsAndRisesAroundTheCircle() {
        var last = -1.0
        let start = HueSpace.oklch.position(ofRGBHue: 0)
        for h in stride(from: 0.0, through: 359.0, by: 1) {
            let p = HueSpace.oklch.position(ofRGBHue: h)
            let unwrapped = p < start - 1e-9 ? p + 360 : p
            #expect(unwrapped > last - 1e-9)
            last = unwrapped
            #expect(abs(ColorMath.signedAngle(from: h, to: HueSpace.oklch.rgbHue(atPosition: p))) < 0.05)
        }
        let low = HueSpace.oklch.rgbHue(atPosition: 10)
        #expect(low > 330 && low < 360)
        #expect(HueSpace(rawValue: "oklch") == .oklch && HueSpace.oklch.displayName == "OKLCH")
    }

    @Test func aHarmonyOnTheOKLCHWheelIsOneThere() {
        let inputs = [HarmonyInput(hue: HueSpace.oklch.rgbHue(atPosition: 60), weight: 1),
                      HarmonyInput(hue: HueSpace.oklch.rgbHue(atPosition: 240), weight: 1)]
        #expect((HarmonyDetector.fit(.complementary, to: inputs, space: .oklch)?.deviation ?? 99) < 2)
    }
}

@Suite struct RYBTests {
    @Test func anchorsMapToTheArtistsWheel() {
        let expected: [(rgb: Double, ryb: Double)] = [(0, 0), (30, 60), (60, 120), (120, 180), (180, 210), (240, 240), (300, 330)]
        for (rgb, ryb) in expected {
            #expect(abs(HueSpace.ryb.position(ofRGBHue: rgb) - ryb) < 1e-9)
            #expect(abs(HueSpace.ryb.rgbHue(atPosition: ryb) - rgb) < 1e-9)
        }
        #expect(HueSpace.ryb.position(ofRGBHue: 90) == 150)      // halfway yellow → green
        #expect(HueSpace.ryb.position(ofRGBHue: 360) == 0)       // wraps
        #expect(HueSpace.rgb.position(ofRGBHue: 400) == 40)
    }

    @Test func mappingIsMonotonicAndRoundTrips() {
        var previous = -1.0
        for h in stride(from: 0.0, to: 360, by: 1.5) {
            let p = HueSpace.ryb.position(ofRGBHue: h)
            #expect(p >= previous)
            previous = p
            #expect(abs(HueSpace.ryb.rgbHue(atPosition: p) - h) < 1e-9)
        }
    }

    @Test func artistsComplementsAreComplementaryOnlyOnRYB() {
        // red–green and orange–blue are the classic artist's pairs; on the RGB wheel they are not opposite.
        let redGreen = [HarmonyInput(hue: 0, weight: 1), HarmonyInput(hue: 120, weight: 1)]
        let ryb = HarmonyDetector.fit(.complementary, to: redGreen, space: .ryb)
        let rgb = HarmonyDetector.fit(.complementary, to: redGreen, space: .rgb)
        #expect((ryb?.deviation ?? 99) < 1)
        #expect((rgb?.deviation ?? 0) > 20)
        let orangeBlue = [HarmonyInput(hue: 30, weight: 1), HarmonyInput(hue: 240, weight: 1)]
        #expect((HarmonyDetector.fit(.complementary, to: orangeBlue, space: .ryb)?.deviation ?? 99) < 1)
        #expect(HarmonyDetector.detect(redGreen, space: .ryb)?.kind == .complementary)
    }

    @Test func shiftsAndTargetsStayInRGBDegrees() {
        // RYB complementary pair at rotation 0: targets at RYB 0° and 180° = sRGB 0° (red) and 120° (green).
        let fit = HarmonyFit(kind: .complementary, rotation: 0, deviation: 0, space: .ryb)
        #expect(fit.targets == [0, 180])
        #expect(fit.targetRGBHues == [0, 120])
        #expect(abs(fit.shift(for: 110) - 10) < 1e-9)        // 110° → green 120°
        #expect(abs(fit.shift(for: 350) - 10) < 1e-9)        // 350° → red 0°
        // Red→orange is stretched 2× on the RYB wheel: the distance is measured there, the shift in sRGB degrees.
        #expect(abs(fit.signedDistance(from: 20) - -40) < 1e-9)
        #expect(abs(fit.shift(for: 20) - -20) < 1e-9)
    }

    @Test func rgbFitsBehaveAsBefore() {
        let fit = HarmonyFit(kind: .complementary, rotation: 30, deviation: 0)
        #expect(fit.space == .rgb && fit.targetRGBHues == fit.targets)
        #expect(fit.shift(for: 22) == 8)
    }

    @Test func exportsAndSessionNameTheWheel() throws {
        let fit = HarmonyFit(kind: .complementary, rotation: 0, deviation: 3, space: .ryb)
        let h = ColorExport.Harmony(fit: fit, autoDetected: false, fitAfter: nil)
        #expect(h.hueSpace == "ryb" && h.targetHues == [0, 120])
        let session = Session(photo: "a.jpg", colorCount: 6, markers: [], hueSpace: "ryb")
        #expect(session.hueSpace == "ryb")
    }
}

@Suite struct SkinToneTests {
    static func hex(_ value: UInt32) -> SRGBColor {
        SRGBColor(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }

    @Test func typicalSkinTonesAreSkinLike() {
        // From pale to deep complexions (Fitzpatrick-style swatches).
        for value: UInt32 in [0xFFDBAC, 0xF1C27D, 0xE0AC69, 0xC68642, 0x8D5524] {
            #expect(SkinTone.isSkinLike(Self.hex(value)), "#\\(String(value, radix: 16))")
        }
    }

    @Test func otherColorsAreNot() {
        for value: UInt32 in [0xFF0000, 0xFF8000, 0xFA7C7A, 0x7787FF, 0x84B824, 0x808080, 0x1A0F08, 0xFFFFFF] {
            #expect(!SkinTone.isSkinLike(Self.hex(value)), "#\\(String(value, radix: 16))")
        }
    }

    @Test func offsetIsSignedTowardYellow() {
        #expect(SkinTone.offset(ofHue: 25) == 0)
        #expect(SkinTone.offset(ofHue: 31) == 6)
        #expect(SkinTone.offset(ofHue: 345) == -40)
        #expect(SkinTone.hueRange == 13...37)
        #expect(SkinTone.describe(offset: 0.4) == "on the line")
        #expect(SkinTone.describe(offset: 4.2) == "+4° toward yellow")
        #expect(SkinTone.describe(offset: -6.7) == "-7° toward red")
    }

    @Test func gradingChangesAreClassified() {
        let skin = Self.hex(0xE0AC69), yellowedSkin = Self.hex(0xD9B800), redWall = Self.hex(0xB03030)
        #expect(SkinTone.change(from: skin, to: skin) == .stays(offset: SkinTone.offset(ofHue: skin.hsb.h)))
        if case .leaves(let offset)? = SkinTone.change(from: skin, to: yellowedSkin) { #expect(offset > 12) } else { Issue.record("expected leaves") }
        if case .enters? = SkinTone.change(from: redWall, to: skin) {} else { Issue.record("expected enters") }
        #expect(SkinTone.change(from: redWall, to: redWall) == nil)
    }

    @Test func exportsCarryTheOffsetOnlyForSkinLikeColors() {
        let skin = Self.hex(0xE0AC69), blue = Self.hex(0x7787FF)
        let records = [ColorRecord(number: 1, location: .zero, color: skin, share: 0.5),
                       ColorRecord(number: 2, location: .zero, color: blue, share: 0.5)]
        #expect(records[0].skinToneOffset != nil && records[1].skinToneOffset == nil)
        let csv = ColorExport(photo: "a.jpg", colors: records).csv().components(separatedBy: "\r\n")
        #expect(csv[0].hasSuffix(",skin_tone_offset"))
        #expect(csv[1].hasSuffix(",\(ColorExport.num(records[0].skinToneOffset))"))
        #expect(csv[2].hasSuffix(","))                      // blank for the non-skin color
        let none = ColorExport(photo: "a.jpg", colors: [records[1]]).csv()
        #expect(!none.contains("skin_tone"))
    }

    @Test func afterColumnTracksSkinDrift() {
        let skin = Self.hex(0xE0AC69), yellowed = Self.hex(0xD9B800)
        let record = ColorRecord(number: 1, location: .zero, color: skin, share: 1, after: yellowed)
        #expect(record.skinToneOffset != nil && record.after?.skinToneOffset == nil)   // left the band
        let csv = ColorExport(photo: "a.jpg", colors: [record]).csv().components(separatedBy: "\r\n")
        #expect(csv[0].hasSuffix(",after_harmony_shift,after_skin_tone_offset"))
        #expect(csv[0].components(separatedBy: ",").count == csv[1].components(separatedBy: ",").count)
    }
}

@Suite struct SeriesTests {
    static func color(_ r: Double, _ g: Double, _ b: Double) -> SIMD3<Float> { SRGBColor(r: r, g: g, b: b).oklab }
    static func hue(_ h: Double, s: Double = 0.7, v: Double = 0.85) -> SIMD3<Float> {
        SRGBColor.fromHSB(h: h, s: s, b: v).oklab
    }

    /// A "look": warm orange/teal pair with the given hue rotation applied.
    static func photo(rotation: Double = 0, orange: Double = 0.6) -> [SeriesColor] {
        [SeriesColor(centroid: hue(30 + rotation), share: orange),
         SeriesColor(centroid: hue(190 + rotation, s: 0.5, v: 0.6), share: 1 - orange)]
    }

    @Test func identicalPhotosShareOnePalette() {
        let photos = [Self.photo(), Self.photo(), Self.photo()]
        let palette = SeriesAnalyzer.sharedPalette(from: photos, size: 4)
        #expect(palette.count == 2)                           // duplicates merge
        #expect(palette[0].presence == 3 && palette[0].photoCount == 3)
        #expect(abs(palette[0].share - 0.6) < 1e-6)
        for photo in photos {
            let c = SeriesAnalyzer.consistency(of: photo, against: palette)
            #expect(c.score == 100 && c.unmatchedShare == 0)
            #expect(abs(c.hueShift ?? 99) < 0.5 && abs(c.saturationChange) < 0.5 && abs(c.lightnessChange) < 0.5)
        }
    }

    @Test func theOutlierGetsTheLowestScoreAndASuggestionBack() {
        let photos = [Self.photo(), Self.photo(), Self.photo(rotation: 12)]
        let palette = SeriesAnalyzer.sharedPalette(from: photos, size: 4)
        let scores = photos.map { SeriesAnalyzer.consistency(of: $0, against: palette) }
        #expect(scores[2].score < scores[0].score)
        #expect(scores[0].score == scores[1].score)
        // The rotated photo should turn back (negative), the two others a little forward.
        #expect((scores[2].hueShift ?? 0) < -1)
        #expect((scores[0].hueShift ?? 0) > 0)
    }

    @Test func aUniqueSubjectIsUnmatched() {
        let green = SeriesColor(centroid: Self.hue(120), share: 0.3)
        let odd = [SeriesColor(centroid: Self.hue(30), share: 0.7), green]
        let palette = SeriesAnalyzer.sharedPalette(from: [Self.photo(), Self.photo(), Self.photo()], size: 4)
        let c = SeriesAnalyzer.consistency(of: odd, against: palette)
        #expect(abs(c.unmatchedShare - 0.3) < 1e-6)
        #expect(c.matches[0] != nil && c.matches[1] == nil)
        #expect(c.score < 100)
    }

    @Test func saturationAndLightnessSuggestionsHaveTheRightSign() {
        let palette = SeriesAnalyzer.sharedPalette(from: [Self.photo(), Self.photo()], size: 2)
        // Same hue, less saturated and darker than the series.
        let dull = [SeriesColor(centroid: Self.hue(30, s: 0.6, v: 0.7), share: 0.6),
                    SeriesColor(centroid: Self.hue(190, s: 0.5, v: 0.6), share: 0.4)]
        let c = SeriesAnalyzer.consistency(of: dull, against: palette)
        #expect(c.saturationChange > 0)      // needs more saturation
        #expect(c.lightnessChange > 0)       // needs to be brighter
    }

    @Test func paletteSizeAndEdgeCases() {
        let many = (0..<6).map { SeriesColor(centroid: Self.hue(Double($0) * 60), share: 1.0 / 6) }
        #expect(SeriesAnalyzer.sharedPalette(from: [many, many], size: 3).count == 3)
        #expect(SeriesAnalyzer.sharedPalette(from: [], size: 3).isEmpty)
        #expect(SeriesAnalyzer.sharedPalette(from: [many], size: 0).isEmpty)
        let empty = SeriesAnalyzer.consistency(of: many, against: [])
        #expect(empty.score == 0 && empty.unmatchedShare == 1)
    }

    @Test func aReferencePhotoMatchesAcrossAWiderGap() {
        // A reference with a different look: its orange and teal sit 40° away from the photo's.
        let reference = SeriesAnalyzer.sharedPalette(from: [Self.photo(rotation: 40)], size: 4)
        let orange = Self.hue(30)
        #expect(SeriesAnalyzer.match(orange, against: reference) == nil)                         // too far for a series
        let match = SeriesAnalyzer.match(orange, against: reference, threshold: SeriesAnalyzer.referenceMatchThreshold)
        #expect(match != nil)
        #expect(abs((match?.hueShift ?? 0) - 40) < 8)                                            // aim: 40° toward the reference

        let strict = SeriesAnalyzer.consistency(of: Self.photo(), against: reference)
        let loose = SeriesAnalyzer.consistency(of: Self.photo(), against: reference,
                                               threshold: SeriesAnalyzer.referenceMatchThreshold)
        #expect(!strict.hasSuggestion)
        #expect(loose.hasSuggestion && loose.unmatchedShare == 0)
        #expect(abs((loose.hueShift ?? 0) - 40) < 8)
    }

    @Test func exportsListPaletteAndPhotos() throws {
        let photos = [Self.photo(), Self.photo(rotation: 12)]
        let palette = SeriesAnalyzer.sharedPalette(from: photos, size: 4)
        let export = SeriesExport(
            settings: .init(colorsPerPhoto: 2, paletteSize: 4),
            palette: palette,
            photos: [("a.jpg", "/x/a.jpg", photos[0]), ("b, \"quoted\".jpg", "/x/b.jpg", photos[1])])
        #expect(export.palette.map(\.number) == Array(1...export.palette.count))
        #expect(export.photos.count == 2 && export.photos[0].colors.count == 2)
        let csv = export.photosCSV().components(separatedBy: "\r\n")
        #expect(csv[0].hasPrefix("name,path,score,"))
        #expect(csv[2].hasPrefix("\"b, \"\"quoted\"\".jpg\",/x/b.jpg,"))       // quoting
        let nl = export.paletteCSV(style: .europeanExcel).components(separatedBy: "\r\n")
        #expect(nl[0].hasPrefix("number;hex;red;") && !nl[0].contains(","))
        #expect(nl[1].components(separatedBy: ";").count == nl[0].components(separatedBy: ";").count)
        let text = String(decoding: try export.json(), as: UTF8.self)
        #expect(text.contains("\"colorsPerPhoto\" : 2") && text.contains("\"paletteNumber\""))
    }
}

@Suite struct SeriesSuggestionTests {
    @Test func aPhotoThatBarelyMatchesGetsNoSuggestion() {
        let palette = SeriesAnalyzer.sharedPalette(from: [SeriesTests.photo(), SeriesTests.photo(), SeriesTests.photo()], size: 4)
        // 55 % of this photo has no counterpart in the palette.
        let far = [SeriesColor(centroid: SeriesTests.hue(120), share: 0.55),
                   SeriesColor(centroid: SeriesTests.hue(30), share: 0.45)]
        let c = SeriesAnalyzer.consistency(of: far, against: palette)
        #expect(!c.hasSuggestion && c.hueShift == nil && c.saturationChange == 0 && c.lightnessChange == 0)
        #expect(c.unmatchedShare > 0.5)
        let export = SeriesExport(settings: .init(colorsPerPhoto: 2, paletteSize: 4), palette: palette,
                                  photos: [("far.jpg", "/x/far.jpg", far)])
        #expect(export.photos[0].hueShift == nil && export.photos[0].saturationChangePercent == nil
                && export.photos[0].lightnessChange == nil)
        let row = export.photosCSV().components(separatedBy: "\r\n")[1]
        #expect(row.contains(",,,,"))               // blank hue / saturation / lightness cells
    }

    @Test func aPhotoThatMostlyMatchesKeepsItsSuggestion() {
        let palette = SeriesAnalyzer.sharedPalette(from: [SeriesTests.photo(), SeriesTests.photo(), SeriesTests.photo()], size: 4)
        let mostly = [SeriesColor(centroid: SeriesTests.hue(120), share: 0.3),
                      SeriesColor(centroid: SeriesTests.hue(30), share: 0.7)]
        #expect(SeriesAnalyzer.consistency(of: mostly, against: palette).hasSuggestion)
    }
}

@Suite struct WideGamutTests {
    /// A flat image in the given color space.
    static func image(_ space: CFString, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let cs = CGColorSpace(name: space)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [r, g, b, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    @Test func displayP3GreenIsNotClippedOnDecode() {
        let buffer = PixelBuffer(image: Self.image(CGColorSpace.displayP3, 0, 1, 0), maxDimension: 8)
        let linear = buffer.linear[0]
        #expect(linear.x < -0.05)                       // red component below zero: outside sRGB
        #expect(linear.y > 1.0)                         // green above one
        let color = SRGBColor(linear: linear)
        #expect(color.isOutsideSRGB)
        #expect(color.hsb.s > 1.05)                     // saturation beyond the sRGB rim
        #expect(color.hex == "#00FF00")                 // readouts are clipped
        let p3 = color.displayP3Components
        #expect(abs(p3.r) < 0.01 && abs(p3.g - 1) < 0.01 && abs(p3.b) < 0.01)   // exactly what the photo had
    }

    @Test func srgbImagesDecodeAsBefore() {
        let buffer = PixelBuffer(image: Self.image(CGColorSpace.sRGB, 0.5, 0.25, 0.75), maxDimension: 8)
        let expected = SRGBColor(r: 0.5, g: 0.25, b: 0.75).linear
        #expect(abs(buffer.linear[0].x - expected.x) < 2e-3)
        #expect(abs(buffer.linear[0].y - expected.y) < 2e-3)
        #expect(abs(buffer.linear[0].z - expected.z) < 2e-3)
        #expect(!SRGBColor(linear: buffer.linear[0]).isOutsideSRGB)
    }

    @Test func transferCurveRoundTripsOutsideTheGamut() {
        for x in [-0.3, -0.002, 0.0, 0.0012, 0.5, 1.0, 1.4] {
            #expect(abs(ColorMath.sRGBToLinear(ColorMath.linearToSRGB(x)) - x) < 1e-9)
        }
        #expect(ColorMath.linearToSRGB(-0.5) == -ColorMath.linearToSRGB(0.5))
    }

    @Test func srgbRedInDisplayP3() {
        let p3 = SRGBColor(r: 1, g: 0, b: 0).displayP3Components
        #expect(abs(p3.r - 0.918) < 0.002 && abs(p3.g - 0.200) < 0.002 && abs(p3.b - 0.139) < 0.002)
        #expect(SRGBColor(r: 1, g: 0, b: 0).displayP3RGB255 == (234, 51, 35))
        let white = SRGBColor(r: 1, g: 1, b: 1).displayP3Components
        #expect(abs(white.r - 1) < 1e-3 && abs(white.g - 1) < 1e-3 && abs(white.b - 1) < 1e-3)
    }

    @Test func outOfGamutColorsKeepValidReadouts() {
        let wide = SRGBColor(linear: SIMD3(-0.2, 1.0, -0.1))
        let hsl = wide.hsl
        #expect(hsl.s >= 0 && hsl.s <= 1 && hsl.l >= 0 && hsl.l <= 1)
        #expect(wide.clamped.r == 0 && abs(wide.clamped.g - 1) < 1e-6)
        #expect(wide.chroma > SRGBColor(r: 0, g: 1, b: 0).chroma)      // truly more saturated than sRGB green
        #expect(wide.hsb.h > 120 && wide.hsb.h < 130)                   // hue of the unclipped color
        #expect(!SRGBColor(r: 0.2, g: 0.4, b: 0.6).isOutsideSRGB)
    }

    @Test func wideGamutColorsStayDistinctInAnalysis() {
        // Two different P3 greens that would clip to the same sRGB green.
        let a = SRGBColor(linear: SIMD3(-0.15, 1.02, -0.05)), b = SRGBColor(linear: SIMD3(-0.30, 1.10, -0.10))
        #expect(a.clamped == b.clamped)
        #expect(ColorMath.distanceSquared(a.oklab, b.oklab).squareRoot() > 0.03)
    }
}

@Suite struct WideGamutExportTests {
    static let p3Green = SRGBColor(linear: SIMD3(-0.2, 1.0, -0.1))
    static let plain = SRGBColor(r: 0.2, g: 0.4, b: 0.6)

    @Test func recordsOutsideSRGBCarryDisplayP3() {
        let wide = ColorRecord(number: 1, location: .zero, color: Self.p3Green, share: 0.5)
        let inside = ColorRecord(number: 2, location: .zero, color: Self.plain, share: 0.5)
        #expect(wide.hex == "#00FF00")
        #expect(wide.displayP3 != nil && inside.displayP3 == nil)
        #expect(wide.displayP3?.count == 3 && (wide.displayP3?[1] ?? 0) > 240)
    }

    @Test func csvAddsP3ColumnsOnlyWhenNeeded() {
        let wide = ColorRecord(number: 1, location: .zero, color: Self.p3Green, share: 0.5)
        let inside = ColorRecord(number: 2, location: .zero, color: Self.plain, share: 0.5)
        let on = ColorExport(photo: "a.jpg", colors: [wide, inside]).csv().components(separatedBy: "\r\n")
        #expect(on[0].hasSuffix(",p3_red,p3_green,p3_blue"))
        #expect(on[2].hasSuffix(",,,"))                                   // blank for the color inside sRGB
        #expect(on[0].components(separatedBy: ",").count == on[1].components(separatedBy: ",").count)
        let off = ColorExport(photo: "a.jpg", colors: [inside]).csv()
        #expect(!off.contains("p3_"))
    }

    @Test func seriesPaletteCarriesDisplayP3() {
        let palette = [SharedColor(centroid: Self.p3Green.oklab, share: 0.6, presence: 2, photoCount: 2),
                       SharedColor(centroid: Self.plain.oklab, share: 0.4, presence: 2, photoCount: 2)]
        let export = SeriesExport(settings: .init(colorsPerPhoto: 2, paletteSize: 2), palette: palette, photos: [])
        #expect(export.palette[0].displayP3 != nil && export.palette[1].displayP3 == nil)
        #expect(export.paletteCSV().components(separatedBy: "\r\n")[0].hasSuffix(",p3_red,p3_green,p3_blue"))
    }
}

@Suite struct MarkerPlacementTests {
    @Test func aFlatBackdropGetsAMarkerInTheMiddleNotTheCorner() {
        let grey = SRGBColor(r: 0.5, g: 0.5, b: 0.5).linear
        let buffer = PixelBuffer(width: 100, height: 100, linear: [SIMD3<Float>](repeating: grey, count: 10_000))
        let location = DominantColorAnalyzer.analyze(buffer, count: 1)[0].location
        #expect(abs(location.x - 0.5) < 0.05 && abs(location.y - 0.5) < 0.05)
    }

    @Test func aBackdropWithAHoleStillAvoidsTheHole() {
        // Grey frame around a red square: the grey marker must sit on grey, not in the middle.
        let grey = SRGBColor(r: 0.5, g: 0.5, b: 0.5).linear, red = SRGBColor(r: 0.9, g: 0.1, b: 0.1).linear
        var linear = [SIMD3<Float>](repeating: grey, count: 10_000)
        for y in 30..<70 { for x in 30..<70 { linear[y * 100 + x] = red } }
        let buffer = PixelBuffer(width: 100, height: 100, linear: linear)
        let colors = DominantColorAnalyzer.analyze(buffer, count: 2)
        let greyLocation = colors.first { $0.centroid.x > 0.4 && ColorMath.distanceSquared($0.centroid, SRGBColor(r: 0.5, g: 0.5, b: 0.5).oklab) < 0.01 }!.location
        let insideHole = (0.3..<0.7).contains(greyLocation.x) && (0.3..<0.7).contains(greyLocation.y)
        #expect(!insideHole)
    }
}

@Suite struct SeriesMatchTests {
    static func palette() -> [SharedColor] {
        [SharedColor(centroid: SeriesTests.hue(30), share: 0.6, presence: 3, photoCount: 3),
         SharedColor(centroid: SeriesTests.hue(190, s: 0.5, v: 0.6), share: 0.4, presence: 3, photoCount: 3)]
    }

    @Test func findsTheCloseColorAndTheWayThere() throws {
        // A slightly more yellow, less saturated, darker orange than the palette's.
        let match = try #require(SeriesAnalyzer.match(SeriesTests.hue(36, s: 0.6, v: 0.7), against: Self.palette()))
        #expect(match.index == 0 && match.deltaE < 0.12)
        #expect((match.hueShift ?? 0) < -2)               // palette is more red: turn back
        #expect(match.saturationChange > 0)               // palette is more saturated
        #expect(match.lightnessChange > 0)                // palette is lighter
    }

    @Test func aColorAwayFromEverythingHasNoCounterpart() {
        #expect(SeriesAnalyzer.match(SeriesTests.hue(120), against: Self.palette()) == nil)
        #expect(SeriesAnalyzer.match(SeriesTests.hue(30), against: []) == nil)
    }

    @Test func neutralColorsGetNoHueShift() throws {
        let grey = SharedColor(centroid: SRGBColor(r: 0.5, g: 0.5, b: 0.5).oklab, share: 1, presence: 1, photoCount: 1)
        let match = try #require(SeriesAnalyzer.match(SRGBColor(r: 0.52, g: 0.5, b: 0.5).oklab, against: [grey]))
        #expect(match.hueShift == nil)
    }
}

@Suite struct SeriesFileTests {
    static func sample() -> SeriesFile {
        SeriesFile(savedAt: Date(timeIntervalSince1970: 1_800_000_000), colorsPerPhoto: 5, paletteSize: 6,
                   weighting: "moderate", hueSpace: "ryb", sortByScore: true,
                   photos: SeriesFile.photos([URL(fileURLWithPath: "/shoot/day1/a.jpg"),
                                              URL(fileURLWithPath: "/shoot/day2/b.jpg"),
                                              URL(fileURLWithPath: "/other/c.jpg")],
                                             savedIn: URL(fileURLWithPath: "/shoot/series")))
    }

    @Test func relativePaths() {
        let folder = URL(fileURLWithPath: "/shoot/series")
        #expect(SeriesFile.relativePath(of: URL(fileURLWithPath: "/shoot/series/x.jpg"), from: folder) == "x.jpg")
        #expect(SeriesFile.relativePath(of: URL(fileURLWithPath: "/shoot/series/sub/x.jpg"), from: folder) == "sub/x.jpg")
        #expect(SeriesFile.relativePath(of: URL(fileURLWithPath: "/shoot/day1/a.jpg"), from: folder) == "../day1/a.jpg")
        #expect(SeriesFile.relativePath(of: URL(fileURLWithPath: "/other/c.jpg"), from: folder) == "../../other/c.jpg")
    }

    @Test func roundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("series-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.sample().write(to: file)
        #expect(try SeriesFile.read(from: file) == Self.sample())
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"path\" : \"/shoot/day1/a.jpg\""))
    }

    @Test func rejectsNewerFormat() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("series-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var saved = Self.sample()
        saved.version = SeriesFile.currentVersion + 1
        try saved.write(to: file)
        #expect(throws: SeriesFile.FileError.self) { try SeriesFile.read(from: file) }
    }

    @Test func photosAreFoundWhereTheyWentWhenTheFolderMoved() {
        // Everything moved from /shoot to /archive/2026; a.jpg also got copied next to the series file.
        let moved = URL(fileURLWithPath: "/archive/2026/series")
        let existing: Set<String> = ["/archive/2026/day2/b.jpg", "/archive/2026/series/c.jpg", "/archive/2026/series/a.jpg"]
        let result = Self.sample().resolvedPhotos(folder: moved) { existing.contains($0.path) }
        #expect(result.found.map(\.path) == ["/archive/2026/series/a.jpg", "/archive/2026/day2/b.jpg", "/archive/2026/series/c.jpg"])
        #expect(result.missing.isEmpty)
    }

    @Test func savedPathWinsAndMissingPhotosAreNamed() {
        let folder = URL(fileURLWithPath: "/shoot/series")
        let result = Self.sample().resolvedPhotos(folder: folder) { $0.path == "/shoot/day1/a.jpg" }
        #expect(result.found.map(\.path) == ["/shoot/day1/a.jpg"])
        #expect(result.missing == ["b.jpg", "c.jpg"])
    }

    @Test func optionalFieldsMayBeMissing() throws {
        let json = #"{"version":1,"savedAt":"2026-10-10T10:00:00Z","colorsPerPhoto":5,"paletteSize":6,"photos":[{"path":"/x/a.jpg"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(SeriesFile.self, from: Data(json.utf8))
        #expect(file.weighting == nil && file.hueSpace == nil && file.sortByScore == nil)
        #expect(file.photos[0].relativePath == nil)
    }
}

@Suite struct IntentionTests {
    @Test func wordsAreCommaSeparatedAndTrimmed() {
        #expect(Intention.words(in: " warm ,calm,, nostalgic ") == ["warm", "calm", "nostalgic"])
        #expect(Intention.words(in: "   ").isEmpty)
    }

    @Test func togglingAddsAndRemovesWords() {
        var text = ""
        text = Intention.toggling("warm", in: text)
        text = Intention.toggling("calm", in: text)
        #expect(text == "warm, calm")
        #expect(Intention.contains("WARM", in: text))
        text = Intention.toggling("Warm", in: text)                 // case-insensitive removal
        #expect(text == "calm" && !Intention.contains("warm", in: text))
        // Free text around the words is kept, as separate items.
        #expect(Intention.toggling("soft", in: "late summer evening, a bit lonely") == "late summer evening, a bit lonely, soft")
    }

    @Test func cleanedDropsEmptyNotes() {
        #expect(Intention.cleaned("  warm and calm \n") == "warm and calm")
        #expect(Intention.cleaned("   ") == nil && Intention.cleaned(nil) == nil)
    }

    @Test func theNoteTravelsWithSessionsExportsAndSeries() throws {
        let session = Session(photo: "a.jpg", colorCount: 6, markers: [], intention: "warm, calm")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try session.write(to: file)
        #expect(try Session.read(from: file).intention == "warm, calm")

        let colors = ColorExport(photo: "a.jpg", intention: " warm, calm ", colors: [])
        #expect(colors.intention == "warm, calm")
        #expect(String(decoding: try colors.json(), as: UTF8.self).contains("\"intention\" : \"warm, calm\""))
        #expect(!String(decoding: try ColorExport(photo: "a.jpg", intention: "  ", colors: []).json(), as: UTF8.self).contains("intention"))

        let series = SeriesFile(colorsPerPhoto: 5, paletteSize: 6, intention: "one family", photos: [])
        #expect(series.intention == "one family")
        let export = SeriesExport(intention: "one family", settings: .init(colorsPerPhoto: 5, paletteSize: 6),
                                  palette: [SeriesExport.PaletteColor](), photos: [SeriesExport.Photo]())
        #expect(export.intention == "one family")
    }
}

@Suite struct DxOHueTests {
    @Test func slicesAreReadFromTheSidecar() {
        #expect(DxOHue.slices.map(\.channel) == [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .magenta])
        let centers = DxOHue.slices.map { Int($0.center.rounded()) % 360 }     // red sits at -0.3°, i.e. 359.7°
        #expect(centers == [0, 36, 52, 104, 186, 231, 270, 310])
        // Neighbouring slices share their fade ranges.
        for (a, b) in zip(DxOHue.slices, DxOHue.slices.dropFirst()) {
            #expect(a.fadeOutStart == b.fadeInStart && a.fadeOutEnd == b.fadeInEnd)
        }
    }

    @Test func membershipFollowsTheFades() {
        let yellow = DxOHue.slices[2]
        #expect(yellow.membership(of: 52) == 1)
        #expect(yellow.membership(of: 30) == 0 && yellow.membership(of: 70) == 0)
        let mid = yellow.membership(of: (41.144 + 50.114) / 2)       // halfway up the fade-in
        #expect(abs(mid - 0.5) < 0.01)
        let red = DxOHue.slices[0]                                    // wraps around 0°
        #expect(red.membership(of: 355) == 1 && red.membership(of: 5) == 1 && red.membership(of: 10) == 1)
        #expect(red.membership(of: 180) == 0)
    }

    @Test func pureSRGBHuesLandWhereRec2020PutsThem() {
        // Measured with PhotoLab 10.1: its hue is the HSV hue in Rec.2020 primaries. Pure sRGB red is at 13.8°, not 0°.
        for (srgb, dxo) in [(0.0, 13.82), (60, 61.34), (120, 93.49), (180, 184.09), (240, 248.66), (300, 288.67)] {
            #expect(abs(DxOHue.fromSRGB(srgb) - dxo) < 0.05, "sRGB \(srgb)")
        }
        // The hue of an actual color depends on its saturation: the less saturated, the nearer to its sRGB hue.
        let saturated = DxOHue.hue(of: .fromHSB(h: 0, s: 1, b: 1)) ?? -1
        let faint = DxOHue.hue(of: .fromHSB(h: 0, s: 0.4, b: 0.8)) ?? -1
        #expect(saturated > faint && faint > 0)
        #expect(DxOHue.hue(of: SRGBColor(r: 0.5, g: 0.5, b: 0.5)) == nil)
    }

    @Test func theMapRoundTripsAndNeverFolds() {
        for h in stride(from: 0.0, to: 360, by: 7.5) {
            #expect(abs(ColorMath.signedAngle(from: h, to: DxOHue.toSRGB(DxOHue.fromSRGB(h)))) < 1e-3)
        }
        var previous = DxOHue.fromSRGB(1)
        for h in stride(from: 2.0, to: 360, by: 1) {
            let d = DxOHue.fromSRGB(h)
            #expect(ColorMath.signedAngle(from: previous, to: d) > 0)
            previous = d
        }
    }

    @Test func channelsFollowDxOsSlicesNotSRGBRanges() {
        // Yellow-green grass (sRGB hue ≈ 81°) is Green in DxO, and so is pure sRGB yellow: on PhotoLab's axis it sits at 61°,
        // inside the fade to green. A warmer yellow (sRGB 50°) is Yellow.
        #expect(DxOMapping.channel(for: .fromHSB(h: 81, s: 0.7, b: 0.7)) == .green)
        #expect(DxOMapping.channel(for: .fromHSB(h: 60, s: 0.8, b: 0.9)) == .green)
        #expect(DxOMapping.channel(for: .fromHSB(h: 50, s: 0.8, b: 0.9)) == .yellow)
        #expect(DxOMapping.channel(for: .fromHSB(h: 25, s: 0.8, b: 0.9)) == .orange)
        #expect(DxOMapping.channel(for: .fromHSB(h: 180, s: 0.8, b: 0.9)) == .cyan)
        #expect(DxOMapping.channel(for: .fromHSB(h: 200, s: 0.8, b: 0.9)) == .blue)      // azure is Blue on PhotoLab's axis
        #expect(DxOMapping.channel(for: .fromHSB(h: 350, s: 0.8, b: 0.9)) == .red)
        #expect(DxOMapping.channel(for: .fromHSB(h: 300, s: 0.8, b: 0.9)) == .magenta)
    }
}

@Suite struct ColorGradingPresetTests {
    /// The contents of `test preset.preset`, saved by DxO PhotoLab 10.1 from the Color Grading tool.
    static let photoLabFile = "Preset = {\n\tSettings = {\n\t\tBase = {\n\t\t\tColorGradingActive = true,\n\t\t\tColorGradingBalance = 10,\n"
        + "\t\t\tColorGradingParams_Highlights = {\n\t\t\t\tHue = 36,\n\t\t\t\tLum = 10,\n\t\t\t\tSat = 43,\n\t\t\t},\n"
        + "\t\t\tColorGradingParams_Master = {\n\t\t\t\tHue = 42,\n\t\t\t\tLum = 5,\n\t\t\t\tSat = 56,\n\t\t\t},\n"
        + "\t\t\tColorGradingParams_Midtones = {\n\t\t\t\tHue = 36,\n\t\t\t\tLum = 5,\n\t\t\t\tSat = 20,\n\t\t\t},\n"
        + "\t\t\tColorGradingParams_Shadows = {\n\t\t\t\tHue = 254,\n\t\t\t\tLum = -5,\n\t\t\t\tSat = 42,\n\t\t\t},\n"
        + "\t\t},\n\t\tVersion = \"21.0\",\n\t},\n\tVersion = \"21.0\",\n}\n"

    @Test func writesExactlyWhatPhotoLabWrites() {
        let preset = ColorGradingPreset(
            master: .init(hue: 42, saturation: 56, luminance: 5),
            shadows: .init(hue: 254, saturation: 42, luminance: -5),
            midtones: .init(hue: 36, saturation: 20, luminance: 5),
            highlights: .init(hue: 36, saturation: 43, luminance: 10),
            balance: 10)
        #expect(preset.luaText() == Self.photoLabFile)
        #expect(preset.luaText().utf8.count == 475)                     // size of the file on disk
        #expect(!preset.luaText().contains("\r"))
    }

    static func color(hue: Double, lightness: Double) -> SRGBColor {
        // A saturated color of the hue, with brightness chosen to land in the wanted tonal range.
        SRGBColor.fromHSB(h: hue, s: 0.7, b: lightness)
    }

    @Test func tintsEachRangeTowardItsTarget() {
        let highlight = Self.color(hue: 80, lightness: 0.95)    // L* well above 66
        let shadow = Self.color(hue: 250, lightness: 0.30)      // L* below 33
        #expect(DxOMapping.tonalRange(for: highlight) == .highlights && DxOMapping.tonalRange(for: shadow) == .shadows)
        let result = ColorGradingSuggestion.suggest(
            from: [.init(color: highlight, share: 0.5, targetHue: 60), .init(color: shadow, share: 0.3, targetHue: 230)],
            strength: .moderate)
        let h = result.preset.highlights, s = result.preset.shadows
        #expect(h.hue == Int(DxOHue.fromSRGB(60).rounded()))
        #expect(h.saturation == 20)                                 // 30 × (20° off / 30°)
        #expect(s.hue == Int(DxOHue.fromSRGB(230).rounded()) && s.saturation == 20)
        #expect(result.preset.midtones == .neutral && result.preset.master == .neutral)
        #expect(result.preset.balance == 0 && h.luminance == 0)
        #expect(result.details.map(\.range) == [.shadows, .midtones, .highlights])
        #expect(result.details[1].meanShift == nil)
    }

    @Test func strengthScalesTheSaturation() {
        let input = [ColorGradingSuggestion.Input(color: Self.color(hue: 100, lightness: 0.95), share: 0.5, targetHue: 60)]
        let sats = ColorGradingSuggestion.Strength.allCases.map {
            ColorGradingSuggestion.suggest(from: input, strength: $0).preset.highlights.saturation
        }
        #expect(sats == [15, 30, 50])                               // 40° off: full strength each
    }

    @Test func colorsOnTargetNeutralColorsAndEmptyInputLeaveEverythingAlone() {
        let onTarget = ColorGradingSuggestion.Input(color: Self.color(hue: 60, lightness: 0.95), share: 0.5, targetHue: 61)
        let grey = ColorGradingSuggestion.Input(color: SRGBColor(r: 0.5, g: 0.5, b: 0.5), share: 0.5, targetHue: 200)
        for inputs in [[onTarget], [grey], [ColorGradingSuggestion.Input]()] {
            let result = ColorGradingSuggestion.suggest(from: inputs, strength: .strong)
            #expect(result.preset == ColorGradingPreset())
        }
    }

    @Test func tintHueIsTheCircularMeanAcrossTheRedSeam() {
        // Two highlight colors whose targets straddle 0°: 350° and 10° average to 0°, not 180°.
        let a = Self.color(hue: 40, lightness: 0.95), b = Self.color(hue: 330, lightness: 0.95)
        let result = ColorGradingSuggestion.suggest(
            from: [.init(color: a, share: 0.25, targetHue: 350), .init(color: b, share: 0.25, targetHue: 10)], strength: .moderate)
        let hue = result.preset.highlights.hue
        #expect(abs(ColorMath.signedAngle(from: 0, to: Double(hue))) < 20)       // near the red seam; a plain average would give 180°
    }
}

@Suite struct ColorGradingEmphasisTests {
    /// A faint tint: the color of fog at dawn.
    static func faint(hue: Double, brightness: Double, saturation: Double = 0.12) -> SRGBColor {
        SRGBColor.fromHSB(h: hue, s: saturation, b: brightness)
    }

    @Test func emphasizesTheFaintTintOfEachRange() {
        let sky = Self.faint(hue: 215, brightness: 0.85)             // bluish highlights
        let dusk = Self.faint(hue: 300, brightness: 0.10, saturation: 0.6)   // violet-ish shadows
        #expect(DxOMapping.tonalRange(for: sky) == .highlights && DxOMapping.tonalRange(for: dusk) == .shadows)
        #expect(DxOMapping.channel(for: sky) == .neutral)             // too faint for the harmony machinery
        let result = ColorGradingSuggestion.emphasize([(sky, 0.5), (dusk, 0.3)], strength: .moderate)
        let h = result.preset.highlights
        #expect(h.hue == Int(DxOHue.fromSRGB(215).rounded()) && h.saturation > 0)
        #expect(result.details.first { $0.range == .highlights }?.reason == .tinted)
        #expect(result.details.first { $0.range == .midtones }?.reason == .noColors)
        #expect(result.preset.midtones == .neutral && h.luminance == 0)
    }

    @Test func strongerTintsAndStrengthScaleTheSaturation() {
        // Whatever tonal range the colors land in, the tinted wheel is what we compare.
        func saturation(_ color: SRGBColor, _ strength: ColorGradingSuggestion.Strength) -> Int? {
            ColorGradingSuggestion.emphasize([(color, 0.5)], strength: strength).details.first { $0.reason == .tinted }?.wheel.saturation
        }
        let faint = Self.faint(hue: 215, brightness: 0.85, saturation: 0.05)
        let vivid = Self.faint(hue: 215, brightness: 0.85, saturation: 0.6)
        let a = saturation(faint, .moderate), b = saturation(vivid, .moderate)
        #expect(a != nil && b != nil && a! < b!)
        #expect(b == 30)                                             // clearly colorful: the strength's full saturation
        #expect(saturation(vivid, .subtle) == 15 && saturation(vivid, .strong) == 50)
    }

    @Test func trulyGreyPhotosGetNothing() {
        let grey = [(SRGBColor(r: 0.5, g: 0.5, b: 0.5), 0.6), (SRGBColor(r: 0.1, g: 0.1, b: 0.1), 0.4)]
        let result = ColorGradingSuggestion.emphasize(grey, strength: .strong)
        #expect(result.preset == ColorGradingPreset())
        #expect(result.details.allSatisfy { $0.reason == .tooNeutral || $0.reason == .noColors })
    }

    @Test func reasonsExplainWhyARangeIsLeftAlone() {
        let onTarget = ColorGradingSuggestion.Input(color: SRGBColor.fromHSB(h: 60, s: 0.7, b: 0.95), share: 0.5, targetHue: 61)
        let result = ColorGradingSuggestion.suggest(from: [onTarget], strength: .moderate)
        #expect(result.details.first { $0.range == .highlights }?.reason == .onTarget)
        #expect(result.details.first { $0.range == .shadows }?.reason == .noColors)
    }
}

@Suite struct PhotoViewportTests {
    static let pane = CGSize(width: 400, height: 300)
    static let photo = CGSize(width: 400, height: 225)      // fits the pane's width at zoom 1

    /// Normalized position on the photo under a pane point.
    static func point(_ v: PhotoViewport, under p: CGPoint) -> CGPoint {
        let r = v.photoRect(photoFit: photo, pane: pane)
        return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    @Test func fitIsTheDefaultAndCentered() {
        let r = PhotoViewport().photoRect(photoFit: Self.photo, pane: Self.pane)
        #expect(r == CGRect(x: 0, y: 37.5, width: 400, height: 225))
        #expect(!PhotoViewport().isZoomed)
    }

    @Test func zoomingAroundAPointKeepsThatPointStill() {
        var v = PhotoViewport()
        let cursor = CGPoint(x: 300, y: 120)                                   // in pane coordinates
        let before = Self.point(v, under: cursor)
        v.setZoom(4, anchor: CGPoint(x: cursor.x - Self.pane.width / 2, y: cursor.y - Self.pane.height / 2))
        let after = Self.point(v, under: cursor)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
        #expect(v.zoom == 4)
        // …and again from a zoomed state, with a step in between.
        let before2 = Self.point(v, under: CGPoint(x: 50, y: 250))
        v.zoom(by: 1.5, anchor: CGPoint(x: 50 - 200, y: 250 - 150))
        let after2 = Self.point(v, under: CGPoint(x: 50, y: 250))
        #expect(abs(before2.x - after2.x) < 1e-9 && abs(before2.y - after2.y) < 1e-9)
    }

    @Test func zoomingWithoutAnAnchorKeepsThePaneCenter() {
        var v = PhotoViewport(zoom: 2, pan: CGSize(width: 30, height: -20))
        let center = CGPoint(x: Self.pane.width / 2, y: Self.pane.height / 2)
        let before = Self.point(v, under: center)
        v.setZoom(5)
        let after = Self.point(v, under: center)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
    }

    @Test func zoomIsLimitedAndFitsBackAtOne() {
        var v = PhotoViewport()
        v.setZoom(500)
        #expect(v.zoom == PhotoViewport.zoomRange.upperBound)
        v.pan = CGSize(width: 50, height: 50)
        v.setZoom(0.2)                                                          // below 1: back to fit, centered
        #expect(v == PhotoViewport())
        v.zoom(by: PhotoViewport.step)
        v.zoom(by: 1 / PhotoViewport.step)
        #expect(v == PhotoViewport())
    }

    @Test func panIsLimitedSoThePhotoStaysInView() {
        var v = PhotoViewport(zoom: 3, pan: CGSize(width: 5000, height: -5000))
        v = v.clamped(photoFit: Self.photo, pane: Self.pane)
        // Zoomed photo: 1200 × 675 in a 400 × 300 pane: edges may go 40 points past the pane's edges.
        #expect(v.pan.width == (1200 - 400) / 2 + 40 && v.pan.height == -((675 - 300) / 2 + 40))
        let r = v.photoRect(photoFit: Self.photo, pane: Self.pane)
        #expect(r.minX <= 40 && r.maxX >= 400 - 40 && r.minY <= 300 - 40 + 1)
        // A photo that is smaller than the pane in a direction is not pushed around in it.
        let small = PhotoViewport(zoom: 1.2, pan: CGSize(width: 100, height: 100)).clamped(photoFit: CGSize(width: 200, height: 100), pane: Self.pane)
        #expect(small.pan == .zero)
    }

    @Test func actualPixelsZoom() {
        #expect(PhotoViewport.actualPixelsZoom(imagePixels: 2048, photoFitWidth: 512) == 4)
        #expect(PhotoViewport.actualPixelsZoom(imagePixels: 300, photoFitWidth: 512) == 1)       // never below fit
        #expect(PhotoViewport.actualPixelsZoom(imagePixels: 99_999, photoFitWidth: 512) == 32)
        #expect(PhotoViewport.actualPixelsZoom(imagePixels: 2048, photoFitWidth: 0) == 1)
    }
}

@Suite struct SwatchExportTests {
    /// Reads an ASE file back: group names and swatches (name, r, g, b).
    struct Parsed {
        var version: (UInt16, UInt16) = (0, 0)
        var blockCount = 0
        var blocks: [UInt16] = []
        var groups: [String] = []
        var swatches: [(name: String, model: String, rgb: [Float], type: UInt16)] = []
    }

    static func parse(_ data: Data) -> Parsed? {
        let b = [UInt8](data)
        var i = 0
        func u16() -> UInt16 { defer { i += 2 }; return UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
        func u32() -> UInt32 { defer { i += 4 }; return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(b[i + $1]) } }
        func name() -> String {
            let count = Int(u16())
            let units = (0..<count).map { _ in u16() }
            return String(decoding: units.dropLast(), as: UTF16.self)
        }
        guard b.count >= 12, Array(b[0..<4]) == Array("ASEF".utf8) else { return nil }
        i = 4
        var parsed = Parsed()
        parsed.version = (u16(), u16())
        parsed.blockCount = Int(u32())
        for _ in 0..<parsed.blockCount {
            let type = u16(), length = Int(u32()), end = i + length
            parsed.blocks.append(type)
            switch type {
            case 0xC001: parsed.groups.append(name())
            case 0x0001:
                let n = name()
                let model = String(decoding: b[i..<i + 4], as: UTF8.self)
                i += 4
                let rgb = (0..<3).map { _ in Float(bitPattern: u32()) }
                parsed.swatches.append((n, model, rgb, u16()))
            default: break
            }
            guard i == end else { return nil }   // every block must be exactly as long as it says
        }
        return i == b.count ? parsed : nil
    }

    @Test func writesAReadableSwatchFile() throws {
        let data = AdobeSwatchExchange.data(groupName: "Sunset – ColorAnalyze", swatches: [
            ("1 – #FF8000", SRGBColor(r: 1, g: 0.5, b: 0)),
            ("2 – #003366", SRGBColor(r: 0, g: 0.2, b: 0.4))])
        let parsed = try #require(Self.parse(data))
        #expect(parsed.version == (1, 0))
        #expect(parsed.blockCount == 4)
        #expect(parsed.blocks == [0xC001, 0x0001, 0x0001, 0xC002])
        #expect(parsed.groups == ["Sunset – ColorAnalyze"])
        #expect(parsed.swatches.map(\.name) == ["1 – #FF8000", "2 – #003366"])
        #expect(parsed.swatches.allSatisfy { $0.model == "RGB " && $0.type == 2 })
        #expect(parsed.swatches[0].rgb == [1, 0.5, 0])
        #expect(abs(parsed.swatches[1].rgb[2] - 0.4) < 1e-6)
    }

    @Test func colorsOutsideSRGBAreClamped() throws {
        let data = AdobeSwatchExchange.data(groupName: "g", swatches: [("wide", SRGBColor(r: 1.2, g: -0.1, b: 0.5))])
        let parsed = try #require(Self.parse(data))
        #expect(parsed.swatches[0].rgb == [1, 0, 0.5])
    }

    @Test func anEmptyPaletteIsStillAValidFile() throws {
        let parsed = try #require(Self.parse(AdobeSwatchExchange.data(groupName: "empty", swatches: [])))
        #expect(parsed.blocks == [0xC001, 0xC002] && parsed.swatches.isEmpty)
    }
}

@Suite struct ImageFolderTests {
    /// A folder with photos, sidecars, a hidden file and a subfolder.
    static func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageFolderTests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["IMG_10.jpg", "IMG_2.JPG", "IMG_1.orf", "shot.png", "notes.txt", "IMG_1.orf.dop",
                     "session.coloranalyze.json", ".hidden.jpg", "sub/deep.jpg"] {
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    @Test func listsPhotosInNaturalOrderWithoutSidecarsOrSubfolders() throws {
        let root = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ImageFolder.images(in: root).map(\.lastPathComponent) == ["IMG_1.orf", "IMG_2.JPG", "IMG_10.jpg", "shot.png"])
    }

    @Test func expandingKeepsFilesAndReplacesFolders() throws {
        let root = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let loose = URL(fileURLWithPath: "/elsewhere/a.heic")
        let expanded = ImageFolder.expand([loose, root, root.appendingPathComponent("IMG_2.JPG")])
        #expect(expanded.map(\.lastPathComponent) == ["a.heic", "IMG_1.orf", "IMG_2.JPG", "IMG_10.jpg", "shot.png"])   // IMG_2 once
        #expect(ImageFolder.expand([]).isEmpty)
        #expect(ImageFolder.images(in: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func recognizesImageTypesByExtension() {
        for name in ["a.jpg", "a.JPEG", "a.png", "a.heic", "a.tif", "a.orf", "a.cr2", "a.dng"] {
            #expect(ImageFolder.isImage(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
        for name in ["a.txt", "a.json", "a.dop", "a", "a.xmp", "a.preset"] {
            #expect(!ImageFolder.isImage(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
    }
}

@Suite struct MissingColorTests {
    /// 100×100 blue water with a 6×4 red boat and a pale band of sky along the top (10%).
    static let scene: PixelBuffer = {
        let water = SRGBColor(r: 0.15, g: 0.3, b: 0.5), boat = SRGBColor(r: 0.85, g: 0.15, b: 0.1)
        let sky = SRGBColor(r: 0.95, g: 0.75, b: 0.5)
        var linear: [SIMD3<Float>] = []
        for y in 0..<100 {
            for x in 0..<100 {
                let isBoat = (60..<66).contains(x) && (70..<74).contains(y)
                linear.append((isBoat ? boat : y < 10 ? sky : water).linear)
            }
        }
        return PixelBuffer(width: 100, height: 100, linear: linear)
    }()

    @Test func findsTheColorThatNoMarkerRepresents() throws {
        let water = SRGBColor(r: 0.15, g: 0.3, b: 0.5).oklab
        let found = try #require(DominantColorAnalyzer.findMissingColor(in: Self.scene, existing: [water]))
        // The sky band is the biggest unrepresented patch; it must come before the tiny boat.
        let sky = SRGBColor(r: 0.95, g: 0.75, b: 0.5).oklab
        #expect(ColorMath.distanceSquared(found.centroid, sky) < 0.01 * 0.01)
        #expect(found.location.y < 0.10 && found.share > 0.09)
    }

    @Test func eachSuggestionIsADifferentColorUntilNothingIsLeft() throws {
        var markers = [SRGBColor(r: 0.15, g: 0.3, b: 0.5).oklab]
        var found: [DominantColor] = []
        while let next = DominantColorAnalyzer.findMissingColor(in: Self.scene, existing: markers), found.count < 5 {
            found.append(next)
            markers.append(next.centroid)
        }
        // Sky first, then the small boat; after that every pixel is close to a marker color.
        #expect(found.count == 2)
        let boat = SRGBColor(r: 0.85, g: 0.15, b: 0.1).oklab
        #expect(ColorMath.distanceSquared(found[1].centroid, boat) < 0.02 * 0.02)
        #expect(abs(found[1].location.x - 0.63) < 0.05 && abs(found[1].location.y - 0.72) < 0.05)
    }

    @Test func aFlatPhotoHasNothingMissing() {
        let flat = PixelBuffer(width: 20, height: 20, linear: [SIMD3<Float>](repeating: SRGBColor(r: 0.4, g: 0.5, b: 0.6).linear, count: 400))
        #expect(DominantColorAnalyzer.findMissingColor(in: flat, existing: [SRGBColor(r: 0.4, g: 0.5, b: 0.6).oklab]) == nil)
    }

    @Test func withoutMarkersItReturnsTheMainColor() throws {
        let found = try #require(DominantColorAnalyzer.findMissingColor(in: Self.scene, existing: []))
        #expect(found.share > 0.8)
    }
}

@Suite struct HSLSuggestionTests {
    @Test func ringShiftFollowsDxOsAxisNotTheSRGBCircle() {
        // On PhotoLab's axis pure sRGB red sits at 13.8° and sRGB orange (30°) at 32.1°: 30° of sRGB hue are 18.3° of ring here,
        // but 61.3° − 32.1° = 29.2° from orange to yellow.
        let toOrange = DxOHue.ringShift(fromSRGBHue: 0, bySRGBShift: 30)
        #expect(abs(toOrange - 18.28) < 0.1)
        #expect(abs(DxOHue.ringShift(fromSRGBHue: 30, bySRGBShift: 30) - 29.24) < 0.1)
        // The other direction is the same distance, negated; no shift is no shift.
        let back = DxOHue.ringShift(fromSRGBHue: 30, bySRGBShift: -30)
        #expect(abs(back + toOrange) < 1e-3)
        #expect(DxOHue.ringShift(fromSRGBHue: 123, bySRGBShift: 0) == 0)
    }

    @Test func aColorsRingShiftDependsOnItsOwnSaturation() throws {
        // The same 20° of sRGB hue is a different distance for a saturated color than for a faint one.
        let strong = try #require(DxOHue.ringShift(of: .fromHSB(h: 0, s: 1, b: 1), bySRGBShift: 20))
        let faint = try #require(DxOHue.ringShift(of: .fromHSB(h: 0, s: 0.4, b: 0.8), bySRGBShift: 20))
        #expect(strong > 0 && faint > 0 && abs(strong - faint) > 0.5)
        #expect(DxOHue.ringShift(of: SRGBColor(r: 0.5, g: 0.5, b: 0.5), bySRGBShift: 20) == nil)
    }

    @Test func ringShiftWrapsAroundRed() {
        // 350° → 10° on the sRGB circle is +20°, not −340°, on the ring too.
        let shift = DxOHue.ringShift(fromSRGBHue: 350, bySRGBShift: 20)
        #expect(shift > 0 && shift < 40)
        #expect(DxOHue.ringShift(fromSRGBHue: 10, bySRGBShift: -20) < 0)
    }

    @Test func aPositiveShiftIsCounterClockwiseOnTheRingForEveryChannel() {
        for hue in stride(from: 0.0, to: 360, by: 15) {
            #expect(DxOHue.ringShift(fromSRGBHue: hue, bySRGBShift: 10) > 0, "hue \(hue)")
        }
    }

    static func color(hue: Double, s: Double = 0.7, b: Double = 0.8) -> SRGBColor { SRGBColor.fromHSB(h: hue, s: s, b: b) }

    @Test func groupsColorsByChannelWeightedByShare() throws {
        let inputs = [
            HSLSuggestion.Input(number: 1, color: Self.color(hue: 25), share: 0.30, hueShift: 8),
            HSLSuggestion.Input(number: 2, color: Self.color(hue: 35), share: 0.10, hueShift: -4),
            HSLSuggestion.Input(number: 3, color: Self.color(hue: 215), share: 0.20, hueShift: -10),
        ]
        let channels = HSLSuggestion.channels(from: inputs)
        #expect(channels.map(\.channel) == [.orange, .blue])
        let orange = try #require(channels.first)
        #expect(orange.colors == [1, 2])
        // The big color pulls the mean toward +: (0.3 × +8 + 0.1 × −4) / 0.4 ≈ +5 sRGB degrees, a bit more on the ring.
        #expect(orange.hueShift > 4 && orange.hueShift < 9)
        #expect(orange.range.lowerBound < 0 && orange.range.upperBound > 0)
        #expect(!orange.isMixed)
        #expect(try #require(channels.last).hueShift < -8 && #require(channels.last).hueShift > -10)   // 10° of sRGB blue is ~9° on the ring
    }

    @Test func leavesOutNeutralsSmallShiftsAndColorsWithoutATarget() {
        let inputs = [
            HSLSuggestion.Input(number: 1, color: SRGBColor(r: 0.5, g: 0.5, b: 0.5), share: 0.4, hueShift: 30),    // neutral
            HSLSuggestion.Input(number: 2, color: Self.color(hue: 120), share: 0.3, hueShift: 0.5),               // already there
            HSLSuggestion.Input(number: 3, color: Self.color(hue: 200), share: 0.3, hueShift: nil),               // no target
        ]
        #expect(HSLSuggestion.channels(from: inputs).isEmpty)
        #expect(HSLSuggestion.channels(from: []).isEmpty)
    }

    @Test func flagsChannelsWhoseColorsWantOppositeShifts() throws {
        let inputs = [
            HSLSuggestion.Input(number: 1, color: Self.color(hue: 100), share: 0.2, hueShift: 25),
            HSLSuggestion.Input(number: 2, color: Self.color(hue: 130), share: 0.2, hueShift: -25),
            HSLSuggestion.Input(number: 3, color: Self.color(hue: 110), share: 0.3, hueShift: 15),
        ]
        let green = try #require(HSLSuggestion.channels(from: inputs).first)
        #expect(green.channel == .green && green.isMixed && green.colors == [1, 2, 3])
    }
}

@Suite struct GradePreviewTests {
    /// What the plan makes of an 8-bit sRGB color, as 8-bit sRGB.
    static func graded(_ rgb: [Int], _ settings: GradePreviewSettings) -> [Int] {
        let color = SRGBColor(r: Double(rgb[0]) / 255, g: Double(rgb[1]) / 255, b: Double(rgb[2]) / 255)
        let linear = color.linear
        let out = SRGBColor(linear: GradePreview.Plan(settings).applyLinear(linear: linear, lab: ColorMath.linearToOKLab(linear))).clamped
        return [Int((out.r * 255).rounded()), Int((out.g * 255).rounded()), Int((out.b * 255).rounded())]
    }

    static func gray(_ v: Int) -> [Int] { [v, v, v] }

    /// Every channel within `tolerance` of PhotoLab's value.
    static func close(_ a: [Int], _ b: [Int], _ tolerance: Int) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }

    // The expected values below were measured with PhotoLab 10.1 on calibration/chart.jpg (see calibration/).

    @Test func noSettingsChangeNothing() {
        let plan = GradePreview.Plan(GradePreviewSettings())
        for color in [SRGBColor(r: 0.2, g: 0.3, b: 0.6).oklab, SRGBColor(r: 0.9, g: 0.5, b: 0.1).oklab] {
            #expect(plan.apply(color) == color)
        }
        #expect(GradePreviewSettings().isIdentity)
        #expect(!GradePreviewSettings(midtones: .init(dxoHue: 30, saturation: 5)).isIdentity)
        #expect(Self.graded([200, 80, 40], GradePreviewSettings()) == [200, 80, 40])
    }

    @Test func tintsFollowPhotoLabOnTheGrayRamp() {
        let blue = GradePreviewSettings.Tint(dxoHue: 231, saturation: 100)
        #expect(Self.close(Self.graded(Self.gray(0x30), .init(shadows: blue)), [0x22, 0x2E, 0x4A], 3))
        #expect(Self.close(Self.graded(Self.gray(0x80), .init(midtones: blue)), [0x70, 0x7E, 0xA1], 3))
        #expect(Self.close(Self.graded(Self.gray(0xC0), .init(highlights: blue)), [0xB5, 0xBF, 0xD8], 3))
    }

    @Test func tonesStayInTheirOwnRange() {
        let blue = GradePreviewSettings.Tint(dxoHue: 231, saturation: 100)
        // Black and white never move, and a shadows tint leaves the highlights alone.
        for tint in [GradePreviewSettings(shadows: blue), GradePreviewSettings(midtones: blue), GradePreviewSettings(highlights: blue)] {
            #expect(Self.graded(Self.gray(0), tint) == [0, 0, 0])
            #expect(Self.graded(Self.gray(255), tint) == [255, 255, 255])
        }
        #expect(Self.close(Self.graded(Self.gray(0xF0), .init(shadows: blue)), Self.gray(0xF0), 1))
        #expect(Self.close(Self.graded(Self.gray(0x10), .init(highlights: blue)), Self.gray(0x10), 1))
    }

    @Test func threeRangesAddUpAndColorsFollowToo() {
        // Shadows 36°, midtones 312° (both Saturation 100) and highlights 104° at 50.
        let combo = GradePreviewSettings(shadows: .init(dxoHue: 36, saturation: 100), midtones: .init(dxoHue: 312, saturation: 100),
                                         highlights: .init(dxoHue: 104, saturation: 50))
        #expect(Self.close(Self.graded(Self.gray(0x30), combo), [0x4C, 0x25, 0x1C], 8))   // the dark blue channel is the least exact: 7/255
        #expect(Self.close(Self.graded(Self.gray(0x80), combo), [0xAD, 0x69, 0x85], 3))
        #expect(Self.close(Self.graded(Self.gray(0xE0), combo), [0xDA, 0xE4, 0xD9], 3))
        // Saturated colors too: this is why the tint is a curve per channel in a wide-gamut space, not one color added.
        #expect(Self.close(Self.graded([0xCD, 0x3D, 0x3D], combo), [0xE0, 0x16, 0x2C], 8))
        #expect(Self.close(Self.graded([0xCD, 0xCC, 0x3E], combo), [0xCE, 0xCD, 0x32], 8))
        #expect(Self.close(Self.graded([0x3C, 0x3D, 0xCD], combo), [0x68, 0x2B, 0xC8], 8))
        #expect(Self.close(Self.graded([0xA8, 0x3D, 0xCB], combo), [0xC6, 0x17, 0xC6], 8))
    }

    @Test func luminanceOfTheWheelsFollowsPhotoLab() {
        // Luminance +60, one wheel at a time, on a gray in the middle of its range (calibration/exports F2…F5).
        #expect(Self.close(Self.graded(Self.gray(0x30), .init(shadows: .init(luminance: 60))), Self.gray(0x3F), 2))
        #expect(Self.close(Self.graded(Self.gray(0x80), .init(midtones: .init(luminance: 60))), Self.gray(0x93), 2))
        #expect(Self.close(Self.graded(Self.gray(0xC0), .init(highlights: .init(luminance: 60))), Self.gray(0xCE), 2))
        #expect(Self.close(Self.graded(Self.gray(0x80), .init(master: .init(luminance: 60))), Self.gray(0x9D), 2))
        // A negative value does the opposite, a little less (F6).
        #expect(Self.close(Self.graded(Self.gray(0xC0), .init(highlights: .init(luminance: -60))), Self.gray(0xB2), 3))
        #expect(!GradePreviewSettings(midtones: .init(luminance: 5)).isIdentity)
    }

    @Test func selectiveToneBlacksAndShadowsFollowPhotoLab() {
        // Light palette, measured with PhotoLab 10.1 (calibration/exports T series): greys 0x20, 0x30, 0x50 and the red CD3D3D.
        let red = [0xCD, 0x3D, 0x3D]
        let cases: [(blacks: Double, shadows: Double, grays: [Int], red: [Int])] = [
            (100, 0, [0x4A, 0x57, 0x71], [0xE6, 0x53, 0x53]), (-100, 0, [0x00, 0x00, 0x03], [0x79, 0x19, 0x19]),
            (0, 100, [0x6B, 0x74, 0x84], [0xEC, 0x5E, 0x5E]), (0, -100, [0x01, 0x04, 0x0D], [0x60, 0x13, 0x13]),
            (60, 40, [0x59, 0x63, 0x78], [0xE8, 0x56, 0x56])]
        for c in cases {
            let settings = GradePreviewSettings(toneBlacks: c.blacks, toneShadows: c.shadows)
            for (gray, expected) in zip([0x20, 0x30, 0x50], c.grays) {
                #expect(Self.close(Self.graded(Self.gray(gray), settings), Self.gray(expected), 3))
            }
            #expect(Self.close(Self.graded(red, settings), c.red, c.blacks < 0 || c.shadows < 0 ? 40 : 24))   // colored: scaled by the gain of the channel mean; a crush is the least exact
        }
        // Black and white stay, a colored pixel keeps its hue, and the sliders do nothing at 0.
        #expect(Self.graded(Self.gray(0), .init(toneBlacks: 100)) == [0, 0, 0])
        #expect(Self.graded(Self.gray(255), .init(toneBlacks: 100, toneShadows: 100)) == [255, 255, 255])
        #expect(!GradePreviewSettings(toneBlacks: 5).isIdentity && GradePreviewSettings(toneBlacks: 0, toneShadows: 0).isIdentity)
    }

    @Test func masterIsAWheelOfItsOwn() {
        // Measured with PhotoLab 10.1 (calibration/exports F1, R1 and the M series), grey 0x80 and the saturated green 3CCC3E.
        let green = [0x3C, 0xCC, 0x3E]
        for (hue, gray, onGreen) in [(231.0, [0x67, 0x7D, 0xB2], [0x00, 0xCA, 0x77]), (36.0, [0xA4, 0x78, 0x52], [0x7E, 0xC7, 0x00]),
                                     (160.0, [0x00, 0x9E, 0x84], [0x00, 0xE0, 0x41]), (340.0, [0xC0, 0x5B, 0x7C], [0xA8, 0xB6, 0x3A])] {
            let settings = GradePreviewSettings(master: .init(dxoHue: hue, saturation: 100))
            #expect(Self.close(Self.graded(Self.gray(0x80), settings), gray, 3))
            #expect(Self.close(Self.graded(green, settings), onGreen, 12))      // saturated colors: the least exact
        }
        #expect(!GradePreviewSettings(master: .init(dxoHue: 231, saturation: 5)).isIdentity)
        // Saturation scales it, and between two measured hues it moves smoothly.
        let full = Self.graded(Self.gray(0x80), .init(master: .init(dxoHue: 100, saturation: 100)))
        let half = Self.graded(Self.gray(0x80), .init(master: .init(dxoHue: 100, saturation: 50)))
        #expect(abs((Double(half[1]) - 128) * 2 - (Double(full[1]) - 128)) < 14)
        let a = Self.graded(Self.gray(0x80), .init(master: .init(dxoHue: 240, saturation: 100)))
        let b = Self.graded(Self.gray(0x80), .init(master: .init(dxoHue: 244, saturation: 100)))
        #expect(Self.close(a, b, 6))
    }

    @Test func balanceMovesTheRangesButKeepsTheTotal() {
        let blue = GradePreviewSettings.Tint(dxoHue: 231, saturation: 100)
        let balance = 59.4377
        // Shadows: a positive Balance narrows them, a negative one widens them (calibration/exports B1, B2).
        #expect(Self.close(Self.graded(Self.gray(0x30), .init(shadows: blue, balance: balance)), [0x26, 0x2F, 0x45], 3))
        #expect(Self.close(Self.graded(Self.gray(0x30), .init(shadows: blue, balance: -balance)), [0x1F, 0x2E, 0x4F], 3))
        // Highlights: the other way around (B3, B4).
        #expect(Self.close(Self.graded(Self.gray(0xC0), .init(highlights: blue, balance: balance)), [0xB2, 0xBE, 0xDF], 3))
        #expect(Self.close(Self.graded(Self.gray(0xC0), .init(highlights: blue, balance: -balance)), [0xB8, 0xBF, 0xD1], 3))
        // The three wheels together add up to the same at any Balance.
        let all = GradePreviewSettings(shadows: blue, midtones: blue, highlights: blue)
        var shifted = all
        shifted.balance = balance
        for v in [0x20, 0x60, 0xA0] {
            #expect(Self.close(Self.graded(Self.gray(v), all), Self.graded(Self.gray(v), shifted), 3))
        }
        // Balance on its own changes nothing.
        #expect(Self.graded([200, 80, 40], .init(balance: 80)) == [200, 80, 40])
    }

    @Test func hslSaturationAndLuminanceFollowPhotoLabApproximately() {
        // Green −80 takes most of the color out of a green patch (calibration/exports H1).
        let paleGreen = Self.graded([0x3C, 0xCC, 0x3E], .init(hslSaturation: [.green: -80]))
        #expect(Self.close(paleGreen, [0x99, 0xAF, 0x95], 14))
        // Purple +80 saturates a purple one.
        let strongPurple = Self.graded([0x85, 0x3E, 0xCC], .init(hslSaturation: [.purple: 80]))
        #expect(strongPurple[2] > 0xDD && strongPurple[1] < 0x3A)
        // Luminance −60 darkens blue, +60 lightens purple (H2): the size is only roughly right.
        let darkBlue = Self.graded([0x3C, 0x3D, 0xCD], .init(hslLuminance: [.blue: -60]))
        #expect(darkBlue[2] < 0xB0 && darkBlue[2] > 0x50)
        let lightPurple = Self.graded([0x85, 0x3E, 0xCC], .init(hslLuminance: [.purple: 60]))
        #expect(lightPurple[0] > 0xA0 && lightPurple[1] > 0x60)
        // Grays have no hue to work on.
        #expect(Self.graded(Self.gray(0x80), .init(hslSaturation: [.red: 100], hslLuminance: [.blue: 100])) == Self.gray(0x80))
    }

    @Test func saturationScalesLinearlyAndAmountExaggerates() {
        let half = GradePreviewSettings(midtones: .init(dxoHue: 231, saturation: 50))
        let full = GradePreviewSettings(midtones: .init(dxoHue: 231, saturation: 100))
        let doubled = GradePreviewSettings(midtones: .init(dxoHue: 231, saturation: 50), amount: 2)
        #expect(Self.close(Self.graded(Self.gray(0x80), doubled), Self.graded(Self.gray(0x80), full), 1))
        // The tint is added in linear light: half the Saturation pushes the blue channel half as far.
        func blue(_ rgb: [Int]) -> Double { Double(SRGBColor(r: Double(rgb[0]) / 255, g: Double(rgb[1]) / 255, b: Double(rgb[2]) / 255).linear.z) }
        let base = blue(Self.gray(0x80))
        let ratio = (blue(Self.graded(Self.gray(0x80), full)) - base) / (blue(Self.graded(Self.gray(0x80), half)) - base)
        #expect(abs(ratio - 2) < 0.15, "ratio \(ratio)")
    }

    @Test func theHueDirectionTurnsAroundTheCircleAndWrapsCleanly() {
        for hue in stride(from: 0.0, to: 360, by: 10) {
            let direction = GradePreview.direction(forHue: hue)
            #expect(direction.x.isFinite && direction.y.isFinite && direction.z.isFinite)
            #expect(abs(direction.x) <= 1.3 && abs(direction.y) <= 1.3 && abs(direction.z) <= 1.3)
        }
        // Exact at a measured hue, and continuous across 0°/360°.
        let blue = GradePreview.direction(forHue: 231)
        #expect(abs(blue.z - 1) < 1e-4 && abs(blue.x + 0.247) < 1e-3)
        let before = GradePreview.direction(forHue: 359.9), after = GradePreview.direction(forHue: 0.1)
        #expect(abs(before.x - after.x) < 0.01 && abs(before.z - after.z) < 0.01)
    }

    @Test func hueTurnsFollowPhotoLabsRingAndKeepLightness() {
        // The sample of calibration/E9: Red +25.6, Green +28.6, Cyan −19.2, Blue +27.1, Magenta −27.1.
        let shifts = GradePreviewSettings(hueShifts: [.red: 25.5866, .green: 28.5536, .cyan: -19.2093, .blue: 27.1425, .magenta: -27.1258])
        #expect(Self.close(Self.graded([0xCD, 0x3D, 0x3D], shifts), [0xA7, 0x5D, 0x15], 8))
        #expect(Self.close(Self.graded([0xCD, 0xCC, 0x3E], shifts), [0x88, 0xDD, 0x50], 8))
        #expect(Self.close(Self.graded([0x3C, 0x3D, 0xCD], shifts), [0x8C, 0x0C, 0xBB], 14))   // the least exact of the four
        #expect(Self.close(Self.graded([0xA8, 0x3D, 0xCB], shifts), [0xA8, 0x3D, 0xCB], 2))      // purple is untouched
        #expect(Self.graded(Self.gray(0x80), shifts) == Self.gray(0x80))                            // so are greys
        // Lightness stays where it was.
        let before = SRGBColor(r: 0.8, g: 0.24, b: 0.24).oklab.x
        let after = SRGBColor(r: Double(Self.graded([0xCC, 0x3D, 0x3D], shifts)[0]) / 255, g: Double(Self.graded([0xCC, 0x3D, 0x3D], shifts)[1]) / 255,
                              b: Double(Self.graded([0xCC, 0x3D, 0x3D], shifts)[2]) / 255).oklab.x
        #expect(abs(before - after) < 0.03)
    }

    @Test func aHueTurnMovesTheColorsPhotoLabHueByThatManyDegrees() throws {
        let orange = SRGBColor.fromHSB(h: 25, s: 0.8, b: 0.9)
        let plan = GradePreviewSettings(hueShifts: [.orange: 8])
        let out = Self.graded([Int((orange.r * 255).rounded()), Int((orange.g * 255).rounded()), Int((orange.b * 255).rounded())], plan)
        let turned = SRGBColor(r: Double(out[0]) / 255, g: Double(out[1]) / 255, b: Double(out[2]) / 255)
        let moved = ColorMath.signedAngle(from: try #require(DxOHue.hue(of: orange)), to: try #require(DxOHue.hue(of: turned)))
        #expect(moved > 5 && moved < 10)                              // orange is nearly all of this color; 8° is what it gets
        // A shift of another channel does not reach it.
        let far = Self.graded([Int((orange.r * 255).rounded()), Int((orange.g * 255).rounded()), Int((orange.b * 255).rounded())],
                              GradePreviewSettings(hueShifts: [.blue: 20]))
        #expect(Self.close(far, [Int((orange.r * 255).rounded()), Int((orange.g * 255).rounded()), Int((orange.b * 255).rounded())], 1))
    }

    @Test func aShiftFadesOutBetweenChannels() throws {
        let plan = GradePreviewSettings(hueShifts: [.orange: 10])
        func moved(sRGBHue: Double) throws -> Double {
            let c = SRGBColor.fromHSB(h: sRGBHue, s: 0.8, b: 0.9)
            let out = Self.graded([Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())], plan)
            let t = SRGBColor(r: Double(out[0]) / 255, g: Double(out[1]) / 255, b: Double(out[2]) / 255)
            return ColorMath.signedAngle(from: try #require(DxOHue.hue(of: c)), to: try #require(DxOHue.hue(of: t)))
        }
        let center = try moved(sRGBHue: 30), edge = try moved(sRGBHue: 42), outside = try moved(sRGBHue: 70)
        #expect(center > 8 && edge > 0.5 && edge < center && abs(outside) < 0.5)
    }

    @Test func rendersAnImageOfTheSameSize() throws {
        let side = 16
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let source = try #require(ctx.makeImage())
        let tinted = try #require(GradePreview.render(source, settings: .init(midtones: .init(dxoHue: 36, saturation: 100))))
        #expect(tinted.width == side && tinted.height == side)
        let pixel = [UInt8](tinted.dataProvider!.data! as Data)
        let r = Int(pixel[0]), b = Int(pixel[2])
        #expect(r > b + 20)                                              // a warm tint on a grey: red above blue
        let plain = try #require(GradePreview.render(source, settings: .init()))
        let flat = [UInt8](plain.dataProvider!.data! as Data)
        let original = [UInt8](source.dataProvider!.data! as Data)
        #expect(abs(Int(flat[0]) - Int(original[0])) <= 1 && abs(Int(flat[2]) - Int(original[2])) <= 1)   // identity survives the round trip
    }
}

@Suite struct GradingOptimizerTests {
    static func input(_ hue: Double, _ s: Double, _ b: Double, share: Double, target: Double) -> ColorGradingSuggestion.Input {
        .init(color: .fromHSB(h: hue, s: s, b: b), share: share, targetHue: target)
    }

    /// Foliage that should be greener, skin a little warmer, sky a little bluer.
    static let scene: [ColorGradingSuggestion.Input] = [
        input(100, 0.5, 0.45, share: 0.5, target: 120), input(20, 0.45, 0.8, share: 0.2, target: 25), input(210, 0.3, 0.7, share: 0.3, target: 200)]

    @Test func bringsTheColorsClearlyCloserThanTheHeuristicDoes() throws {
        let heuristic = ColorGradingSuggestion.suggest(from: Self.scene, strength: .moderate)
        let optimized = ColorGradingSuggestion.optimized(from: Self.scene, strength: .moderate)
        let fit = try #require(optimized.fit)
        #expect(fit.before > 10)
        #expect(fit.after < fit.before * 0.5)
        // The heuristic's wheels, judged by the same model, are far less effective.
        let problem = GradingProblem(inputs: Self.scene, cap: ColorGradingSuggestion.Strength.moderate.maxSaturation)
        var p: [Double] = []
        for wheel in [heuristic.preset.shadows, heuristic.preset.midtones, heuristic.preset.highlights] { p += [Double(wheel.hue), Double(wheel.saturation), 0] }
        p += [0, 0, 0, 0, 0]
        #expect(problem.meanErrors(p).after > fit.after + 3)
    }

    @Test func staysWithinTheStrengthAndKeepsRangesWithoutColorsNeutral() {
        for strength in ColorGradingSuggestion.Strength.allCases {
            let s = ColorGradingSuggestion.optimized(from: Self.scene, strength: strength)
            for wheel in [s.preset.shadows, s.preset.midtones, s.preset.highlights] {
                #expect(Double(wheel.saturation) <= strength.maxSaturation + 0.5)
                #expect(abs(Double(wheel.luminance)) <= strength.maxSaturation + 0.5 && (0..<360).contains(wheel.hue))
            }
            // The scene has mid-range colors only: shadows and highlights have none.
            #expect(s.preset.shadows == .neutral && s.preset.highlights == .neutral)
            #expect(abs(s.preset.balance) <= 50)
        }
        #expect(ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong).preset.midtones.saturation
                >= ColorGradingSuggestion.optimized(from: Self.scene, strength: .subtle).preset.midtones.saturation)
    }

    /// The cast (OKLab a, b) a grey of this lightness gets from a suggestion, by the calibrated model.
    static func cast(of s: ColorGradingSuggestion.Suggestion, lightness: Float) -> SIMD2<Float> {
        func tint(_ w: ColorGradingPreset.Wheel) -> GradePreviewSettings.Tint {
            .init(dxoHue: Double(w.hue), saturation: Double(w.saturation), luminance: Double(w.luminance))
        }
        let plan = GradePreview.Plan(GradePreviewSettings(shadows: tint(s.preset.shadows), midtones: tint(s.preset.midtones),
                                                          highlights: tint(s.preset.highlights), master: tint(s.preset.master),
                                                          balance: Double(s.preset.balance)))
        let lab = plan.apply(SIMD3(lightness, 0, 0))
        return SIMD2(lab.y, lab.z)
    }

    @Test func aStyleGivesShadowsAndHighlightsTheirCast() {
        let warm = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong, style: .warmHighlights)
        let cool = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong, style: .coolHighlights)
        // OKLab b: negative is blue, positive is yellow/orange.
        #expect(Self.cast(of: warm, lightness: 0.25).y < -0.008)       // cool shadows
        #expect(Self.cast(of: warm, lightness: 0.82).y > 0.006)        // warm highlights
        #expect(Self.cast(of: cool, lightness: 0.82).y < -0.008)       // cool highlights
        #expect(Self.cast(of: cool, lightness: 0.25).y > 0.004)        // warm shadows
        // The neutral style leaves the greys alone, as before.
        let neutral = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong)
        #expect(abs(Self.cast(of: neutral, lightness: 0.25).y) < 0.004 && abs(Self.cast(of: neutral, lightness: 0.82).y) < 0.004)
        #expect(ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong, style: .neutral) == neutral)
    }

    @Test func theOtherStylesDoWhatTheirNamesSay() {
        func lab(_ s: ColorGradingSuggestion.Suggestion, _ lightness: Float) -> SIMD3<Float> {
            func tint(_ w: ColorGradingPreset.Wheel) -> GradePreviewSettings.Tint {
                .init(dxoHue: Double(w.hue), saturation: Double(w.saturation), luminance: Double(w.luminance))
            }
            return GradePreview.Plan(GradePreviewSettings(shadows: tint(s.preset.shadows), midtones: tint(s.preset.midtones),
                                                          highlights: tint(s.preset.highlights), master: tint(s.preset.master),
                                                          balance: Double(s.preset.balance)))
                .apply(SIMD3(lightness, 0, 0))
        }
        let teal = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong, style: .tealOrange)
        #expect(lab(teal, 0.25).y < -0.008 && lab(teal, 0.25).z < -0.006)          // teal: green-blue, both a and b negative
        #expect(lab(teal, 0.82).z > 0.008)                                         // orange highlights
        let warm = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong, style: .warmOverall)
        let cool = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong, style: .coolOverall)
        for l: Float in [0.25, 0.55, 0.82] {
            #expect(lab(warm, l).z > 0.005)
            #expect(lab(cool, l).z < -0.007)
        }
        // The cast of the whole photo is carried by the Master wheel; the other styles do not use it.
        #expect(warm.preset.master.saturation > 0 && cool.preset.master.saturation > 0)
        #expect(Double(warm.preset.master.saturation) <= ColorGradingSuggestion.Strength.strong.maxSaturation + 0.5)
        let faded = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong, style: .faded)
        func fadedLightness(_ l: Float) -> Float {
            func tint(_ w: ColorGradingPreset.Wheel) -> GradePreviewSettings.Tint {
                .init(dxoHue: Double(w.hue), saturation: Double(w.saturation), luminance: Double(w.luminance))
            }
            return GradePreview.Plan(GradePreviewSettings(shadows: tint(faded.preset.shadows), midtones: tint(faded.preset.midtones),
                                                          highlights: tint(faded.preset.highlights), master: tint(faded.preset.master),
                                                          balance: Double(faded.preset.balance),
                                                          toneBlacks: Double(faded.toneBlacks), toneShadows: Double(faded.toneShadows)))
                .apply(SIMD3(l, 0, 0)).x
        }
        #expect(fadedLightness(0.12) > 0.12 + 0.03)                                // the darks are lighter, down to the deep shadows
        #expect(fadedLightness(0.25) > 0.25 + 0.03)
        #expect(abs(fadedLightness(0.55) - 0.55) < 0.03 && abs(fadedLightness(0.82) - 0.82) < 0.03)   // the rest stays
        #expect(faded.toneBlacks > 0)                                              // done with the Light palette's Blacks
        #expect(teal.toneBlacks == 0 && warm.toneBlacks == 0)
        #expect(teal.preset.master == .neutral && faded.preset.master == .neutral)
        // Every style stays within the strength.
        for style in GradingStyle.allCases {
            let s = ColorGradingSuggestion.optimized(from: Self.scene, strength: .subtle, style: style)
            for wheel in [s.preset.shadows, s.preset.midtones, s.preset.highlights] {
                #expect(Double(wheel.saturation) <= ColorGradingSuggestion.Strength.subtle.maxSaturation + 0.5)
                #expect(abs(Double(wheel.luminance)) <= ColorGradingSuggestion.Strength.subtle.maxSaturation + 0.5)
            }
        }
    }

    @Test func aStyleStaysWithinTheStrengthAndKeepsTheColorsClose() throws {
        for strength in ColorGradingSuggestion.Strength.allCases {
            let s = ColorGradingSuggestion.optimized(from: Self.scene, strength: strength, style: .warmHighlights)
            for wheel in [s.preset.shadows, s.preset.midtones, s.preset.highlights] {
                #expect(Double(wheel.saturation) <= strength.maxSaturation + 0.5)
            }
            let fit = try #require(s.fit)
            #expect(fit.after < fit.before)          // still brings the colors toward their targets
        }
        // A style also works for ranges without colors (the scene has none in the shadows or highlights).
        let s = ColorGradingSuggestion.optimized(from: Self.scene, strength: .moderate, style: .warmHighlights)
        #expect(s.preset.shadows.saturation > 0 && s.preset.highlights.saturation > 0)
        // And with nothing but greys.
        let greys = [ColorGradingSuggestion.Input(color: SRGBColor(r: 0.5, g: 0.5, b: 0.5), share: 1, targetHue: 0)]
        #expect(ColorGradingSuggestion.optimized(from: greys, strength: .moderate, style: .warmHighlights).preset.highlights.saturation > 0)
    }

    @Test func luminanceAndBalanceAreNotNoise() {
        // They are used only when they bring the colors clearly closer: for the plain scene they stay at 0.
        for strength in ColorGradingSuggestion.Strength.allCases {
            let p = ColorGradingSuggestion.optimized(from: Self.scene, strength: strength).preset
            #expect(p.balance == 0 && p.master == .neutral)
            #expect([p.shadows, p.midtones, p.highlights].allSatisfy { $0.luminance == 0 })
        }
    }

    @Test func leavesColorsThatAreOnTargetAlone() {
        let onTarget = [Self.input(30, 0.6, 0.7, share: 0.5, target: 30), Self.input(210, 0.5, 0.5, share: 0.5, target: 210)]
        let s = ColorGradingSuggestion.optimized(from: onTarget, strength: .strong)
        #expect(s.preset == ColorGradingPreset())
        #expect(s.fit.map { $0.before < 1 && $0.after < 1 } == true)
    }

    @Test func doesNotTurnGreysIntoACast() {
        // The same scene plus a big grey wall: the tint must now stay small where the wall is.
        let withGrey = Self.scene + [ColorGradingSuggestion.Input(color: SRGBColor(r: 0.5, g: 0.5, b: 0.5), share: 0.6, targetHue: 0)]
        let without = ColorGradingSuggestion.optimized(from: Self.scene, strength: .strong)
        let with = ColorGradingSuggestion.optimized(from: withGrey, strength: .strong)
        #expect(with.preset.midtones.saturation < without.preset.midtones.saturation)
    }

    @Test func isDeterministicAndHandlesNoColors() {
        let a = ColorGradingSuggestion.optimized(from: Self.scene, strength: .moderate)
        let b = ColorGradingSuggestion.optimized(from: Self.scene, strength: .moderate)
        #expect(a == b)
        #expect(ColorGradingSuggestion.optimized(from: [], strength: .moderate).preset == ColorGradingPreset())
        let greys = [ColorGradingSuggestion.Input(color: SRGBColor(r: 0.5, g: 0.5, b: 0.5), share: 1, targetHue: 0)]
        #expect(ColorGradingSuggestion.optimized(from: greys, strength: .strong).preset == ColorGradingPreset())
    }
}
