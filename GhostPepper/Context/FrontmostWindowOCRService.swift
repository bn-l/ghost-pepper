import CoreGraphics
import Foundation

final class FrontmostWindowOCRService: @unchecked Sendable {
    typealias PermissionProvider = @Sendable () -> Bool
    typealias TextRecognizer = @Sendable (CGImage, [String]) async throws -> String?
    private static let maximumWindowContentsCharacters = 4_000

    private let permissionProvider: PermissionProvider
    private let windowCaptureService: WindowCaptureServing
    private let recognizeText: TextRecognizer

    var logger: AppLogger?

    init(
        permissionProvider: @escaping PermissionProvider = { PermissionChecker.hasScreenRecordingPermission() },
        windowCaptureService: WindowCaptureServing = WindowCaptureService(),
        requestFactory: OCRRequestFactory = OCRRequestFactory()
    ) {
        self.permissionProvider = permissionProvider
        self.windowCaptureService = windowCaptureService
        self.recognizeText = { image, customWords in
            try requestFactory.recognizeText(in: image, customWords: customWords)
        }
    }

    init(
        permissionProvider: @escaping PermissionProvider,
        windowCaptureService: WindowCaptureServing,
        recognizeText: @escaping TextRecognizer
    ) {
        self.permissionProvider = permissionProvider
        self.windowCaptureService = windowCaptureService
        self.recognizeText = recognizeText
    }

    func captureContext(customWords: [String]) async -> OCRContext? {
        do {
            guard let image = try await windowCaptureService.captureFrontmostWindowImage() else {
                logger?.info("capture.empty", "Frontmost-window OCR produced no text.")
                return nil
            }

            guard !Task.isCancelled,
                  let text = try await recognizeText(image, customWords),
                  !Task.isCancelled else {
                logger?.info("capture.cancelled", "Frontmost-window OCR was cancelled before recognition completed.")
                return nil
            }

            logger?.info("capture.success", "Frontmost-window OCR captured text.")
            let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let boundedText = Self.boundedWindowContents(normalizedText)
            return OCRContext(
                windowContents: boundedText.contents,
                sourceCharacterCount: normalizedText.count,
                wasTruncated: boundedText.wasTruncated
            )
        } catch {
            if !permissionProvider() {
                logger?.warning(
                    "capture.permission_unavailable",
                    "Frontmost-window OCR failed while Screen Recording permission appears unavailable.",
                    error: error
                )
            } else {
                logger?.warning("capture.failed", "Frontmost-window OCR failed.", error: error)
            }
            return nil
        }
    }

    private static func boundedWindowContents(_ text: String) -> (contents: String, wasTruncated: Bool) {
        guard text.count > maximumWindowContentsCharacters else {
            return (text, false)
        }

        return (String(text.prefix(maximumWindowContentsCharacters)), true)
    }
}
