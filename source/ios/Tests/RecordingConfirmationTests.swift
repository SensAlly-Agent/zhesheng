import XCTest

/// Recording over what the screen holds (a transcript, or the numbers of a silent recording) asks first; confirming
/// clears it. Stopping a recording never asks.
@MainActor
final class RecordingConfirmationTests: XCTestCase {
    private func stats() -> RunStats {
        RunStats(file: "recording.wav", audioSeconds: 12, totalSeconds: 0.5, decodeSeconds: 0.01, logMelSeconds: 0.01,
                 windowSeconds: 0.4, stageSeconds: ["encoder", "reader"], stageSums: [0.2, 0.1], hostSeconds: 0.01,
                 windows: 1, form: "ANE 编码器 + GPU 识别器", overlap: true, decodeMode: "lm", decodeMilliseconds: 3)
    }

    func testEmptyScreenRecordsWithoutAsking() {
        let model = AppModel()
        XCTAssertFalse(model.hasContent)
        XCTAssertFalse(model.asksBeforeRecording)
    }

    func testTranscriptAsksAndClearingEmptiesTheScreen() {
        let model = AppModel()
        model.transcript = "明天上午十点开会吗"
        model.stats = stats()
        XCTAssertTrue(model.asksBeforeRecording)

        model.clearContent()
        XCTAssertEqual(model.transcript, "")
        XCTAssertNil(model.stats)
        XCTAssertNil(model.spectrogram)
        XCTAssertFalse(model.hasContent)
        XCTAssertFalse(model.asksBeforeRecording)
    }

    func testNumbersOfSilentRecordingAsk() {
        let model = AppModel()
        model.stats = stats()
        XCTAssertEqual(model.transcript, "")
        XCTAssertTrue(model.asksBeforeRecording)
    }

    func testStoppingNeverAsks() {
        let model = AppModel()
        model.transcript = "明天上午十点开会吗"
        model.phase = .recording
        XCTAssertTrue(model.hasContent)
        XCTAssertFalse(model.asksBeforeRecording)
    }
}
