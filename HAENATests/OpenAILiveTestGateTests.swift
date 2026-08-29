import XCTest
@testable import HAENA

final class OpenAILiveTestGateTests: XCTestCase {
    func testKeyFileAloneDoesNotOptIn() {
        XCTAssertEqual(
            OpenAILiveTestGate.evaluate(
                environment: [:],
                kind: .workStateExtraction,
                hasCredential: true
            ),
            .disabled
        )
    }

    func testEnvironmentAPIKeyAloneDoesNotOptIn() {
        XCTAssertEqual(
            OpenAILiveTestGate.evaluate(
                environment: ["OPENAI_API_KEY": "present"],
                kind: .workStateExtraction,
                hasCredential: true
            ),
            .disabled
        )
    }

    func testFlagWithoutCredentialSkips() {
        XCTAssertEqual(
            OpenAILiveTestGate.evaluate(
                environment: [OpenAILiveTestGate.optInEnvironmentKey: "1"],
                kind: .workStateExtraction,
                hasCredential: false
            ),
            .missingCredential
        )
    }

    func testFlagAndCredentialAllowWorkStateLiveTest() {
        XCTAssertEqual(
            OpenAILiveTestGate.evaluate(
                environment: [OpenAILiveTestGate.optInEnvironmentKey: "1"],
                kind: .workStateExtraction,
                hasCredential: true
            ),
            .allowed
        )
    }

    func testTranscriptionAdditionallyRequiresAudioPath() {
        let environment = [OpenAILiveTestGate.optInEnvironmentKey: "1"]
        XCTAssertEqual(
            OpenAILiveTestGate.evaluate(
                environment: environment,
                kind: .transcription,
                hasCredential: true,
                hasAudioPath: false
            ),
            .missingAudioPath
        )
        XCTAssertEqual(
            OpenAILiveTestGate.evaluate(
                environment: environment,
                kind: .transcription,
                hasCredential: true,
                hasAudioPath: true
            ),
            .allowed
        )
    }
}
