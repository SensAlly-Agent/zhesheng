import Foundation

/// Context before the first spoken samples. This is only an inference input;
/// the source file and its reported duration remain unchanged.
enum RecognitionPrelude {
    static let seconds = 3.0
    static let sampleCount = Int(seconds * AudioDecoder.sampleRate)

    /// Inputs without a valid feature frame keep their existing empty-result behavior.
    static func prefixSampleCount(for originalSampleCount: Int) -> Int {
        LogMelExtractor.frameCount(samples: originalSampleCount) > 0 ? sampleCount : 0
    }
}
