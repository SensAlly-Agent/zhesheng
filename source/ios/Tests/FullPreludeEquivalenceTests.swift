import CryptoKit
import Foundation
import XCTest

final class FullPreludeEquivalenceTests: XCTestCase {
    func testFullRecordingMatchesExplicitSilenceBitForBit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../..").standardizedFileURL
        let input = root.appending(path: "evidence/whole-recording-input.json")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Full recording is optional; provide the local acceptance input manifest.")
        }
        let paths = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: input))
        let audio = try AudioDecoder.decode(URL(fileURLWithPath: XCTUnwrap(paths["audio"])))
        let filters = URL(fileURLWithPath: try XCTUnwrap(paths["models"])).appending(path: "mel_filters.bin")
        let extractor = try LogMelExtractor(filtersURL: filters)
        let prefix = RecognitionPrelude.prefixSampleCount(for: audio.samples.count)
        let physical = extractor.featuresTimed([Float](repeating: 0, count: prefix) + audio.samples).features
        let virtual = extractor.featuresTimed(audio.samples, leadingSilenceSamples: prefix).features
        let original = extractor.featuresTimed(audio.samples).features
        XCTAssertEqual(physical.count, virtual.count)
        var mismatches = 0
        for (left, right) in zip(physical, virtual) {
            if left.bitPattern != right.bitPattern { mismatches += 1 }
        }
        let prefixFeatures = prefix / LogMelExtractor.hopLength * LogMelExtractor.mels
        XCTAssertEqual(virtual.count - prefixFeatures, original.count)
        var originalMismatches = 0
        for (left, right) in zip(original, virtual.dropFirst(prefixFeatures)) {
            if left.bitPattern != right.bitPattern { originalMismatches += 1 }
        }
        func sha(_ values: [Float]) -> String {
            values.withUnsafeBytes { bytes in
                SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            }
        }
        let physicalSHA = sha(physical)
        let virtualSHA = sha(virtual)
        let record: [String: Any] = [
            "audio_s": audio.seconds, "original_samples": audio.samples.count,
            "leading_silence_samples": prefix, "features": virtual.count,
            "mismatching_float_bit_patterns": mismatches,
            "original_audio_feature_mismatches": originalMismatches,
            "physical_sha256": physicalSHA, "virtual_sha256": virtualSHA,
            "passed": physical.count == virtual.count && mismatches == 0 && originalMismatches == 0
                && physicalSHA == virtualSHA
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "evidence/full-prelude-equivalence.json"), options: .atomic)
        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(originalMismatches, 0)
        XCTAssertEqual(physicalSHA, virtualSHA)
    }
}
