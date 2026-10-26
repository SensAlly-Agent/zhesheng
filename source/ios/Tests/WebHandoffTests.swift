import XCTest
import Foundation
import Dispatch
#if os(macOS)
import AppKit
#endif

private nonisolated func webHandoffCallbackIsOnMainThread() -> Bool {
    Thread.isMainThread
}

@MainActor
private final class WebHandoffCallbackState {
    var values: [Bool] = []
    var deliveredOnMainThread: [Bool] = []

    func record(_ accepted: Bool) {
        MainActor.preconditionIsolated()
        deliveredOnMainThread.append(Thread.isMainThread)
        values.append(accepted)
    }
}

@MainActor
final class WebHandoffTests: XCTestCase {
    private func promptFixture() throws -> String {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/requested-prompt-template.txt")
        return try String(contentsOf: fixture, encoding: .utf8)
    }

    private func waitForCallback(_ state: WebHandoffCallbackState) async throws {
        for _ in 0..<200 {
            if !state.values.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the background callback to reach MainActor")
    }

    func testSuccessfulDetachedOpenURLCallbackReturnsToMainActor() async throws {
        let state = WebHandoffCallbackState()
        let callback = WebHandoff.onMainActor { accepted in
            state.record(accepted)
        }
        let invokedOnMainThread = await Task.detached {
            let onMain = webHandoffCallbackIsOnMainThread()
            callback(true)
            return onMain
        }.value

        XCTAssertFalse(invokedOnMainThread)
        try await waitForCallback(state)
        XCTAssertEqual(state.values, [true])
        XCTAssertEqual(state.deliveredOnMainThread, [true])
    }

    func testFailedDispatchOpenURLCallbackReturnsToMainActor() async throws {
        let state = WebHandoffCallbackState()
        let callback = WebHandoff.onMainActor { accepted in
            state.record(accepted)
        }
        let invokedOnMainThread = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let onMain = Thread.isMainThread
                callback(false)
                continuation.resume(returning: onMain)
            }
        }

        XCTAssertFalse(invokedOnMainThread)
        try await waitForCallback(state)
        XCTAssertEqual(state.values, [false])
        XCTAssertEqual(state.deliveredOnMainThread, [true])
    }

    func testWebsiteAllowlistContainsExactlyFiveOfficialRoots() {
        let expected = [
            "deepseek": "https://chat.deepseek.com/",
            "chatgpt": "https://chatgpt.com/",
            "claude": "https://claude.ai/",
            "gemini": "https://gemini.google.com/",
            "kimi": "https://www.kimi.com/",
        ]
        XCTAssertEqual(LLMWebsite.allCases.count, 5)
        XCTAssertEqual(Set(LLMWebsite.allCases.map(\.rawValue)), Set(expected.keys))
        XCTAssertEqual(Set(LLMWebsite.allCases.map(\.id)).count, 5)
        for website in LLMWebsite.allCases {
            XCTAssertEqual(website.url.absoluteString, expected[website.rawValue])
            XCTAssertFalse(website.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testEveryWebsiteUsesHTTPSWithoutTextOrCredentialsInURL() throws {
        for website in LLMWebsite.allCases {
            let components = try XCTUnwrap(URLComponents(url: website.url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertNotNil(components.host)
            XCTAssertEqual(components.path, "/")
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertNil(components.user)
            XCTAssertNil(components.password)
            XCTAssertNil(components.port)
        }
    }

    func testSavedWebsiteRestoresEveryAllowlistedValue() {
        for website in LLMWebsite.allCases {
            XCTAssertEqual(LLMWebsite.saved(website.rawValue), website)
        }
    }

    func testInvalidSavedWebsiteFallsBackToDeepSeek() {
        for raw in ["", "unknown", "DEEPSEEK", " deepseek ", "https://example.invalid/", "javascript:alert(1)"] {
            XCTAssertEqual(LLMWebsite.saved(raw), .deepseek)
        }
    }

    func testEmptyOrWhitespaceTranscriptNeverWritesClipboard() {
        for text in ["", " ", "\n\r\t", "\u{00a0}\u{3000}\n\t"] {
            XCTAssertNil(WebHandoff.payload(text))
            var writes = 0
            let result = WebHandoff.copyPrompt(text) { _ in
                writes += 1
                return true
            }
            XCTAssertEqual(result, .empty)
            XCTAssertEqual(writes, 0)
        }
    }

    func testPromptPrefixAndSuffixMatchFixedUserFixture() throws {
        let parts = try promptFixture().components(separatedBy: "识别出的内容")
        XCTAssertEqual(parts.count, 2)
        guard parts.count == 2 else { return }
        XCTAssertEqual(Array(ProofreadingPrompt.prefix.utf8), Array(parts[0].utf8))
        XCTAssertEqual(Array(ProofreadingPrompt.suffix.utf8), Array(parts[1].utf8))
    }

    func testPayloadMatchesVerbatimUserPromptFixture() throws {
        let expected = try promptFixture()
        let actual = try XCTUnwrap(WebHandoff.payload("识别出的内容"))
        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8))
    }

    func testCopyPreservesWhitespaceSpecialDelimitersAndUnicodeScalarCount() throws {
        let text = " \n’‘’原文\n'''引号‘’‘\t👩🏽‍💻 e\u{301}\r\n尾部  "
        let expected = ProofreadingPrompt.user(text)
        let payload = try XCTUnwrap(WebHandoff.payload(text))
        XCTAssertEqual(Array(payload.utf8), Array(expected.utf8))
        var written: [String] = []
        let result = WebHandoff.copyPrompt(text) { value in
            written.append(value)
            return true
        }
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(written.first).utf8), Array(expected.utf8))
        XCTAssertGreaterThan(text.unicodeScalars.count, text.count)
        XCTAssertEqual(result, .copied(characters: text.unicodeScalars.count))
    }

    func testLongTranscriptIsCopiedCompletelyWithoutTruncation() throws {
        let text = String(repeating: "字", count: 80_001) + "\n👩🏽‍💻 e\u{301}\n尾部必须保留  "
        XCTAssertGreaterThan(text.unicodeScalars.count, 80_000)
        let expected = ProofreadingPrompt.user(text)
        XCTAssertEqual(Array(try XCTUnwrap(WebHandoff.payload(text)).utf8), Array(expected.utf8))
        var written: String?
        var writes = 0
        let result = WebHandoff.copyPrompt(text) { value in
            written = value
            writes += 1
            return true
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(Array(try XCTUnwrap(written).utf8), Array(expected.utf8))
        XCTAssertEqual(result, .copied(characters: text.unicodeScalars.count))
    }

    func testFailedClipboardWriteReturnsFailureWithoutRetrying() {
        var writes = 0
        let result = WebHandoff.copyPrompt("原始识别") { value in
            writes += 1
            XCTAssertEqual(value, ProofreadingPrompt.user("原始识别"))
            return false
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(result, .copyFailed)
    }

    #if os(macOS)
    func testNamedPasteboardRoundTripPreservesPayloadWithoutUsingGeneralPasteboard() throws {
        let board = NSPasteboard(name: .init("EG2ZHWebHandoffTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let text = " \n原文’‘’\n👩🏽‍💻 e\u{301}\t尾部 "
        let expected = ProofreadingPrompt.user(text)
        let result = WebHandoff.copyPrompt(text) { value in
            board.clearContents()
            return board.setString(value, forType: .string)
        }
        XCTAssertEqual(result, .copied(characters: text.unicodeScalars.count))
        let copied = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(Array(copied.utf8), Array(expected.utf8))
    }
    #endif
}
