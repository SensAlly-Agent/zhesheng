import Accelerate
import AVFoundation
import CoreGraphics
import Foundation

/// A coarse picture of an audio file for the scope: log-spaced bands from 80 Hz to 8 kHz, one FFT window per
/// column. It reads only those short slices of the file, so even an hour of audio costs a few milliseconds, and it
/// never touches the transcription (which decodes the file on its own).
struct Spectrogram: Sendable, Equatable {
    let id = UUID()
    let columns: Int
    let bands: Int
    /// Column-major, 0…1, band 0 = lowest.
    let values: [Float]
    let seconds: Double

    static func make(_ url: URL, maxColumns: Int = 720, bands: Int = 56) -> Spectrogram? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate, length = file.length
        guard length > 0, rate > 0 else { return nil }
        let seconds = Double(length) / rate
        let fftLength = rate > 24_000 ? 2048 : 1024
        let half = fftLength / 2
        let columns = max(48, min(maxColumns, Int(seconds * 14)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fftLength)),
              let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftLength))), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(&window, vDSP_Length(fftLength), Int32(vDSP_HANN_NORM))
        let top = min(8_000, rate / 2)
        let edges = (0...bands).map { b -> Int in
            let f = 80 * pow(top / 80, Double(b) / Double(bands))
            return max(1, min(half - 1, Int(f / rate * Double(fftLength))))
        }

        var decibels = [Float](repeating: -120, count: columns * bands)
        var frame = [Float](repeating: 0, count: fftLength)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        let span = max(0, length - AVAudioFramePosition(fftLength))
        let channels = Int(format.channelCount)

        for c in 0..<columns {
            file.framePosition = AVAudioFramePosition((Double(c) + 0.5) / Double(columns) * Double(span))
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(fftLength))) != nil,
                  let data = buffer.floatChannelData else { continue }
            let count = Int(buffer.frameLength)
            for i in 0..<fftLength {
                var sum: Float = 0
                if i < count { for ch in 0..<channels { sum += data[ch][i] } }
                frame[i] = sum / Float(max(channels, 1)) * window[i]
            }
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer { src in
                        src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(fftLength))), FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            for b in 0..<bands {
                let lo = edges[b], hi = max(edges[b] + 1, edges[b + 1])
                var sum: Float = 0
                for k in lo..<min(hi, half) { sum += power[k] }
                decibels[c * bands + b] = 10 * log10(sum / Float(hi - lo) + 1e-12)
            }
        }

        let ceiling = decibels.max() ?? 0
        let floor = ceiling - 70
        let values = decibels.map { Float(max(0, min(1, ($0 - floor) / 70))) }
        return Spectrogram(columns: columns, bands: bands, values: values, seconds: seconds)
    }

    /// The picture in magma, one pixel per column and band (drawn stretched and smoothed).
    func image() -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: columns * bands * 4)
        for c in 0..<columns {
            for b in 0..<bands {
                let v = pow(Double(values[c * bands + b]), 1.25)
                let i = max(0, min(255, Int(v * 255))) * 3
                let o = ((bands - 1 - b) * columns + c) * 4
                pixels[o] = Magma.table[i]; pixels[o + 1] = Magma.table[i + 1]; pixels[o + 2] = Magma.table[i + 2]
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: columns, height: bands, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func == (a: Spectrogram, b: Spectrogram) -> Bool { a.id == b.id }
}
