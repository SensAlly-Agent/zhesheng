import Foundation

// eg2zh (Mandarin, LM): CTC prefix beam search with character n-gram shallow fusion (lmver SPEC 4). Foundation
// only: the same file compiles in the Linux test package, which checks it against the Python reference
// (lmver/py/lmdecode.py) bit for bit: the same ids, the same bits of the final score, the same statistics.
//
// Numeric rules (SPEC 4.3): IEEE-754 Double, + - * only, evaluated in exactly the written order and
// parenthesisation (Swift never contracts to fused multiply-add); log-add through LogAddTable; orders from arrays
// only (no dictionary iteration).

/// The decoder's settings (reader_config.json `lm_decode`, SPEC 4.2).
struct LMDecodeConfig: Sendable, Equatable {
    /// LM weight (on the natural-log scale of the LM's log10 scores: alpha * ln 10 * log10 p).
    var alpha: Double
    /// Bonus per character.
    var beta: Double
    var beam: Int
    /// Candidates per frame (at most the bundle's K).
    var topk: Int
    /// Candidates below this natural-log posterior are not extended.
    var candMinLogp: Double
    /// A frame whose blank log-posterior is above this is a confident blank: skipped (no extension).
    var skipBlankLogp: Double
    /// After a run of this many skipped frames the LM context is reset (`</s>`, then `<s>`); 0 = never.
    var resetBlankFrames: Int
}

/// The decoder's input for a run of frames: per frame the blank log-posterior and the K best characters with
/// their log-posteriors (bundle order, best first). Row-major [count][k].
struct LMFrames: Sendable {
    let count: Int
    let k: Int
    let ids: [Int32]
    let logp: [Float]
    let blankLogp: [Float]
}

extension LMFrames {
    /// The kept tokens of one window (`window.keep`, in order) from the reader's topk_index / topk_logp [1, T, k]
    /// and blank_logp [1, T] (row-major).
    static func kept(window: Window, topkIndex: [Int32], topkLogp: [Float], blankLogp: [Float], k: Int) -> LMFrames {
        let n = window.keep.count
        precondition(topkIndex.count >= window.keep.upperBound * k && topkLogp.count >= window.keep.upperBound * k
                     && blankLogp.count >= window.keep.upperBound, "LMFrames.kept: arrays shorter than the window")
        var ids: [Int32] = []
        var logp: [Float] = []
        var blank: [Float] = []
        ids.reserveCapacity(n * k)
        logp.reserveCapacity(n * k)
        blank.reserveCapacity(n)
        for p in window.keep {
            ids.append(contentsOf: topkIndex[(p * k)..<(p * k + k)])
            logp.append(contentsOf: topkLogp[(p * k)..<(p * k + k)])
            blank.append(blankLogp[p])
        }
        return LMFrames(count: n, k: k, ids: ids, logp: logp, blankLogp: blank)
    }
}

struct LMDecodeResult: Sendable {
    /// The best prefix: character ids (vocabulary indices).
    let ids: [Int]
    /// Its final score: CTC log-probability + alpha ln10 log10 P_LM (incl. `</s>`) + beta * length.
    let score: Double
    let frames: Int
    /// Frames skipped as confident blanks.
    let skipped: Int
    /// LM context resets (SPEC 4.6).
    let resets: Int
    let lmQueries: Int
    let nodesCreated: Int
}

/// Feed frames in order (any split into calls gives the same result), then `finish()` once. Deterministic.
final class CTCLMDecoder {
    let config: LMDecodeConfig
    private let lm: EG2LanguageModel?
    private let useLM: Bool
    private let alphaLn10: Double
    private let begin: LMState

    /// A prefix: the node of its last character (root: char -1, length 0). `seq` = creation order (root 0).
    private struct Node {
        var parent: Int32
        var char: Int32
        var length: Int32
        var hash: UInt64
        var seq: Int
    }

    /// A live prefix and its probabilities: log CTC prob ending in blank / non-blank, the LM's log10 sum (with
    /// `</s>` at resets), the LM state, characters since the last `<s>`.
    private struct Entry {
        var node: Int
        var pb: Double
        var pnb: Double
        var lm10: Double
        var lmState: LMState
        var sinceReset: Int
    }

    private static let neg = -Double.infinity
    private static let fnv: UInt64 = 0x100000001B3
    private static let ln10 = 2.302585092994046

    /// Node arena; index identity = node identity. Nodes no live beam reaches are dropped by `collect()` (indices
    /// change, identities and creation order do not).
    private var nodes: [Node]
    private var beams: [Entry]
    private var nextSeq = 1
    private var blankRun = 0
    private var frames = 0, skipped = 0, resets = 0, lmQueries = 0, nodesCreated = 0
    private var finished = false
    /// The arena is compacted when it holds more nodes than the limit: first `collectMinimum`, then twice the live
    /// nodes + `collectMinimum` (results do not depend on it; tests set 1 to compact as often as possible).
    var collectMinimum = 1 << 16 {
        didSet { collectLimit = collectMinimum }
    }
    private var collectLimit = 1 << 16
    /// Compactions so far.
    private(set) var collections = 0
    private let table: UnsafeMutablePointer<Double>
    private let tableCount: Int

    // per-frame scratch, kept to avoid allocations
    private var next: [Entry] = []
    private var slot: [Int] = []
    private var candIDs: [Int] = []
    private var candLogp: [Double] = []
    private var scores: [Double] = []
    private var seqs: [Int] = []
    private var order: [Int] = []

    /// `lm` may be nil only when `config.alpha` is 0 (alpha 0 never queries the LM, SPEC A-5).
    init(lm: EG2LanguageModel?, config: LMDecodeConfig) {
        precondition(config.beam >= 1 && config.topk >= 1, "LM decoder: beam and topk must be >= 1")
        precondition(lm != nil || config.alpha == 0, "LM decoder: an LM is required when alpha != 0")
        self.config = config
        self.lm = lm
        useLM = config.alpha != 0
        alphaLn10 = config.alpha * Self.ln10
        begin = lm?.beginState() ?? LMState(length: 0, words: .zero, backoffs: .zero)
        nodes = [Node(parent: -1, char: -1, length: 0, hash: 0, seq: 0)]
        beams = [Entry(node: 0, pb: 0.0, pnb: Self.neg, lm10: 0.0, lmState: begin, sinceReset: 0)]
        let values = LogAddTable.values
        tableCount = values.count
        table = UnsafeMutablePointer<Double>.allocate(capacity: values.count)
        table.initialize(from: values, count: values.count)
    }

    deinit {
        table.deinitialize(count: tableCount)
        table.deallocate()
    }

    /// Log-add (SPEC 4.3): hi + T[Int((hi - lo) * 256)] below 30 nats, exact operation order. (`!(d < 30)` also
    /// returns hi for a NaN difference, where the reference would fail; the app never passes NaN or +inf.)
    @inline(__always)
    private func lae(_ a: Double, _ b: Double) -> Double {
        let hi: Double, lo: Double
        if a >= b { hi = a; lo = b } else { hi = b; lo = a }
        if lo == Self.neg { return hi }
        let d = hi - lo
        if !(d < 30.0) { return hi }
        return hi + table[Int(d * 256.0)]
    }

    @inline(__always)
    private func score(_ e: Entry) -> Double {
        (lae(e.pb, e.pnb) + alphaLn10 * e.lm10) + config.beta * Double(nodes[e.node].length)
    }

    /// Content equality of two nodes of equal length: both parent chains in lock step until they meet.
    @inline(__always)
    private func same(_ a: Int, _ b: Int) -> Bool {
        var a = a, b = b
        while a != b {
            if nodes[a].char != nodes[b].char { return false }
            a = Int(nodes[a].parent)
            b = Int(nodes[b].parent)
        }
        return true
    }

    func feed(_ input: LMFrames) {
        precondition(!finished, "LM decoder: feed after finish")
        precondition(input.ids.count == input.count * input.k && input.logp.count == input.ids.count
                     && input.blankLogp.count == input.count, "LM decoder: LMFrames arrays do not match count x k")
        guard input.count > 0 else { return }
        let k = input.k
        let kf = min(k, config.topk)
        input.ids.withUnsafeBufferPointer { ids in
            input.logp.withUnsafeBufferPointer { logp in
                for t in 0..<input.count {
                    frame(Double(input.blankLogp[t]), ids, logp, t * k, kf)
                }
            }
        }
    }

    private func frame(_ bl: Double, _ ids: UnsafeBufferPointer<Int32>, _ logp: UnsafeBufferPointer<Float>,
                       _ row: Int, _ kf: Int) {
        frames += 1
        if bl > config.skipBlankLogp {
            // SKIP (confident blank): every prefix ends in blank; order unchanged
            for i in beams.indices {
                beams[i].pb = lae(beams[i].pb, beams[i].pnb) + bl
                beams[i].pnb = Self.neg
            }
            blankRun += 1
            skipped += 1
            return
        }
        if config.resetBlankFrames > 0 && blankRun >= config.resetBlankFrames { boundary() }
        blankRun = 0

        candIDs.removeAll(keepingCapacity: true)
        candLogp.removeAll(keepingCapacity: true)
        for j in 0..<kf {
            let lp = Double(logp[row + j])
            if lp >= config.candMinLogp {
                candIDs.append(Int(ids[row + j]))
                candLogp.append(lp)
            }
        }
        next.removeAll(keepingCapacity: true)
        slot.removeAll(keepingCapacity: true)
        slot.append(contentsOf: repeatElement(-1, count: beams.count))

        for bi in beams.indices {
            let b = beams[bi]
            let bn = nodes[b.node]
            let t = lae(b.pb, b.pnb)
            let e = touch(bi)
            next[e].pb = lae(next[e].pb, t + bl)
            if bn.length > 0 {
                // the repeated last character: the first of the frame's kf candidates with its id
                for j in 0..<kf where Int(ids[row + j]) == Int(bn.char) {
                    next[e].pnb = lae(next[e].pnb, b.pnb + Double(logp[row + j]))
                    break
                }
            }
            for ci in candIDs.indices {
                let c = candIDs[ci]
                let lp = candLogp[ci]
                let h2 = (bn.hash ^ UInt64(bitPattern: Int64(c + 1))) &* Self.fnv
                // a live prefix with the content "b extended by c" (first in beam order)
                var q = -1
                for qi in beams.indices {
                    let x = nodes[beams[qi].node]
                    if x.length > 0 && x.hash == h2 && Int(x.char) == c && x.length == bn.length + 1
                        && same(Int(x.parent), b.node) {
                        q = qi
                        break
                    }
                }
                let f: Int
                if q >= 0 {
                    f = touch(q)
                } else {
                    nodes.append(Node(parent: Int32(b.node), char: Int32(c), length: bn.length + 1, hash: h2,
                                      seq: nextSeq))
                    nextSeq += 1
                    nodesCreated += 1
                    var l10 = 0.0
                    var state = b.lmState
                    if useLM, let lm {
                        (l10, state) = lm.score(b.lmState, c)
                        lmQueries += 1
                    }
                    f = next.count
                    next.append(Entry(node: nodes.count - 1, pb: Self.neg, pnb: Self.neg, lm10: b.lm10 + l10,
                                      lmState: state, sinceReset: b.sinceReset + 1))
                }
                let add = c == Int(bn.char) ? (b.pb + lp) : (t + lp)
                next[f].pnb = lae(next[f].pnb, add)
            }
        }

        // the `beam` best by (score desc, seq asc): a total order
        scores.removeAll(keepingCapacity: true)
        seqs.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        for i in next.indices {
            scores.append(score(next[i]))
            seqs.append(nodes[next[i].node].seq)
            order.append(i)
        }
        let (scores, seqs) = (self.scores, self.seqs)
        order.sort { a, b in scores[a] > scores[b] || (scores[a] == scores[b] && seqs[a] < seqs[b]) }
        let keep = min(order.count, config.beam)
        beams.removeAll(keepingCapacity: true)
        for i in 0..<keep { beams.append(next[order[i]]) }
        if nodes.count > collectLimit { collect() }
    }

    /// The entry of `beams[bi]`'s node in `next` (created on first touch with pb = pnb = -inf and that beam's LM
    /// fields). Beams are unique by node, so a beam index identifies its node.
    @inline(__always)
    private func touch(_ bi: Int) -> Int {
        if slot[bi] < 0 {
            let b = beams[bi]
            slot[bi] = next.count
            next.append(Entry(node: b.node, pb: Self.neg, pnb: Self.neg, lm10: b.lm10, lmState: b.lmState,
                              sinceReset: b.sinceReset))
        }
        return slot[bi]
    }

    /// LM context reset before a frame after a long pause (SPEC 4.6): `</s>` closes each beam's sentence, the
    /// next character starts from `<s>`.
    private func boundary() {
        var changed = false
        for i in beams.indices where beams[i].sinceReset > 0 {
            var l10 = 0.0
            if useLM, let lm {
                l10 = lm.score(beams[i].lmState, lm.endOfSentence).log10
                lmQueries += 1
            }
            beams[i].lm10 = beams[i].lm10 + l10
            beams[i].lmState = begin
            beams[i].sinceReset = 0
            changed = true
        }
        if changed { resets += 1 }
    }

    /// Drops the nodes no live beam reaches (parents always precede their children in the arena).
    private func collect() {
        var live = [Bool](repeating: false, count: nodes.count)
        for b in beams {
            var n = b.node
            while n >= 0 && !live[n] {
                live[n] = true
                n = Int(nodes[n].parent)
            }
        }
        var index = [Int32](repeating: -1, count: nodes.count)
        var count = 0
        for i in nodes.indices where live[i] {
            var node = nodes[i]
            if node.parent >= 0 { node.parent = index[Int(node.parent)] }
            index[i] = Int32(count)
            nodes[count] = node
            count += 1
        }
        nodes.removeLast(nodes.count - count)
        for i in beams.indices { beams[i].node = Int(index[beams[i].node]) }
        collectLimit = 2 * count + collectMinimum
        collections += 1
    }

    /// The best prefix after `</s>` (SPEC 4.6). Call once, after the last frame.
    func finish() -> LMDecodeResult {
        precondition(!finished, "LM decoder: finish twice")
        finished = true
        var best = -1
        var bestFinal = 0.0
        for i in beams.indices {
            let b = beams[i]
            let length = Int(nodes[b.node].length)
            var eos = 0.0
            if useLM, let lm, b.sinceReset > 0 || length == 0 {
                eos = lm.score(b.lmState, lm.endOfSentence).log10
                lmQueries += 1
            }
            let final = (lae(b.pb, b.pnb) + alphaLn10 * (b.lm10 + eos)) + config.beta * Double(length)
            if best < 0 || final > bestFinal
                || (final == bestFinal && nodes[b.node].seq < nodes[beams[best].node].seq) {
                best = i
                bestFinal = final
            }
        }
        var ids: [Int] = []
        var n = beams[best].node
        while nodes[n].parent >= 0 {
            ids.append(Int(nodes[n].char))
            n = Int(nodes[n].parent)
        }
        ids.reverse()
        return LMDecodeResult(ids: ids, score: bestFinal, frames: frames, skipped: skipped, resets: resets,
                              lmQueries: lmQueries, nodesCreated: nodesCreated)
    }
}

/// A CTCLMDecoder on a detached task, fed through a stream: Transcriber.run yields each window's LMFrames as the
/// window finishes, so decoding overlaps the stages of the later windows. `finish()` ends the stream and returns the
/// result and the decoder's CPU milliseconds (its feed / finish calls, CLOCK_THREAD_CPUTIME_ID: a synchronous call
/// stays on one thread); `cancel()` drops it (an error elsewhere).
struct LMDecodingTask: Sendable {
    private let feed: AsyncStream<LMFrames>.Continuation
    private let task: Task<(result: LMDecodeResult, cpuMs: Double), Never>

    init(lm: EG2LanguageModel?, config: LMDecodeConfig) {
        let (stream, feed) = AsyncStream<LMFrames>.makeStream()
        self.feed = feed
        task = Task.detached(priority: .userInitiated) { () -> (result: LMDecodeResult, cpuMs: Double) in
            let decoder = CTCLMDecoder(lm: lm, config: config)
            var cpu = 0.0
            for await frames in stream {
                let t = ThreadCPUClock.seconds()
                decoder.feed(frames)
                cpu += ThreadCPUClock.seconds() - t
            }
            let t = ThreadCPUClock.seconds()
            let result = decoder.finish()
            cpu += ThreadCPUClock.seconds() - t
            return (result, cpu * 1000)
        }
    }

    func yield(_ frames: LMFrames) { feed.yield(frames) }

    func finish() async -> (result: LMDecodeResult, cpuMs: Double) {
        feed.finish()
        return await task.value
    }

    func cancel() {
        feed.finish()
        task.cancel()
    }
}

/// CPU seconds of the calling thread (CLOCK_THREAD_CPUTIME_ID).
enum ThreadCPUClock {
    static func seconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}
