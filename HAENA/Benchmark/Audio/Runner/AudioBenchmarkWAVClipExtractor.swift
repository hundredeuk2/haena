import AVFoundation
import AudioToolbox
import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// The source location needed to materialize one authorized benchmark clip.
///
/// This value is intentionally not `Codable`: source paths and frame offsets are runtime-only
/// capabilities and must never enter a benchmark report.
enum AudioBenchmarkPCMSampleEncoding: String, Equatable, Sendable {
    case signedInteger
    case unsignedInteger
    case floatingPoint
}

struct AudioBenchmarkWAVFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let bitDepth: UInt32
    let sampleEncoding: AudioBenchmarkPCMSampleEncoding
}

struct AudioBenchmarkSourceClip: Equatable, Sendable {
    let sourceWAVURL: URL
    let startFrame: AVAudioFramePosition
    let frameCount: AVAudioFrameCount
    let expectedFormat: AudioBenchmarkWAVFormat

    /// Derived from integer frame count and the authorized source's expected sample rate. Callers
    /// never need to round a duration copied from gold metadata to construct a clip.
    var durationSeconds: Double {
        Double(frameCount) / expectedFormat.sampleRate
    }
}

enum AudioBenchmarkClipExtractionError: String, Error, Equatable, Sendable {
    case invalidSourceType
    case sourceMissing
    case sourceUnreadable
    case invalidAudioFormat
    case sampleFormatMismatch
    case invalidFrameRange
    case temporaryDirectoryUnavailable
    case clipWriteFailed
    case temporaryCleanupFailed
}

/// Creates exactly one anonymous WAV clip at a time and removes it before returning.
///
/// A private namespace below the system temporary directory acts like `mktemp -d`: every case gets
/// a fresh UUID directory and the filename is always `clip.wav`. Neither the corpus case id nor the
/// source recording title can leak into a temporary pathname.
struct AudioBenchmarkWAVClipExtractor: @unchecked Sendable {
    static let namespaceName = "haena-audio-benchmark-v0"
    static let staleDirectoryPrefix = "run-"

    let temporaryRootURL: URL
    let fileManager: FileManager
    let now: @Sendable () -> Date
    let makeNonce: @Sendable () -> String
    let staleAge: TimeInterval
    let maximumStaleRemovals: Int

    init(
        temporaryRootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.namespaceName, isDirectory: true),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        makeNonce: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        staleAge: TimeInterval = 24 * 60 * 60,
        maximumStaleRemovals: Int = 32
    ) {
        self.temporaryRootURL = temporaryRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
        self.makeNonce = makeNonce
        self.staleAge = staleAge
        self.maximumStaleRemovals = max(0, maximumStaleRemovals)
    }

    /// Materializes the requested frame range, executes `operation`, then removes the entire
    /// anonymous case directory on both success and failure. A cleanup failure overrides a provider
    /// result because leaving corpus audio behind is not a successful benchmark case.
    func withTemporaryClip<Result: Sendable>(
        _ sourceClip: AudioBenchmarkSourceClip,
        operation: @escaping @Sendable (URL, Double) async throws -> Result
    ) async throws -> Result {
        try prepareRootAndCleanStaleDirectories()
        let caseDirectory = try makeUniqueCaseDirectory()
        let clipURL = caseDirectory.appendingPathComponent("clip.wav", isDirectory: false)

        let operationResult: Swift.Result<Result, Error>
        do {
            let duration = try materialize(sourceClip, at: clipURL)
            operationResult = .success(try await operation(clipURL, duration))
        } catch {
            operationResult = .failure(error)
        }

        do {
            try fileManager.removeItem(at: caseDirectory)
        } catch {
            throw AudioBenchmarkClipExtractionError.temporaryCleanupFailed
        }

        return try operationResult.get()
    }

    // MARK: Temporary directory lifecycle

    private func prepareRootAndCleanStaleDirectories() throws {
        do {
            try fileManager.createDirectory(
                at: temporaryRootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try cleanStaleDirectories()
        } catch {
            throw AudioBenchmarkClipExtractionError.temporaryDirectoryUnavailable
        }
    }

    private func makeUniqueCaseDirectory() throws -> URL {
        for _ in 0..<4 {
            let nonce = makeNonce()
            guard Self.isSafeNonce(nonce) else {
                continue
            }
            let candidate = temporaryRootURL
                .appendingPathComponent(Self.staleDirectoryPrefix + nonce, isDirectory: true)
                .standardizedFileURL
            guard candidate.deletingLastPathComponent() == temporaryRootURL else {
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw AudioBenchmarkClipExtractionError.temporaryDirectoryUnavailable
            }
        }
        throw AudioBenchmarkClipExtractionError.temporaryDirectoryUnavailable
    }

    private static func isSafeNonce(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
                .contains($0)
        }
    }

    /// Deletes at most `maximumStaleRemovals` old direct children per invocation. The bounded scan
    /// prevents a damaged temp namespace from turning benchmark startup into an unbounded delete.
    private func cleanStaleDirectories() throws {
        guard maximumStaleRemovals > 0 else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: temporaryRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let cutoff = now().addingTimeInterval(-max(0, staleAge))
        let stale = try urls.compactMap { url -> (URL, Date)? in
            let standardized = url.standardizedFileURL
            guard standardized.deletingLastPathComponent() == temporaryRootURL,
                  standardized.lastPathComponent.hasPrefix(Self.staleDirectoryPrefix) else {
                return nil
            }
            let values = try standardized.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else {
                return nil
            }
            return (standardized, modified)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }
        .prefix(maximumStaleRemovals)

        for (url, _) in stale {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: WAV validation and extraction

    private func materialize(_ sourceClip: AudioBenchmarkSourceClip, at destinationURL: URL) throws -> Double {
        guard sourceClip.sourceWAVURL.pathExtension.lowercased() == "wav" else {
            throw AudioBenchmarkClipExtractionError.invalidSourceType
        }
        guard sourceClip.startFrame >= 0, sourceClip.frameCount > 0,
              sourceClip.expectedFormat.sampleRate.isFinite,
              sourceClip.expectedFormat.sampleRate > 0,
              sourceClip.expectedFormat.channelCount > 0,
              sourceClip.expectedFormat.bitDepth > 0 else {
            throw AudioBenchmarkClipExtractionError.invalidFrameRange
        }

        guard fileManager.fileExists(atPath: sourceClip.sourceWAVURL.path) else {
            throw AudioBenchmarkClipExtractionError.sourceMissing
        }

        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: sourceClip.sourceWAVURL)
        } catch {
            throw AudioBenchmarkClipExtractionError.sourceUnreadable
        }

        let processingFormat = source.processingFormat
        let fileDescription = source.fileFormat.streamDescription.pointee
        let sampleRate = fileDescription.mSampleRate
        guard fileDescription.mFormatID == kAudioFormatLinearPCM,
              sampleRate.isFinite, sampleRate > 0,
              fileDescription.mChannelsPerFrame > 0,
              fileDescription.mBitsPerChannel > 0,
              source.length > 0 else {
            throw AudioBenchmarkClipExtractionError.invalidAudioFormat
        }

        let actualEncoding: AudioBenchmarkPCMSampleEncoding
        if fileDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            actualEncoding = .floatingPoint
        } else if fileDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            actualEncoding = .signedInteger
        } else {
            actualEncoding = .unsignedInteger
        }
        guard abs(sampleRate - sourceClip.expectedFormat.sampleRate) < 0.000_001,
              fileDescription.mChannelsPerFrame == sourceClip.expectedFormat.channelCount,
              fileDescription.mBitsPerChannel == sourceClip.expectedFormat.bitDepth,
              actualEncoding == sourceClip.expectedFormat.sampleEncoding else {
            throw AudioBenchmarkClipExtractionError.sampleFormatMismatch
        }

        let (endFrame, overflow) = sourceClip.startFrame.addingReportingOverflow(
            AVAudioFramePosition(sourceClip.frameCount)
        )
        guard !overflow, endFrame <= source.length else {
            throw AudioBenchmarkClipExtractionError.invalidFrameRange
        }

        let actualDuration = sourceClip.durationSeconds

        do {
            source.framePosition = sourceClip.startFrame
            var output: AVAudioFile? = try AVAudioFile(
                forWriting: destinationURL,
                settings: source.fileFormat.settings,
                commonFormat: processingFormat.commonFormat,
                interleaved: processingFormat.isInterleaved
            )

            var remaining = sourceClip.frameCount
            while remaining > 0 {
                let capacity = min(remaining, 4_096)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else {
                    throw AudioBenchmarkClipExtractionError.invalidAudioFormat
                }
                try source.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength == capacity else {
                    throw AudioBenchmarkClipExtractionError.invalidFrameRange
                }
                try output?.write(from: buffer)
                remaining -= capacity
            }
            output = nil // finalize the WAV header before the provider is allowed to open it

            let verification = try AVAudioFile(forReading: destinationURL)
            let verifiedDescription = verification.fileFormat.streamDescription.pointee
            guard verification.length == AVAudioFramePosition(sourceClip.frameCount),
                  verifiedDescription.mFormatID == kAudioFormatLinearPCM,
                  verifiedDescription.mChannelsPerFrame == fileDescription.mChannelsPerFrame,
                  verifiedDescription.mBitsPerChannel == fileDescription.mBitsPerChannel,
                  abs(verifiedDescription.mSampleRate - sampleRate) < 0.000_001 else {
                throw AudioBenchmarkClipExtractionError.clipWriteFailed
            }
        } catch let error as AudioBenchmarkClipExtractionError {
            throw error
        } catch {
            throw AudioBenchmarkClipExtractionError.clipWriteFailed
        }

        return actualDuration
    }
}
