import Foundation

/// Internal failure reasons for audio-file meeting capture. Kept separate from user-facing Korean
/// copy so the service stays presentation-agnostic and unit-testable.
enum AudioMeetingCaptureError: Error, Equatable, Sendable {
    case noProjectSelected
    case projectNameMissing
    case meetingTitleMissing
    case projectNotFound
    case invalidFile(AudioFileValidationError)
    case storageFailure
    case transcriptionFailed(TranscriptionError)
    case repositoryFailure
}

/// Imports one audio file as a `.audioFile` `Meeting`: validate, copy locally, transcribe, then
/// persist.
///
/// The ordering is the design. The user's file is copied into app storage *before* the network
/// call, and the meeting is written *after* it returns — so a provider outage leaves a complete
/// local audio file to retry from and not a single incomplete record in the project. Nothing
/// here converts, compresses, or splits audio, and nothing writes to the project until there is
/// a real transcript to write.
///
/// `now`/`makeID` are injected (defaulting to `Date.init`/`UUID.init`) so tests can supply fixed
/// values instead of depending on wall-clock time or random UUIDs.
struct AudioMeetingCaptureService: Sendable {
    let repository: any ProjectRepository
    let provider: any TranscriptionProvider
    let validator: AudioFileValidator
    let assetStore: AudioAssetStore
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        repository: any ProjectRepository,
        provider: any TranscriptionProvider,
        assetStore: AudioAssetStore,
        validator: AudioFileValidator = AudioFileValidator(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.provider = provider
        self.assetStore = assetStore
        self.validator = validator
        self.now = now
        self.makeID = makeID
    }

    // MARK: - Project selection

    func allProjects() async throws -> [Project] {
        try await repository.allProjects()
    }

    /// Creates and persists a new project, so a user importing their first recording does not
    /// have to leave the flow to make somewhere to put it.
    @discardableResult
    func createProject(name: String) async throws -> Project {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AudioMeetingCaptureError.projectNameMissing
        }

        let timestamp = now()
        let project = Project(
            id: makeID(),
            name: trimmedName,
            summary: "",
            createdAt: timestamp,
            updatedAt: timestamp,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
        do {
            try await repository.save(project)
        } catch {
            throw AudioMeetingCaptureError.repositoryFailure
        }
        return project
    }

    // MARK: - Validation

    /// Exposed so the UI can reject a file the moment it is chosen, before showing any progress.
    func validate(fileURL: URL) throws -> ValidatedAudioFile {
        do {
            return try validator.validate(fileURL)
        } catch let error as AudioFileValidationError {
            throw AudioMeetingCaptureError.invalidFile(error)
        } catch {
            throw AudioMeetingCaptureError.invalidFile(.notReadable)
        }
    }

    // MARK: - Import

    /// `sourceType` defaults to `.audioFile`, so every existing caller is unaffected. A microphone
    /// recording passes `.microphone` — by the time it reaches here it is simply a local audio
    /// file, and the rest of the pipeline is deliberately identical.
    @discardableResult
    func importAudioMeeting(
        projectID: UUID?,
        title: String,
        fileURL: URL,
        sourceType: MeetingSourceType = .audioFile
    ) async throws -> Meeting {
        guard let projectID else {
            throw AudioMeetingCaptureError.noProjectSelected
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw AudioMeetingCaptureError.meetingTitleMissing
        }

        let file = try validate(fileURL: fileURL)

        // Checked before the upload as well as after it: discovering the project is gone only
        // after a ten-minute file has been transcribed would waste the request and the user's time.
        guard try await loadProject(projectID) != nil else {
            throw AudioMeetingCaptureError.projectNotFound
        }

        // Step 1: the app's own copy, made before anything can fail over the network. From here
        // on a retry never depends on the user's original file still being where it was.
        let asset: AudioAsset
        do {
            asset = try assetStore.store(file, id: makeID(), importedAt: now())
        } catch {
            throw AudioMeetingCaptureError.storageFailure
        }

        // Step 2: transcription. On failure the stored copy is deliberately left in place, and
        // no meeting has been created yet, so the project is untouched.
        let result: TranscriptionResult
        do {
            result = try await provider.transcribe(
                TranscriptionRequest(
                    fileURL: assetStore.url(for: asset),
                    fileName: asset.storedFileName,
                    byteSize: asset.byteSize
                )
            )
        } catch let error as TranscriptionError {
            throw AudioMeetingCaptureError.transcriptionFailed(error)
        } catch {
            throw AudioMeetingCaptureError.transcriptionFailed(.networkUnavailable)
        }

        // Steps 3-4: meeting and segments, built entirely in memory.
        let meeting = makeMeeting(
            projectID: projectID,
            title: trimmedTitle,
            asset: asset,
            result: result,
            sourceType: sourceType
        )

        // Step 5: persist. The project is re-read rather than reused, because transcription may
        // have taken minutes and the copy fetched before the upload is now stale.
        guard var project = try await loadProject(projectID) else {
            throw AudioMeetingCaptureError.projectNotFound
        }
        project.meetings.append(meeting)
        project.updatedAt = now()
        do {
            try await repository.save(project)
        } catch {
            throw AudioMeetingCaptureError.repositoryFailure
        }

        return meeting
    }

    // MARK: - Building

    private func makeMeeting(
        projectID: UUID,
        title: String,
        asset: AudioAsset,
        result: TranscriptionResult,
        sourceType: MeetingSourceType
    ) -> Meeting {
        let timestamp = now()
        let meetingID = makeID()
        let mapping = TranscriptSpeakerMapper.map(result.segments, makeID: makeID)

        // One stored segment per provider utterance — never per word. The provider's own
        // segmentation is what the extractor later cites as evidence.
        let segments = result.segments.map { segment in
            TranscriptSegment(
                id: makeID(),
                meetingID: meetingID,
                speakerID: mapping.participantID(forLabel: segment.speakerLabel),
                sourceSpeakerLabel: segment.speakerLabel,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }

        return Meeting(
            id: meetingID,
            projectID: projectID,
            title: title,
            occurredAt: timestamp,
            sourceType: sourceType,
            participants: mapping.participants,
            transcriptSegments: segments,
            createdAt: timestamp,
            audioAsset: asset
        )
    }

    private func loadProject(_ id: UUID) async throws -> Project? {
        do {
            return try await repository.project(id: id)
        } catch {
            throw AudioMeetingCaptureError.repositoryFailure
        }
    }
}
