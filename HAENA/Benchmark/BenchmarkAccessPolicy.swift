import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

// MARK: - Errors

/// Why a benchmark run was refused before it could touch anything.
///
/// Every case is a *refusal*, never a warning. A benchmark whose sealed holdout has been read once
/// is permanently spent, and a dataset that has been shipped to a third party cannot be recalled;
/// neither outcome may be reachable by a run that merely logged a caution and carried on.
enum BenchmarkAccessError: Error, Equatable, Sendable {
    /// A sealed-holdout case was requested without an explicit unlock. Not a warning: the run fails.
    ///
    /// `caseIDs` lists the offending cases when specific ids were requested, and is empty when a
    /// whole sealed split was requested — naming every sealed case in that message would hand the
    /// operator part of the holdout's shape for free.
    case sealedHoldoutLocked(caseIDs: [String])
    case providerNotAllowed(provider: String)
    case networkNotAllowed(provider: String)
    case datasetTransferNotConfirmed(provider: String)
}

// MARK: - Provider selection

/// Which extractor a run drives, expressed as a permission subject rather than as a type.
///
/// The distinction that matters to the policy is not "which vendor" but "does this send the corpus
/// off this machine". `.offlineStub` cannot, so it is always allowed; everything else is `.external`
/// and has to clear the full authorization path below, whatever it is called.
enum BenchmarkProviderSelection: Equatable, Sendable {
    case offlineStub
    case external(identifier: String)

    /// The stable string recorded in `PredictionArtifact.provider`.
    var identifier: String {
        switch self {
        case .offlineStub:
            return "stub"
        case .external(let identifier):
            return identifier
        }
    }

    /// The stable string recorded in `PredictionArtifact.runMode`.
    var runMode: String {
        switch self {
        case .offlineStub:
            return "offline_stub"
        case .external:
            return "provider"
        }
    }
}

// MARK: - Policy

/// What this run is permitted to touch. Every field defaults to the safest value, so a policy
/// constructed with no arguments can read development cases only and can reach no network.
///
/// The defaults are the whole design. A harness is run from scripts, from CI, and from a terminal
/// at midnight; the cost of forgetting a flag must be a failed run, never a leaked holdout or an
/// unintended upload. Each permission is therefore opt-in, granted per run, and never persisted.
struct BenchmarkAccessPolicy: Equatable, Sendable {
    /// Permits reading `sealed_holdout` cases. Corresponds to `--unlock-sealed-holdout`.
    var unlockedSealedHoldout: Bool = false
    /// Permits an extractor that opens a socket. Corresponds to `--allow-network`.
    var allowNetwork: Bool = false
    /// Records that the operator accepted sending corpus text to a third party, which the dataset's
    /// terms make a separate decision from "may this process use the network at all".
    /// Corresponds to `--i-accept-dataset-transfer`.
    var datasetTransferConfirmed: Bool = false
    /// Providers this run may drive, by `BenchmarkProviderSelection.identifier`. Empty by default:
    /// consent to *transfer* is not consent to a *particular recipient*.
    var allowedProviders: Set<String> = []

    /// Development split, no network, no external provider — what an unconfigured run gets.
    static let offlineDefault = BenchmarkAccessPolicy()

    // MARK: - Splits

    /// Throws when any requested case sits in a split this run may not read.
    ///
    /// Takes source-index entries rather than case files on purpose: authorization has to be decidable
    /// from discovery metadata alone, because deciding it from the case file would mean opening the
    /// very file the policy exists to keep shut.
    func authorizeCases(_ entries: [BenchmarkSourceIndexEntry]) throws {
        guard !unlockedSealedHoldout else { return }

        var sealed: [String] = []
        for entry in entries where entry.split == .sealedHoldout {
            // Order of appearance, deduplicated: the message should read back as the caller's own
            // request rather than as an arbitrary set ordering.
            if !sealed.contains(entry.caseID) {
                sealed.append(entry.caseID)
            }
        }

        guard sealed.isEmpty else {
            throw BenchmarkAccessError.sealedHoldoutLocked(caseIDs: sealed)
        }
    }

    func authorizeSplit(_ split: BenchmarkSplit) throws {
        guard split == .sealedHoldout, !unlockedSealedHoldout else { return }
        throw BenchmarkAccessError.sealedHoldoutLocked(caseIDs: [])
    }

    // MARK: - Providers

    /// `provider` is `BenchmarkProviderSelection.identifier`. The offline stub always passes;
    /// anything else needs network permission, dataset-transfer confirmation, and an allow-list entry.
    ///
    /// The three conditions are checked in a fixed order — recipient, then network, then transfer
    /// consent — so each two-of-three combination fails with a distinct, actionable error instead of
    /// with whichever check happened to run first.
    func authorizeProvider(_ selection: BenchmarkProviderSelection) throws {
        guard case .external = selection else { return }
        let provider = selection.identifier

        guard allowedProviders.contains(provider) else {
            throw BenchmarkAccessError.providerNotAllowed(provider: provider)
        }
        guard allowNetwork else {
            throw BenchmarkAccessError.networkNotAllowed(provider: provider)
        }
        guard datasetTransferConfirmed else {
            throw BenchmarkAccessError.datasetTransferNotConfirmed(provider: provider)
        }
    }
}
