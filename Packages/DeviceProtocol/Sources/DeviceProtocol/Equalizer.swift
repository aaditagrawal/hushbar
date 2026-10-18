import Foundation

public struct CustomEQParameters: Decodable, Sendable {
    public let freqLow: Float, qLow: Float, freqPeak: Float, qPeak: Float, freqHigh: Float, qHigh: Float
    public var flat: EqualizerProfile {
        .init(totalGain: -0.0, bands: [
            .init(filter: 1, gain: 0, frequency: freqPeak, quality: qPeak),
            .init(filter: 2, gain: 0, frequency: freqHigh, quality: qHigh),
            .init(filter: 0, gain: 0, frequency: freqLow, quality: qLow)
        ])
    }
}
public struct EqualizerBand: Equatable, Sendable {
    public var filter: UInt8
    public var gain: Float, frequency: Float, quality: Float
    public init(filter: UInt8 = 1, gain: Float = 0, frequency: Float, quality: Float = 1) {
        self.filter = filter; self.gain = gain; self.frequency = frequency; self.quality = quality
    }
}
/// The APK EQEntity carries profile, total gain and filter metadata. Keep all of it,
/// including read-back frequency/Q values that differ from bundled defaults.
public struct EqualizerProfile: Equatable, Sendable {
    public var profile: UInt8
    public var totalGain: Float
    public var bands: [EqualizerBand]
    public init(profile: UInt8 = 0, totalGain: Float, bands: [EqualizerBand]) {
        self.profile = profile; self.totalGain = totalGain; self.bands = bands
    }
    public static let frequencies: [Float] = [55, 110, 220, 440, 1320, 3300, 6600, 13200]
    public static let frequencyRanges: [ClosedRange<Double>] = [20...99, 100...199, 200...399, 400...999, 1000...2999, 3000...5999, 6000...11999, 12000...20000]
    public static var flatAdvanced: Self { .init(totalGain: -6, bands: frequencies.map { .init(frequency: $0) }) }
    public func validated(advanced: Bool) -> Bool {
        guard totalGain.isFinite, (-100...20).contains(totalGain),
              advanced ? (1...8).contains(bands.count) : bands.count == 3 else { return false }
        if !advanced && Set(bands.map(\.filter)) != Set([UInt8(0), 1, 2]) { return false }
        return bands.allSatisfy { $0.filter <= 2 && $0.gain.isFinite && (-6...6).contains($0.gain) && $0.frequency.isFinite && (20...20000).contains($0.frequency) && $0.quality.isFinite && (0.1...10).contains($0.quality) }
    }
    public func encoded(advanced: Bool) -> [UInt8] {
        var bytes: [UInt8] = advanced ? [profile, UInt8(bands.count)] : [UInt8(bands.count)]
        bytes += Self.floatBytes(totalGain)
        for band in bands {
            bytes.append(band.filter)
            bytes += Self.floatBytes(band.gain) + Self.floatBytes(band.frequency) + Self.floatBytes(band.quality)
        }
        // SimpleEQEntity uses packed 13-byte bands. The JS app appends 3 zero bytes
        // per band after the records; accept that padding on reads, send APK layout.
        return bytes
    }
    public static func decode(_ bytes: [UInt8], advanced: Bool) -> Self? {
        let start = advanced ? 2 : 1
        guard bytes.count >= start + 4 else { return nil }
        let count = Int(bytes[start - 1])
        guard (1...8).contains(count), bytes.count == start + 4 + 13 * count || (!advanced && bytes.count == start + 4 + 16 * count && bytes.suffix(3 * count).allSatisfy { $0 == 0 }) else { return nil }
        var bands: [EqualizerBand] = []
        for i in 0..<count {
            let offset = start + 4 + i * 13
            bands.append(.init(filter: bytes[offset], gain: float(bytes, offset + 1), frequency: float(bytes, offset + 5), quality: float(bytes, offset + 9)))
        }
        let value = Self(profile: advanced ? bytes[0] : 0, totalGain: float(bytes, start), bands: bands)
        return value.validated(advanced: advanced) ? value : nil
    }
    public func matches(_ other: Self?) -> Bool {
        guard let other, profile == other.profile, abs(totalGain - other.totalGain) < 0.01, bands.count == other.bands.count else { return false }
        return zip(bands, other.bands).allSatisfy { a, b in
            a.filter == b.filter && abs(a.gain - b.gain) < 0.05 && abs(a.frequency - b.frequency) < 1 && abs(a.quality - b.quality) < 0.01
        }
    }
    private static func floatBytes(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
    }
    private static func float(_ bytes: [UInt8], _ offset: Int) -> Float {
        let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        return Float(bitPattern: bits)
    }
}
