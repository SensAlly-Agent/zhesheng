import Foundation

// eg2zh (Mandarin, LM): the character n-gram language model of the LM decoder, read from an `.eg2lm` file
// (lmver SPEC 2). Foundation only: the same file compiles in the Linux test package.

/// Where a query stands in the n-gram model: the last `length` words (words[0] the most recent) and the log10
/// backoff weights of the contexts they form (backoffs[j] = backoff of the (j + 1)-gram words[j] … words[0]).
/// Lanes at and above `length` are 0.
struct LMState: Sendable, Hashable {
    var length: Int
    var words: SIMD4<Int32>
    var backoffs: SIMD4<Float>
}

/// An `.eg2lm` file (version 1), memory-mapped: a character n-gram model (order 2…5) with KenLM / ARPA backoff
/// semantics. Ids: 0 ..< V the vocab.txt characters (the reader's class ids), V `</s>`, V + 1 `<s>`, V + 2 `<unk>`.
///
/// Layout (little-endian): a 512-byte header, then 64-aligned sections: order 1 `prob` f32[B] and `backoff` f32[B];
/// per order n = 2…N `bucket` u32[B + 1] (the entries predicting word w are [bucket[w], bucket[w + 1])), `keys`
/// (the context as sum c_i B^i, c_0 the word right before w; u16 for n = 2, u32 for n = 3, u64 for n = 4, 5) sorted
/// within each bucket, `prob` f32 and (n < N) `backoff` f32; then a UTF-8 JSON description (`metaJSON`).
final class EG2LanguageModel: Sendable {
    static let magic: [UInt8] = [0x45, 0x47, 0x32, 0x4C, 0x4D, 0x00, 0x00, 0x00]  // "EG2LM\0\0\0"
    static let headerBytes = 512

    let order: Int
    /// V: the characters (vocab.txt lines).
    let vocabularyCount: Int
    /// B = V + 3: the characters, `</s>`, `<s>`, `<unk>`.
    let idCount: Int
    let fileBytes: Int
    /// SHA-256 of the vocab.txt the model was written for (raw 32 bytes).
    let vocabSHA256: [UInt8]
    /// The file's description (sources, licence, counts), UTF-8 JSON.
    let metaJSON: Data
    /// N-grams per order (counts[0] = B).
    let counts: [Int]

    var endOfSentence: Int { vocabularyCount }
    var beginOfSentence: Int { vocabularyCount + 1 }
    var unknown: Int { vocabularyCount + 2 }

    /// Byte offsets of one order's sections (orders 2…N).
    private struct Table: Sendable {
        let bucket: Int
        let keys: Int
        let keyWidth: Int
        let prob: Int
        let backoff: Int  // 0 for the highest order
    }

    private let data: Data
    private let prob1: Int
    private let backoff1: Int
    /// tables[n - 2] for n = 2…N.
    private let tables: [Table]
    /// B^0 … B^3.
    private let powers: [UInt64]

    /// Opens the file memory-mapped and checks its header and bucket tables (throws on any inconsistency).
    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), name: url.lastPathComponent)
    }

    init(data input: Data, name: String = "LM") throws {
        func fail(_ message: String) -> TranscribeError { TranscribeError.model("\(name): \(message)") }
        // Element loads need 8-byte alignment of the bytes (a mapped file is page-aligned, a heap copy 16-aligned).
        var data = input
        if data.startIndex != 0 || data.withUnsafeBytes({ Int(bitPattern: $0.baseAddress) % 8 != 0 }) {
            data = Data(input)
        }
        let size = data.count
        guard size >= Self.headerBytes else { throw fail("\(size) bytes, shorter than the 512-byte header") }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: offset, as: UInt32.self)) }
        }
        func u64(_ offset: Int) -> UInt64 {
            data.withUnsafeBytes { UInt64(littleEndian: $0.load(fromByteOffset: offset, as: UInt64.self)) }
        }
        guard Array(data.prefix(8)) == Self.magic else { throw fail("not an eg2lm file (magic)") }
        guard u32(8) == 1 else { throw fail("version \(u32(8)), this reader reads version 1") }
        guard u32(12) == UInt32(Self.headerBytes) else { throw fail("header_bytes \(u32(12))") }
        let n = Int(u32(16)), v = Int(u32(20)), b = Int(u32(24))
        guard (2...5).contains(n) else { throw fail("order \(n) is not 2…5") }
        guard v > 0, b == v + 3 else { throw fail("B \(b) is not V + 3 (V \(v))") }
        guard u32(28) == 1 else { throw fail("value_type \(u32(28)) (1 = float32 log10)") }
        guard u64(64) == UInt64(size) else { throw fail("file_bytes \(u64(64)) but the file has \(size) bytes") }
        let sizeU = UInt64(size)
        /// A section of `bytes` bytes at `offset`: 64-aligned, after the header, inside the file.
        func section(_ offset: UInt64, _ bytes: UInt64, _ what: String) throws -> Int {
            guard offset != 0, offset % 64 == 0, offset >= UInt64(Self.headerBytes), offset <= sizeU,
                  bytes <= sizeU - offset else {
                throw fail("section \(what) at \(offset) (+\(bytes) bytes) is not inside the file or not 64-aligned")
            }
            return Int(offset)
        }
        let metaOffset = u64(72), metaBytes = u64(80)
        guard metaOffset % 64 == 0, metaOffset >= UInt64(Self.headerBytes), metaOffset <= sizeU,
              metaBytes <= sizeU - metaOffset else {
            throw fail("meta section at \(metaOffset) (+\(metaBytes) bytes) is invalid")
        }
        var counts: [Int] = []
        for k in 0..<5 {
            let c = u64(88 + 8 * k)
            guard c <= sizeU else { throw fail("count[\(k + 1)] \(c) is larger than the file") }
            counts.append(Int(c))
        }
        guard counts[0] == b else { throw fail("count[1] \(counts[0]) is not B \(b)") }
        guard counts[n...].allSatisfy({ $0 == 0 }) else { throw fail("an order above \(n) has n-grams") }
        let widths = [0, 2, 4, 8, 8]
        var prob1 = 0, backoff1 = 0
        var tables: [Table] = []
        let bU = UInt64(b)
        for order in 1...n {
            let h = 128 + 48 * (order - 1)
            let bucketOffset = u64(h), keysOffset = u64(h + 8), probOffset = u64(h + 16), backoffOffset = u64(h + 24)
            let width = u64(h + 32)
            guard width == UInt64(widths[order - 1]) else { throw fail("order \(order) key_width \(width)") }
            if order == 1 {
                guard bucketOffset == 0, keysOffset == 0 else { throw fail("order 1 has a bucket or keys section") }
                prob1 = try section(probOffset, 4 * bU, "prob1")
                backoff1 = try section(backoffOffset, 4 * bU, "backoff1")
                continue
            }
            let c = UInt64(counts[order - 1])
            let bucket = try section(bucketOffset, 4 * (bU + 1), "bucket\(order)")
            let keys = try section(keysOffset, width * c, "keys\(order)")
            let prob = try section(probOffset, 4 * c, "prob\(order)")
            var backoff = 0
            if order < n {
                backoff = try section(backoffOffset, 4 * c, "backoff\(order)")
            } else if backoffOffset != 0 {
                throw fail("the highest order has a backoff section")
            }
            // bucket[0] == 0, bucket[B] == count, non-decreasing
            let valid = data.withUnsafeBytes { raw -> Bool in
                var previous: UInt32 = 0
                guard UInt32(littleEndian: raw.load(fromByteOffset: bucket, as: UInt32.self)) == 0 else { return false }
                for w in 0...b {
                    let x = UInt32(littleEndian: raw.load(fromByteOffset: bucket + 4 * w, as: UInt32.self))
                    if x < previous { return false }
                    previous = x
                }
                return UInt64(previous) == c
            }
            guard valid else { throw fail("order \(order): bucket table is not 0 … count, non-decreasing") }
            tables.append(Table(bucket: bucket, keys: keys, keyWidth: Int(width), prob: prob, backoff: backoff))
        }
        self.data = data
        self.order = n
        self.vocabularyCount = v
        self.idCount = b
        self.fileBytes = size
        self.vocabSHA256 = Array(data[32..<64])
        self.metaJSON = Data(data[Int(metaOffset)..<Int(metaOffset + metaBytes)])
        self.counts = Array(counts[0..<n])
        self.prob1 = prob1
        self.backoff1 = backoff1
        self.tables = tables
        self.powers = [1, bU, bU &* bU, bU &* bU &* bU]
    }

    /// The state before the first word of a sentence: `<s>`.
    func beginState() -> LMState {
        let bos = beginOfSentence
        let backoff = data.withUnsafeBytes {
            Float(bitPattern: UInt32(littleEndian: $0.load(fromByteOffset: backoff1 + 4 * bos, as: UInt32.self)))
        }
        return LMState(length: 1, words: SIMD4(Int32(bos), 0, 0, 0), backoffs: SIMD4(backoff, 0, 0, 0))
    }

    /// log10 p(word | state) with ARPA backoff, and the state after the word (lmver SPEC 2.4, accumulated in Double
    /// in exactly this order). A pure function of the file, the state and the word. `word` is a character, `</s>`
    /// or `<unk>` (never `<s>`).
    func score(_ state: LMState, _ word: Int) -> (log10: Double, next: LMState) {
        precondition(word >= 0 && word < idCount && word != beginOfSentence, "LM word id \(word)")
        return data.withUnsafeBytes { raw -> (log10: Double, next: LMState) in
            @inline(__always) func f32(_ offset: Int) -> Float {
                Float(bitPattern: UInt32(littleEndian: raw.load(fromByteOffset: offset, as: UInt32.self)))
            }
            @inline(__always) func u32(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: raw.load(fromByteOffset: offset, as: UInt32.self)))
            }
            @inline(__always) func key(_ table: Table, _ index: Int) -> UInt64 {
                switch table.keyWidth {
                case 2: UInt64(UInt16(littleEndian: raw.load(fromByteOffset: table.keys + 2 * index, as: UInt16.self)))
                case 4: UInt64(UInt32(littleEndian: raw.load(fromByteOffset: table.keys + 4 * index, as: UInt32.self)))
                default: UInt64(littleEndian: raw.load(fromByteOffset: table.keys + 8 * index, as: UInt64.self))
                }
            }
            var p = Double(f32(prob1 + 4 * word))
            var matched = 1
            var nb = SIMD4<Float>(f32(backoff1 + 4 * word), 0, 0, 0)
            var context: UInt64 = 0
            let limit = min(state.length, order - 1)
            var j = 0
            while j < limit {
                let n = j + 2
                let table = tables[j]
                context = context &+ UInt64(UInt32(bitPattern: state.words[j])) &* powers[j]
                var lo = u32(table.bucket + 4 * word)
                let hi = u32(table.bucket + 4 * (word + 1))
                // lower bound of `context` in keys[lo ..< hi]
                var count = hi - lo
                while count > 0 {
                    let half = count / 2
                    if key(table, lo + half) < context {
                        lo += half + 1
                        count -= half + 1
                    } else {
                        count = half
                    }
                }
                if lo >= hi || key(table, lo) != context { break }
                p = Double(f32(table.prob + 4 * lo))
                matched = n
                if n < order { nb[n - 1] = f32(table.backoff + 4 * lo) }
                j += 1
            }
            var c = matched - 1
            while c < state.length {
                p = p + Double(state.backoffs[c])
                c += 1
            }
            let length = min(matched, order - 1)
            var next = LMState(length: length, words: .zero, backoffs: .zero)
            next.words[0] = Int32(word)
            var i = 1
            while i < length {
                next.words[i] = state.words[i - 1]
                i += 1
            }
            i = 0
            while i < length {
                next.backoffs[i] = nb[i]
                i += 1
            }
            return (p, next)
        }
    }

    /// The meta JSON's `licence` (nil when absent).
    var licence: String? {
        (try? JSONSerialization.jsonObject(with: metaJSON) as? [String: Any])?["licence"] as? String
    }
}
