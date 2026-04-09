import Foundation

final class RecordingSessionCoordinator: @unchecked Sendable {
    typealias FinalizationResult = (filteredTranscript: String?, summary: DiarizationSummary)
    private enum FinishStrategy {
        case direct(() async -> FinalizationResult)
        case withSpans(([DiarizationSummary.Span]) async -> FinalizationResult)
    }

    private let appendAudioChunkHandler: ([Float]) -> Void
    private let finishStrategy: FinishStrategy

    private(set) var filteredTranscript: String?

    init(session: FluidAudioSpeechSession) {
        appendAudioChunkHandler = session.appendAudioChunk
        finishStrategy = .withSpans { spans in
            let result = await session.finalize(spans: spans)
            return (filteredTranscript: result.filteredTranscript, summary: result.summary)
        }
    }

    init(
        session: FluidAudioSpeechSession,
        processAudioChunk: @escaping ([Float]) -> Void,
        finish: @escaping () -> [DiarizationSummary.Span],
        cleanup: @escaping () -> Void = {}
    ) {
        appendAudioChunkHandler = { samples in
            session.appendAudioChunk(samples)
            processAudioChunk(samples)
        }
        finishStrategy = .direct {
            let result = await session.finalize(spans: finish())
            cleanup()
            return (filteredTranscript: result.filteredTranscript, summary: result.summary)
        }
    }

    init(
        appendAudioChunk: @escaping ([Float]) -> Void,
        finish: @escaping () async -> FinalizationResult
    ) {
        appendAudioChunkHandler = appendAudioChunk
        finishStrategy = .direct(finish)
    }

    func appendAudioChunk(_ samples: [Float]) {
        appendAudioChunkHandler(samples)
    }

    func finish() async -> DiarizationSummary {
        switch finishStrategy {
        case .direct(let finish):
            let result = await finish()
            filteredTranscript = result.filteredTranscript
            return result.summary
        case .withSpans:
            assertionFailure("finish() called on a spans-driven RecordingSessionCoordinator")
            return Self.invalidFinishSummary()
        }
    }

    func finish(spans: [DiarizationSummary.Span]) async -> DiarizationSummary {
        switch finishStrategy {
        case .withSpans(let finish):
            let result = await finish(spans)
            filteredTranscript = result.filteredTranscript
            return result.summary
        case .direct:
            return await finish()
        }
    }

    private static func invalidFinishSummary() -> DiarizationSummary {
        DiarizationSummary(
            spans: [],
            mergedKeptSpans: [],
            targetSpeakerID: nil,
            targetSpeakerDuration: 0,
            keptAudioDuration: 0,
            usedFallback: true,
            fallbackReason: .noUsableSpeakerSpans
        )
    }
}
