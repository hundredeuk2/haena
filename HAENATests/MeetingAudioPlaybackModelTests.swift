import XCTest
@testable import HAENA

/// Covers every playback state and failure through the deterministic player, so the whole control
/// surface is verified on a machine that never opens an audio device.
@MainActor
final class MeetingAudioPlaybackModelTests: XCTestCase {
    private static let fileURL = URL(fileURLWithPath: "/tmp/haena-playback-tests/recording.m4a")

    private func makeModel(
        _ behavior: DeterministicMeetingAudioPlayer.Behavior = .succeeds,
        duration: TimeInterval = 12
    ) -> (MeetingAudioPlaybackModel, DeterministicMeetingAudioPlayer) {
        let player = DeterministicMeetingAudioPlayer(behavior: behavior, duration: duration)
        return (MeetingAudioPlaybackModel(player: player, fileURL: Self.fileURL), player)
    }

    // MARK: - Loading

    func testLoadingReportsDurationAndStartsStoppedAtZero() async {
        let (model, _) = makeModel(duration: 95)
        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.duration, 95)
        XCTAssertEqual(model.currentTime, 0)
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.errorMessage)
    }

    /// A redraw must not reopen the file or restart anything.
    func testLoadingTwiceOpensTheFileOnce() async {
        let (model, player) = makeModel()
        await model.load()
        await model.load()

        let loads = await player.loadCount
        XCTAssertEqual(loads, 1)
    }

    // MARK: - Play, pause, restart

    func testPlayThenPauseKeepsThePosition() async {
        let (model, player) = makeModel(duration: 20)
        await model.load()

        await model.togglePlayPause()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertTrue(model.isPlaying)

        await player.advance(by: 6)
        await model.tick()
        XCTAssertEqual(model.currentTime, 6)

        await model.togglePlayPause()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentTime, 6, "Pausing must not rewind what has been heard.")

        let pauses = await player.pauseCount
        XCTAssertEqual(pauses, 1)
    }

    func testResumingAfterAPauseDoesNotRewind() async {
        let (model, player) = makeModel(duration: 20)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 5)
        await model.tick()
        await model.togglePlayPause()

        await model.togglePlayPause()

        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.currentTime, 5)
        let seeks = await player.seekCount
        XCTAssertEqual(seeks, 0, "Resuming is not restarting.")
    }

    func testRestartReturnsToTheBeginningAndKeepsPlaying() async {
        let (model, player) = makeModel(duration: 20)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 8)
        await model.tick()

        await model.restart()

        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.currentTime, 0)
        let seeks = await player.seekCount
        XCTAssertEqual(seeks, 1)
    }

    /// Restarting something that has not moved would do nothing, so the control stays off until it
    /// would have an effect.
    func testRestartIsOnlyOfferedOnceThereIsSomethingToRestart() async {
        let (model, player) = makeModel(duration: 20)
        XCTAssertFalse(model.canRestart, "Nothing is loaded yet.")

        await model.load()
        XCTAssertFalse(model.canRestart, "Loaded but still at the beginning.")

        await model.togglePlayPause()
        await player.advance(by: 3)
        await model.tick()
        XCTAssertTrue(model.canRestart)
    }

    // MARK: - Reaching the end

    func testPlaybackEndingOnItsOwnIsReportedAsFinished() async {
        let (model, player) = makeModel(duration: 10)
        await model.load()
        await model.togglePlayPause()

        await player.advance(by: 10)
        await model.tick()

        XCTAssertEqual(model.phase, .finished)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentTime, 10, "The readout must rest at the end, not snap to zero.")
    }

    func testPlayingAgainAfterTheEndStartsFromTheBeginning() async {
        let (model, player) = makeModel(duration: 10)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 10)
        await model.tick()

        await model.togglePlayPause()

        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.currentTime, 0)
        let seeks = await player.seekCount
        XCTAssertEqual(seeks, 1)
    }

    // MARK: - Ticking

    func testTickIsIgnoredWhileNotPlaying() async {
        let (model, _) = makeModel()
        await model.tick()
        XCTAssertEqual(model.phase, .idle)

        await model.load()
        await model.tick()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.currentTime, 0)
    }

    /// The readout comes from the player, never from counting ticks, so a delayed or dropped tick
    /// cannot make it drift away from what is actually being heard.
    func testElapsedTimeFollowsThePlayerRatherThanTheNumberOfTicks() async {
        let (model, player) = makeModel(duration: 30)
        await model.load()
        await model.togglePlayPause()

        await player.advance(by: 9)
        await model.tick()
        await model.tick()
        await model.tick()

        XCTAssertEqual(model.currentTime, 9)
    }

    // MARK: - Stopping

    func testStoppingSilencesThePlayerAndRewinds() async {
        let (model, player) = makeModel(duration: 20)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 4)
        await model.tick()

        await model.stop()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.currentTime, 0)
        let stops = await player.stopCount
        let playing = await player.isPlaying()
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(playing, "Leaving the screen must not leave audio running.")
    }

    /// Teardown runs on paths that may never have loaded anything, so it must be harmless there.
    func testStoppingBeforeAnythingLoadedIsHarmless() async {
        let (model, player) = makeModel(.fileMissing)
        await model.stop()

        XCTAssertEqual(model.phase, .idle)
        let stops = await player.stopCount
        XCTAssertEqual(stops, 1)
    }

    // MARK: - Failures

    func testMissingFileIsReportedAndLeavesTheControlsOff() async {
        let (model, _) = makeModel(.fileMissing)
        await model.load()

        XCTAssertEqual(model.phase, .failed(.fileMissing))
        XCTAssertFalse(model.isLoaded)
        XCTAssertFalse(model.canRestart)
        XCTAssertEqual(model.currentTime, 0)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("찾을 수 없습니다") == true)
    }

    func testCorruptFileIsReportedDistinctlyFromAMissingOne() async {
        let (model, _) = makeModel(.unreadableAudio)
        await model.load()

        XCTAssertEqual(model.phase, .failed(.unreadableAudio))
        XCTAssertTrue(model.errorMessage?.contains("재생할 수 없습니다") == true)
    }

    /// A failure to load must not hand the user dead controls that appear usable.
    func testPressingPlayAfterAFailureDoesNothing() async {
        let (model, player) = makeModel(.unreadableAudio)
        await model.load()

        await model.togglePlayPause()
        await model.restart()

        XCTAssertEqual(model.phase, .failed(.unreadableAudio))
        let plays = await player.playCount
        XCTAssertEqual(plays, 0)
    }

    func testAFailureToStartPlaybackIsReportedAndClearsTheClock() async {
        let (model, _) = makeModel(.playbackFails, duration: 15)
        await model.load()
        XCTAssertEqual(model.phase, .ready)

        await model.togglePlayPause()

        XCTAssertEqual(model.phase, .failed(.playbackFailed))
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentTime, 0, "A stalled clock beside an error would read as playing.")
    }

    func testRetryingAfterAFailureAttemptsTheFileAgain() async {
        let (model, player) = makeModel(.fileMissing)
        await model.load()
        await model.load()

        let loads = await player.loadCount
        XCTAssertEqual(loads, 2, "The retry button has to actually retry.")
        XCTAssertEqual(model.phase, .failed(.fileMissing))
    }

    // MARK: - Readout

    /// The playhead reads the same way as the transcript timestamps on the same screen, because it
    /// is the same formatter.
    func testTimeReadoutMatchesTheTranscriptTimestampFormat() async {
        let (model, player) = makeModel(duration: 3_725)
        await model.load()
        XCTAssertEqual(model.durationText, "01:02:05")
        XCTAssertEqual(model.currentTimeText, "00:00")

        await model.togglePlayPause()
        await player.advance(by: 65)
        await model.tick()
        XCTAssertEqual(model.currentTimeText, "01:05")
        XCTAssertEqual(model.currentTimeText, TranscriptTimestampFormatter.string(from: 65))
    }

    func testReadoutIsZeroBeforeAnythingIsLoaded() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.currentTimeText, "00:00")
        XCTAssertEqual(model.durationText, "00:00")
    }
}
