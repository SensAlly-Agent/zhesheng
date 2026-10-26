import XCTest

/// 贴回结果 and editing: what the clipboard check accepts, and how the text on the screen moves between the
/// recognition, the pasted answer, the person's edits and 恢复原始稿.
@MainActor
final class PasteBackEditingTests: XCTestCase {
    private let raw = "明天上午十点开会吗你记得带上周的报表"
    private let answer = "明天上午十点开会吗？你记得带上周的报表。"

    func testNothingOnTheClipboardIsRefused() {
        XCTAssertEqual(PasteBack.check(nil, current: raw), .empty)
        XCTAssertEqual(PasteBack.check(" \n\t ", current: raw), .empty)
        XCTAssertEqual(PasteBack.check("```\n```", current: raw), .empty)
    }

    func testThePromptStillOnTheClipboardIsRefused() {
        // The person pressed 贴回 before copying the answer: the clipboard holds what the app copied for the site.
        XCTAssertEqual(PasteBack.check(ProofreadingPrompt.user(raw), current: raw), .stillPrompt)
        XCTAssertEqual(PasteBack.check("  " + ProofreadingPrompt.user(raw) + "\n", current: raw), .stillPrompt)
    }

    func testTheSameTextAsOnTheScreenIsRefused() {
        XCTAssertEqual(PasteBack.check(raw + "\n", current: raw), .unchanged)
    }

    func testAnAnswerComesBackTrimmedAndUnwrapped() {
        XCTAssertEqual(PasteBack.check("\n  " + answer + "  \n\n", current: raw), .ready(answer))
        XCTAssertEqual(PasteBack.check("```text\n" + answer + "\n```", current: raw), .ready(answer))
        XCTAssertEqual(PasteBack.check("’‘’\n" + answer + "\n‘’‘", current: raw), .ready(answer))
        XCTAssertEqual(PasteBack.check("'''\n" + answer + "\n'''", current: raw), .ready(answer))
        // Paragraphs inside the answer stay as they are.
        let paragraphs = "第一段。\n\n第二段，继续。"
        XCTAssertEqual(PasteBack.check(paragraphs, current: raw), .ready(paragraphs))
    }

    func testPastedAnswerReplacesTheTextAndKeepsTheRecognition() {
        let model = AppModel()
        model.showRecognized(raw)
        XCTAssertEqual(model.arrival, .recognized)
        XCTAssertTrue(model.hasText)
        XCTAssertFalse(model.isEdited)

        model.applyProofread(answer)
        XCTAssertEqual(model.transcript, answer)
        XCTAssertEqual(model.recognized, raw)
        XCTAssertTrue(model.isProofread)
        XCTAssertFalse(model.isEdited)

        model.transcript += "\n补一句。"
        XCTAssertTrue(model.isEdited)
        XCTAssertTrue(model.isProofread)

        model.restoreRecognized()
        XCTAssertEqual(model.transcript, raw)
        XCTAssertEqual(model.arrival, .restored)
        XCTAssertFalse(model.isProofread)
        XCTAssertFalse(model.isEdited)
    }

    func testEditsKeepTheTextOnTheScreenAndCountAsContent() {
        let model = AppModel()
        model.showRecognized(raw)
        model.transcript = ""
        // Deleting everything keeps the editor (the recognition is still there to restore) and is an edit.
        XCTAssertTrue(model.hasText)
        XCTAssertTrue(model.isEdited)
        model.transcript = "改过的第一行\n第二行"
        XCTAssertTrue(model.isEdited)
        XCTAssertTrue(model.asksBeforeRecording)
    }

    func testOnlyArrivalsBumpTheGenerationNotEdits() {
        let model = AppModel()
        let start = model.textGeneration
        model.showRecognized(raw)
        XCTAssertEqual(model.textGeneration, start + 1)
        model.transcript = raw + "。"
        model.transcript = raw + "。\n"
        XCTAssertEqual(model.textGeneration, start + 1)
        model.applyProofread(answer)
        XCTAssertEqual(model.textGeneration, start + 2)
        model.restoreRecognized()
        XCTAssertEqual(model.textGeneration, start + 3)
    }

    func testANewRecognitionOrClearingStartsOver() {
        let model = AppModel()
        model.showRecognized(raw)
        model.applyProofread(answer)
        model.showRecognized("新的一段")
        XCTAssertEqual(model.transcript, "新的一段")
        XCTAssertEqual(model.recognized, "新的一段")
        XCTAssertFalse(model.isProofread)

        model.clearContent()
        XCTAssertEqual(model.arrival, .cleared)
        XCTAssertEqual(model.transcript, "")
        XCTAssertFalse(model.hasText)
        XCTAssertFalse(model.hasContent)
    }
}
