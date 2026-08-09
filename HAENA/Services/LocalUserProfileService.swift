import Foundation

enum LocalUserProfileError: Error, Equatable, Sendable {
    case nameMissing
    /// The chosen participant is not in any stored meeting. Refused rather than stored, so the
    /// profile cannot accumulate links to people who were never there.
    case unknownParticipant
    case storageFailure
}

/// Every write to the local profile goes through here: naming yourself, and saying which meeting
/// participants are you.
///
/// Read paths stay elsewhere — `MyWorkPolicy` decides what is mine, `ParticipantDirectory` builds
/// the list to choose from. This type only validates and persists.
///
/// `now`/`makeID` are injected (defaulting to `Date.init`/`UUID.init`) so tests can supply fixed
/// values, matching the other capture services.
struct LocalUserProfileService: Sendable {
    let profileRepository: any LocalUserProfileRepository
    let projectRepository: any ProjectRepository
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        profileRepository: any LocalUserProfileRepository,
        projectRepository: any ProjectRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.profileRepository = profileRepository
        self.projectRepository = projectRepository
        self.now = now
        self.makeID = makeID
    }

    // MARK: - Reading

    func profile() async throws -> LocalUserProfile? {
        do {
            return try await profileRepository.profile()
        } catch {
            throw LocalUserProfileError.storageFailure
        }
    }

    /// The participants the user can choose from, with the project and meeting each came from.
    func directory() async throws -> [ParticipantDirectoryEntry] {
        let projects = try await loadProjects()
        let profile = try await profile()
        return ParticipantDirectory.entries(in: projects, profile: profile)
    }

    // MARK: - Naming

    /// Creates the profile on first use and renames it afterwards — the user never has to think
    /// about which of those they are doing.
    @discardableResult
    func setDisplayName(_ name: String) async throws -> LocalUserProfile {
        guard let validated = LocalUserProfile.validatedName(name) else {
            throw LocalUserProfileError.nameMissing
        }

        let timestamp = now()
        var profile = try await profile() ?? LocalUserProfile(
            id: makeID(),
            displayName: validated,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        _ = profile.rename(to: validated, at: timestamp)
        try await persist(profile)
        return profile
    }

    // MARK: - Linking

    /// Links one or more participants to the user in a single step.
    ///
    /// Several at once because identifying yourself genuinely means naming several records — one
    /// per meeting you attended — and making that a row-at-a-time chore invites the user to give up
    /// halfway, which leaves "my work" quietly incomplete.
    ///
    /// Requires a profile to already exist: there is no "me" to link to before the user has said
    /// who they are.
    @discardableResult
    func link(participantIDs: [UUID]) async throws -> LocalUserProfile {
        guard var profile = try await profile() else {
            throw LocalUserProfileError.nameMissing
        }
        guard !participantIDs.isEmpty else {
            return profile
        }

        let known = ParticipantDirectory.knownParticipantIDs(in: try await loadProjects())
        guard participantIDs.allSatisfy({ known.contains($0) }) else {
            throw LocalUserProfileError.unknownParticipant
        }

        profile.link(participantIDs, at: now())
        try await persist(profile)
        return profile
    }

    /// Always allowed, and deliberately not validated against stored meetings: a link to a
    /// participant whose meeting has since been deleted is exactly the one a user most needs to be
    /// able to remove.
    @discardableResult
    func unlink(participantID: UUID) async throws -> LocalUserProfile {
        guard var profile = try await profile() else {
            throw LocalUserProfileError.nameMissing
        }
        profile.unlink(participantID, at: now())
        try await persist(profile)
        return profile
    }

    // MARK: - Private

    private func loadProjects() async throws -> [Project] {
        do {
            return try await projectRepository.allProjects()
        } catch {
            throw LocalUserProfileError.storageFailure
        }
    }

    private func persist(_ profile: LocalUserProfile) async throws {
        do {
            try await profileRepository.save(profile)
        } catch {
            throw LocalUserProfileError.storageFailure
        }
    }
}
