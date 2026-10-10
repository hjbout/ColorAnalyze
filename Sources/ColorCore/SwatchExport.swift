import Foundation

/// Adobe Swatch Exchange (`.ase`): the palette format that Photoshop, Illustrator, InDesign, Affinity and
/// many other tools read into their swatch panels.
///
/// Layout (all numbers big-endian): the signature `ASEF`, version 1.0 and the number of blocks; then one
/// block per entry — group start, one color per swatch, group end. A block is a 16-bit type, a 32-bit
/// length and the payload; names are UTF-16 with a terminating zero and a leading length in characters.
public enum AdobeSwatchExchange {
    public static let fileExtension = "ase"

    /// One group holding `swatches`, as sRGB colors (values outside the sRGB gamut are clamped).
    public static func data(groupName: String, swatches: [(name: String, color: SRGBColor)]) -> Data {
        var out = Data()
        out.append(contentsOf: Array("ASEF".utf8))
        out.append(uint16: 1)
        out.append(uint16: 0)
        out.append(uint32: UInt32(swatches.count + 2))

        var start = Data()
        start.appendName(groupName)
        out.appendBlock(type: 0xC001, payload: start)

        for swatch in swatches {
            let color = swatch.color.clamped
            var payload = Data()
            payload.appendName(swatch.name)
            payload.append(contentsOf: Array("RGB ".utf8))
            payload.append(float: Float(color.r))
            payload.append(float: Float(color.g))
            payload.append(float: Float(color.b))
            payload.append(uint16: 2)   // 0 = global, 1 = spot, 2 = normal
            out.appendBlock(type: 0x0001, payload: payload)
        }

        out.appendBlock(type: 0xC002, payload: Data())
        return out
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    mutating func append(float value: Float) {
        append(uint32: value.bitPattern)
    }

    /// Length in characters (including the terminating zero), then the characters as UTF-16, then the zero.
    mutating func appendName(_ name: String) {
        let units = Array(name.utf16)
        append(uint16: UInt16(units.count + 1))
        for unit in units { append(uint16: unit) }
        append(uint16: 0)
    }

    mutating func appendBlock(type: UInt16, payload: Data) {
        append(uint16: type)
        append(uint32: UInt32(payload.count))
        append(payload)
    }
}
