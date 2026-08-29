import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Atomic, report-only persistence. Runtime paths and transcripts never appear in any encoded type
/// accepted by this store.
struct AudioBenchmarkArtifactStore: @unchecked Sendable {
    static let configurationFileName = "run-configuration.json"
    static let aggregateFileName = "aggregate-report.json"

    let outputDirectoryURL: URL
    let fileManager: FileManager

    init(outputDirectoryURL: URL, fileManager: FileManager = .default) {
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func prepare(for configuration: AudioBenchmarkRunConfiguration) throws {
        guard configuration.isValid else {
            throw AudioBenchmarkRunError.invalidConfiguration
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: outputDirectoryURL.path, isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue {
            throw AudioBenchmarkRunError.outputDirectoryConflict
        }
        if !exists {
            do {
                try fileManager.createDirectory(
                    at: outputDirectoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw AudioBenchmarkRunError.outputWriteFailed
            }
        }

        let configurationURL = outputDirectoryURL.appendingPathComponent(Self.configurationFileName)
        if fileManager.fileExists(atPath: configurationURL.path) {
            let existing: AudioBenchmarkRunConfiguration
            do {
                existing = try AudioBenchmarkRunConfiguration.decoder.decode(
                    AudioBenchmarkRunConfiguration.self,
                    from: Data(contentsOf: configurationURL)
                )
            } catch {
                throw AudioBenchmarkRunError.resumeConfigurationMismatch
            }
            guard existing == configuration, existing.canonicalHash == configuration.canonicalHash else {
                throw AudioBenchmarkRunError.resumeConfigurationMismatch
            }
            return
        }

        let existingItems: [URL]
        do {
            existingItems = try fileManager.contentsOfDirectory(
                at: outputDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw AudioBenchmarkRunError.outputWriteFailed
        }
        guard existingItems.isEmpty else {
            throw AudioBenchmarkRunError.resumeConfigurationMissing
        }

        do {
            try AudioBenchmarkRunConfiguration.encoder.encode(configuration)
                .write(to: configurationURL, options: [.atomic])
        } catch {
            throw AudioBenchmarkRunError.outputWriteFailed
        }
    }

    func existingCaseReport(
        caseID: String,
        configuration: AudioBenchmarkRunConfiguration
    ) throws -> AudioBenchmarkCaseReport? {
        let url = caseReportURL(caseID: caseID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let report: AudioBenchmarkCaseReport
        do {
            report = try Self.decoder.decode(AudioBenchmarkCaseReport.self, from: Data(contentsOf: url))
        } catch {
            throw AudioBenchmarkRunError.resumeArtifactInvalid
        }
        guard report.caseID == caseID,
              report.split == .development,
              report.configurationHash == configuration.canonicalHash,
              report.providerID == configuration.providerID,
              report.modelID == configuration.modelID,
              report.metricSchemaVersion == configuration.metricSchemaVersion else {
            throw AudioBenchmarkRunError.resumeArtifactInvalid
        }
        return report
    }

    func write(_ report: AudioBenchmarkCaseReport) throws {
        do {
            try Self.encoder.encode(report)
                .write(to: caseReportURL(caseID: report.caseID), options: [.atomic])
        } catch {
            throw AudioBenchmarkRunError.outputWriteFailed
        }
    }

    func write(_ report: AudioBenchmarkAggregateReport) throws {
        do {
            try Self.encoder.encode(report)
                .write(
                    to: outputDirectoryURL.appendingPathComponent(Self.aggregateFileName),
                    options: [.atomic]
                )
        } catch {
            throw AudioBenchmarkRunError.outputWriteFailed
        }
    }

    func existingAggregateReport(
        configuration: AudioBenchmarkRunConfiguration
    ) throws -> AudioBenchmarkAggregateReport? {
        let url = outputDirectoryURL.appendingPathComponent(Self.aggregateFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let report: AudioBenchmarkAggregateReport
        do {
            report = try Self.decoder.decode(
                AudioBenchmarkAggregateReport.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw AudioBenchmarkRunError.resumeArtifactInvalid
        }
        guard report.configurationHash == configuration.canonicalHash,
              report.benchmark == configuration.benchmark else {
            throw AudioBenchmarkRunError.resumeArtifactInvalid
        }
        return report
    }

    private func caseReportURL(caseID: String) -> URL {
        outputDirectoryURL.appendingPathComponent(caseID + ".report.json", isDirectory: false)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
