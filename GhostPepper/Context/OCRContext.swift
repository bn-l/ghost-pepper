import Foundation

struct OCRContext: Equatable, Sendable {
    let windowContents: String
    let sourceCharacterCount: Int
    let wasTruncated: Bool

    init(
        windowContents: String,
        sourceCharacterCount: Int? = nil,
        wasTruncated: Bool = false
    ) {
        self.windowContents = windowContents
        self.sourceCharacterCount = sourceCharacterCount ?? windowContents.count
        self.wasTruncated = wasTruncated
    }
}
