import Foundation

struct EQPreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var headphone: String
    var source: String
    var preamp: Float          // dB
    var bands: [EQBand]        // expected length: 10 (Klang's section count); shorter presets are padded with identity biquads

    enum CodingKeys: String, CodingKey {
        case id, name, headphone, source, preamp, bands
    }

    init(id: UUID = UUID(), name: String, headphone: String, source: String, preamp: Float, bands: [EQBand]) {
        self.id = id
        self.name = name
        self.headphone = headphone
        self.source = source
        self.preamp = preamp
        self.bands = bands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.headphone = try c.decode(String.self, forKey: .headphone)
        self.source = try c.decode(String.self, forKey: .source)
        self.preamp = try c.decode(Float.self, forKey: .preamp)
        self.bands = try c.decode([EQBand].self, forKey: .bands)
    }
}

extension EQPreset {
    /// The neutral "no correction" preset. Always available, even offline. Its
    /// canonical UUID is mirrored in `Klang/Resources/presets.json` so PresetStore
    /// can identify it as the bundled baseline.
    static let flatID = UUID(uuidString: "C1996F66-CC88-4D92-8511-7407391A0BE2")!

    static let flat = EQPreset(
        id: flatID,
        name: "Flat",
        headphone: "Any",
        source: "Klang",
        preamp: 0,
        bands: [
            EQBand(type: .lowShelf,  frequency: 100,   gain: 0, q: 0.71),
            EQBand(type: .peak,      frequency: 1000,  gain: 0, q: 1.0),
            EQBand(type: .peak,      frequency: 4000,  gain: 0, q: 1.0),
            EQBand(type: .highShelf, frequency: 10000, gain: 0, q: 0.71)
        ]
    )

    func sameContent(as other: EQPreset) -> Bool {
        guard name == other.name,
              headphone == other.headphone,
              source == other.source,
              preamp == other.preamp,
              bands.count == other.bands.count
        else { return false }
        for (a, b) in zip(bands, other.bands) {
            if a.type != b.type || a.frequency != b.frequency || a.gain != b.gain || a.q != b.q {
                return false
            }
        }
        return true
    }
}

/// Pair (old UUID, AutoEq slug) used to upgrade users from the in-file built-in
/// model to the network catalog without losing their selection.
struct LegacyMigrationEntry: Hashable {
    let legacyID: UUID
    let slug: String

    static let aryaStealthOratory1990 = LegacyMigrationEntry(
        legacyID: UUID(uuidString: "B2626DF3-DEDE-4EA6-A1C5-A34C0B320552")!,
        slug: "oratory1990/over-ear/HIFIMAN Arya Stealth Magnet Version"
    )

    /// All UUIDs that previous Klang versions seeded into `presets.json` and that
    /// should now live in the network catalog instead.
    static let all: [LegacyMigrationEntry] = [aryaStealthOratory1990]
}
