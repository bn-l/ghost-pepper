import Foundation

struct KeyChord: Codable, Hashable {
    let keys: Set<PhysicalKey>

    private enum CodingKeys: String, CodingKey {
        case keys
    }

    init?(keys: Set<PhysicalKey>) {
        guard !keys.isEmpty else { return nil }
        self.keys = keys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = try container.decode(Set<PhysicalKey>.self, forKey: .keys)

        guard !keys.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .keys, in: container, debugDescription: "Key chords cannot be empty.")
        }

        self.keys = keys
    }

    var displayString: String {
        sortedKeysForDisplay()
            .map(\.displayName)
            .joined(separator: " + ")
    }

    var shortcutRecorderDisplayString: String {
        sortedKeysForDisplay()
            .map(\.shortcutRecorderDisplayName)
            .joined(separator: " + ")
    }

    private func sortedKeysForDisplay() -> [PhysicalKey] {
        keys.sorted {
            if $0.sortOrder == $1.sortOrder {
                if $0.displayName == $1.displayName {
                    return $0.keyCode < $1.keyCode
                }

                return $0.displayName < $1.displayName
            }

            return $0.sortOrder < $1.sortOrder
        }
    }
}
