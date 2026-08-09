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

    // MARK: - Pause must never become a rewind

    /// The defect this suite missed: a timer tick was in flight when the user pressed pause, saw a
    /// player that was no longer running, and called the file finished. The next press of play then
    /// started from the top.
    ///
    /// Every test above drove `tick()` and `togglePlayPause()` one strictly after the other, which
    /// is the one ordering the real app never guarantees.
    func testATickInFlightWhilePausingCannotTurnAPauseIntoARewind() async {
        let (model, player) = makeModel(duration: 20)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 7)

        async let ticking: Void = model.tick()
        await model.togglePlayPause()
        await ticking

        XCTAssertEqual(model.phase, .ready, "A pause is not a finish.")
        XCTAssertEqual(model.currentTime, 7)

        await model.togglePlayPause()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.currentTime, 7, "Resuming must continue from where it stopped.")
        let seeks = await player.seekCount
        XCTAssertEqual(seeks, 0, "Nothing may seek to zero unless the user asked for it.")
    }

    /// The state the race produced, reached directly: the player stopped mid-file without this
    /// model doing it. That is not the end of the file, and must not be reported as one.
    func testAPlayerStoppedShortOfTheEndIsNotReportedAsFinished() async {
        let (model, player) = makeModel(duration: 20)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 4)
        await player.interrupt()

        await model.tick()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.currentTime, 4, "The position it stopped at is what resuming needs.")
    }

    /// Reaching the end is still detected — the fix must not trade one wrong reading for another.
    func testReachingTheEndIsStillDetectedAfterTheFix() async {
        let (model, player) = makeModel(duration: 10)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 10)

        await model.tick()

        XCTAssertEqual(model.phase, .finished)
    }

    /// Some players rewind to zero the instant a file completes. That must read as finished, not as
    /// a player mysteriously stopped at the start.
    func testAPlayerThatRewindsItselfAtTheEndIsStillFinished() async {
        let (model, player) = makeModel(duration: 10)
        await model.load()
        await model.togglePlayPause()

        // Playing, all but at the end.
        await player.advance(by: 9.9)
        await model.tick()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.currentTime, 9.9, accuracy: 0.001)

        // The file runs out and the player rewinds itself before the next tick reads it.
        await player.interrupt()
        await player.seekToStart()
        await model.tick()

        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.currentTime, 10)
    }

    /// Pause and resume, several times over, never loses the position.
    func testRepeatedPauseAndResumeKeepsAdvancing() async {
        let (model, player) = makeModel(duration: 60)
        await model.load()

        for expected in [5.0, 11.0, 18.0] {
            await model.togglePlayPause()
            XCTAssertEqual(model.phase, .playing)
            await player.advance(by: expected - model.currentTime)
            await model.tick()
            await model.togglePlayPause()
            XCTAssertEqual(model.currentTime, expected)
        }

        let seeks = await player.seekCount
        XCTAssertEqual(seeks, 0)
    }

    /// Only the two paths that mean "from the top" may move the playhead to zero.
    func testOnlyRestartAndPlayingAfterTheEndSeekToZero() async {
        let (model, player) = makeModel(duration: 20)
        await model.load()
        await model.togglePlayPause()
        await player.advance(by: 9)
        await model.tick()

        await model.togglePlayPause()   // pause
        await model.togglePlayPause()   // resume
        await model.tick()
        var seeks = await player.seekCount
        XCTAssertEqual(seeks, 0)

        await model.restart()
        seeks = await player.seekCount
        XCTAssertEqual(seeks, 1, "The 처음부터 button is an explicit request to go to zero.")

        await player.advance(by: 20)
        await model.tick()
        XCTAssertEqual(model.phase, .finished)
        await model.togglePlayPause()
        seeks = await player.seekCount
        XCTAssertEqual(seeks, 2, "Playing from the end is the other way to mean 'from the top'.")
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
        let playing = await player.snapshot().isPlaying
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
