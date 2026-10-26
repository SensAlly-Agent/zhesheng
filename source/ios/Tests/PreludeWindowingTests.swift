import XCTest

final class PreludeWindowingTests: XCTestCase {
    private let contract = WindowContract(frames: 3000, leftOverlap: 48, dropLast: 49)
    private let prefixFrames = 300
    private let prefixTokens = 75

    func testZeroPreludeReturnsEveryOriginalWindowFieldUnchanged() {
        for frames in [0, 1, 2, 3, 4, 799, 800, 801, 2999, 3000, 3001, 5612, 389_155] {
            XCTAssertEqual(Windowing.planWithPrelude(frames: frames, leadingSilenceFrames: 0, contract: contract),
                           Windowing.plan(frames: frames, contract: contract), "frames \(frames)")
        }
    }

    func testLongRecordingKeepsNativeWindowInputsAndTailExactlyAligned() {
        let originalFrames = 389_155
        let native = Windowing.plan(frames: originalFrames, contract: contract)
        let adjusted = Windowing.planWithPrelude(frames: originalFrames + prefixFrames,
                                                 leadingSilenceFrames: prefixFrames, contract: contract)
        XCTAssertEqual(native.count, 149)
        XCTAssertEqual(adjusted.count, 150)
        XCTAssertEqual(adjusted.first, Window(index: 0, token0: 0, frame0: 0, frames: 3000,
                                             validTokens: 750, keep: 0..<275))
        XCTAssertEqual(adjusted[1].keep, 200..<701)
        for (original, shifted) in zip(native, adjusted.dropFirst()) {
            XCTAssertEqual(shifted.index, original.index + 1)
            XCTAssertEqual(shifted.frame0 - prefixFrames, original.frame0)
            XCTAssertEqual(shifted.token0 - prefixTokens, original.token0)
            XCTAssertEqual(shifted.frames, original.frames)
            XCTAssertEqual(shifted.validTokens, original.validTokens)
            XCTAssertEqual(shifted.keep.upperBound, original.keep.upperBound)
            if original.index > 0 { XCTAssertEqual(shifted.keep, original.keep) }
        }
        XCTAssertEqual(adjusted.last?.frames, 2579)
        XCTAssertEqual(Windowing.totalTokens(adjusted), Windowing.tokens(frames: originalFrames) + prefixTokens)
        assertExactCoverage(adjusted, frames: originalFrames + prefixFrames, contract: contract)
    }

    func testClipsThroughEightSecondsUseOnlyTheLeadingWindow() {
        for originalFrames in [1, 2, 3, 4, 159, 160, 161, 797, 798, 799, 800] {
            let frames = originalFrames + prefixFrames
            let plan = Windowing.planWithPrelude(frames: frames, leadingSilenceFrames: prefixFrames,
                                                 contract: contract)
            XCTAssertEqual(plan.count, 1, "original frames \(originalFrames)")
            XCTAssertEqual(plan.first?.frames, frames)
            XCTAssertEqual(plan.first?.keep, 0..<Windowing.tokens(frames: frames))
            assertExactCoverage(plan, frames: frames, contract: contract)
        }
    }

    func testFirstNativeTokenAfterRecoveryIsNeitherSkippedNorRepeated() {
        for originalFrames in 801...804 {
            let plan = Windowing.planWithPrelude(frames: originalFrames + prefixFrames,
                                                 leadingSilenceFrames: prefixFrames, contract: contract)
            XCTAssertEqual(plan.count, 2)
            XCTAssertEqual(plan[0].keep, 0..<275)
            XCTAssertEqual(plan[1].frame0, prefixFrames)
            XCTAssertEqual(plan[1].token0, prefixTokens)
            XCTAssertEqual(plan[1].keep, 200..<201)
            assertExactCoverage(plan, frames: originalFrames + prefixFrames, contract: contract)
        }
    }

    func testCoverageAcrossFrameRemaindersAndEveryEarlyWindowTransition() {
        // Four-frame residues and the original/fused first-window and later-window end boundaries.
        var lengths = Set(1...1104)
        for boundary in [2700, 2804, 3000, 5416, 5612, 8028, 8224] {
            for delta in -8...8 { lengths.insert(boundary + delta) }
        }
        for originalFrames in lengths.sorted() {
            let frames = originalFrames + prefixFrames
            let plan = Windowing.planWithPrelude(frames: frames, leadingSilenceFrames: prefixFrames,
                                                 contract: contract)
            assertExactCoverage(plan, frames: frames, contract: contract)
        }
    }

    func testSmallContractCapsRecoveryToLeadingSafeCapacity() {
        let small = WindowContract(frames: 400, leftOverlap: 5, dropLast: 10)
        let plan = Windowing.planWithPrelude(frames: 2300, leadingSilenceFrames: prefixFrames, contract: small)
        // 100 tokens - 10 unsafe tail tokens - 75 prefix tokens leaves 15 recovered audio tokens.
        XCTAssertEqual(plan[0].keep, 0..<90)
        XCTAssertEqual(plan[1].frame0, 300)
        XCTAssertEqual(plan[1].keep, 15..<90)
        assertExactCoverage(plan, frames: 2300, contract: small)
    }

    func testSafeCapacityCanRetainOnlyThePreludeWithoutDroppingNativeAudio() {
        let small = WindowContract(frames: 400, leftOverlap: 5, dropLast: 25)
        let native = Windowing.plan(frames: 2000, contract: small)
        let plan = Windowing.planWithPrelude(frames: 2300, leadingSilenceFrames: prefixFrames, contract: small)
        XCTAssertEqual(plan[0].keep, 0..<75)
        XCTAssertEqual(plan[1].keep, native[0].keep)
        assertExactCoverage(plan, frames: 2300, contract: small)
    }

    func testPrefixOnlyFeaturesHaveCompleteCoverageWithoutAnEmptyNativeWindow() {
        let plan = Windowing.planWithPrelude(frames: prefixFrames, leadingSilenceFrames: prefixFrames,
                                             contract: contract)
        XCTAssertEqual(plan, [Window(index: 0, token0: 0, frame0: 0, frames: prefixFrames,
                                     validTokens: prefixTokens, keep: 0..<prefixTokens)])
        assertExactCoverage(plan, frames: prefixFrames, contract: contract)
    }

    private func assertExactCoverage(_ plan: [Window], frames: Int, contract: WindowContract,
                                     file: StaticString = #filePath, line: UInt = #line) {
        var nextToken = 0
        for (index, window) in plan.enumerated() {
            XCTAssertEqual(window.index, index, file: file, line: line)
            XCTAssertEqual(window.frame0, 4 * window.token0, file: file, line: line)
            XCTAssertGreaterThan(window.frames, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(window.frames, contract.frames, file: file, line: line)
            XCTAssertLessThanOrEqual(window.frame0 + window.frames, frames, file: file, line: line)
            XCTAssertEqual(window.validTokens, Windowing.tokens(frames: window.frames), file: file, line: line)
            XCTAssertFalse(window.keep.isEmpty, file: file, line: line)
            XCTAssertGreaterThanOrEqual(window.keep.lowerBound, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(window.keep.upperBound, window.validTokens, file: file, line: line)
            // Adjacent half-open intervals must touch exactly, proving no gap, duplicate or reordering.
            XCTAssertEqual(window.token0 + window.keep.lowerBound, nextToken, file: file, line: line)
            nextToken = window.token0 + window.keep.upperBound
        }
        XCTAssertEqual(nextToken, Windowing.tokens(frames: frames), file: file, line: line)
        XCTAssertEqual(Windowing.totalTokens(plan), nextToken, file: file, line: line)
    }
}
