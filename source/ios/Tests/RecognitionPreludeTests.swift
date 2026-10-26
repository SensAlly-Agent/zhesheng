import XCTest
import Foundation

final class RecognitionPreludeTests: XCTestCase {
    func testExactlyThreeSecondsForInputsWithACompleteFeatureFrame() {
        XCTAssertEqual(RecognitionPrelude.seconds, 3)
        XCTAssertEqual(RecognitionPrelude.sampleCount, 48_000)
        for count in [161, 162, 320, 500, 62_264_832] {
            XCTAssertEqual(RecognitionPrelude.prefixSampleCount(for: count), 48_000)
            XCTAssertEqual(LogMelExtractor.frameCount(samples: count + 48_000),
                           LogMelExtractor.frameCount(samples: count) + 300)
        }
    }

    func testEmptyAndShortInputsAreNotExtended() throws {
        let extractor = try makeExtractor()
        for count in [0, 1, 159, 160] {
            let original = waveform(count: count)
            let prefix = RecognitionPrelude.prefixSampleCount(for: count)
            XCTAssertEqual(prefix, 0)
            let output = extractor.featuresTimed(original, leadingSilenceSamples: prefix)
            XCTAssertTrue(output.features.isEmpty)
            XCTAssertEqual(output.breakdown.blocks, 0)
        }
    }

    func testVirtualPrefixMatchesExplicitPCMAtFrameBoundaries() throws {
        let extractor = try makeExtractor()
        for count in [161, 162, 319, 320, 321, 511, 512, 513] {
            assertSameFeatures(waveform(count: count), extractor: extractor)
        }
    }

    func testVirtualPrefixMatchesExplicitPCMAcross512FrameBlocks() throws {
        let extractor = try makeExtractor()
        // These cross the 511/512/513 padded-frame boundary and include a source longer than 512 frames,
        // a partial last hop and more than two padded blocks.
        for count in [33_920, 33_921, 34_080, 34_081, 96_073, 116_038] {
            assertSameFeatures(waveform(count: count), extractor: extractor)
        }
    }

    func testZeroWaveformAndSignedZeroMatchExplicitPCM() throws {
        let extractor = try makeExtractor()
        var samples = [Float](repeating: 0, count: 509)
        samples[0] = -0.0
        samples[159] = -0.0
        samples[508] = -0.0
        assertSameFeatures(samples, extractor: extractor)
    }

    private func makeExtractor() throws -> LogMelExtractor {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // source
            .deletingLastPathComponent() // experiment root
        return try LogMelExtractor(filtersURL: root.appending(path: "models/eg2-transcribe-zh/mel_filters.bin"))
    }

    private func waveform(count: Int) -> [Float] {
        // Deterministic non-periodic dyadic samples exercise every position without floating-point trig.
        var state: UInt64 = 0x7b54_1e3d_a0c9_826f
        var samples = (0..<count).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int(state >> 40) - 8_388_608) / 16_777_216
        }
        if !samples.isEmpty { samples[0] = 0.875; samples[samples.count - 1] = -0.75 }
        if samples.count > 159 { samples[159] = -0.625 }
        if samples.count > 160 { samples[160] = .leastNormalMagnitude }
        return samples
    }

    private func assertSameFeatures(_ original: [Float], extractor: LogMelExtractor,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let originalBits = original.map(\.bitPattern)
        let prefix = RecognitionPrelude.prefixSampleCount(for: original.count)
        // Independent oracle: the previous implementation's physical zero-prefix waveform.
        let explicit = [Float](repeating: 0, count: prefix) + original
        let expected = extractor.featuresTimed(explicit)
        let actual = extractor.featuresTimed(original, leadingSilenceSamples: prefix)
        XCTAssertEqual(actual.features.count, expected.features.count, file: file, line: line)
        XCTAssertEqual(actual.breakdown.blocks, expected.breakdown.blocks, file: file, line: line)
        XCTAssertTrue(actual.features.allSatisfy(\.isFinite), file: file, line: line)
        let mismatch = zip(actual.features, expected.features).enumerated()
            .first { $0.element.0.bitPattern != $0.element.1.bitPattern }?.offset
        XCTAssertNil(mismatch, "sample count \(original.count): first differing feature \(mismatch ?? -1)",
                     file: file, line: line)
        XCTAssertEqual(original.map(\.bitPattern), originalBits, file: file, line: line)
    }
}
