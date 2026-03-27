import Foundation

struct TranscriptionLabEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let createdAt: Date
    let audioFileName: String
    let audioDuration: TimeInterval
    let windowContext: OCRContext?
    let rawTranscription: String?
    let correctedTranscription: String?
    let speechModelID: String
    let cleanupModelName: String
    let cleanupUsedFallback: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case audioFileName
        case audioDuration
        case windowContents
        case rawTranscription
        case correctedTranscription
        case speechModelID
        case cleanupModelName
        case cleanupUsedFallback
    }

    init(
        id: UUID = UUID(),
        createdAt: Date,
        audioFileName: String,
        audioDuration: TimeInterval,
        windowContext: OCRContext?,
        rawTranscription: String?,
        correctedTranscription: String?,
        speechModelID: String,
        cleanupModelName: String,
        cleanupUsedFallback: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFileName = audioFileName
        self.audioDuration = audioDuration
        self.windowContext = windowContext
        self.rawTranscription = rawTranscription
        self.correctedTranscription = correctedTranscription
        self.speechModelID = speechModelID
        self.cleanupModelName = cleanupModelName
        self.cleanupUsedFallback = cleanupUsedFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        audioDuration = try container.decode(TimeInterval.self, forKey: .audioDuration)
        if let windowContents = try container.decodeIfPresent(String.self, forKey: .windowContents) {
            windowContext = OCRContext(windowContents: windowContents)
        } else {
            windowContext = nil
        }
        rawTranscription = try container.decodeIfPresent(String.self, forKey: .rawTranscription)
        correctedTranscription = try container.decodeIfPresent(String.self, forKey: .correctedTranscription)
        speechModelID = try container.decode(String.self, forKey: .speechModelID)
        cleanupModelName = try container.decode(String.self, forKey: .cleanupModelName)
        cleanupUsedFallback = try container.decode(Bool.self, forKey: .cleanupUsedFallback)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(audioFileName, forKey: .audioFileName)
        try container.encode(audioDuration, forKey: .audioDuration)
        try container.encodeIfPresent(windowContext?.windowContents, forKey: .windowContents)
        try container.encodeIfPresent(rawTranscription, forKey: .rawTranscription)
        try container.encodeIfPresent(correctedTranscription, forKey: .correctedTranscription)
        try container.encode(speechModelID, forKey: .speechModelID)
        try container.encode(cleanupModelName, forKey: .cleanupModelName)
        try container.encode(cleanupUsedFallback, forKey: .cleanupUsedFallback)
    }
}
