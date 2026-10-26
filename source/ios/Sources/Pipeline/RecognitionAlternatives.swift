import Foundation

// Pure recognition data and candidate algorithms retained for the unchanged Transcriber.
// Extracted verbatim from the frozen source; no settings, credentials, JSON, or network dependencies.

struct CharAlt: Equatable, Sendable {
    let char: Unicode.Scalar
    let p: Double
}

struct CharTopK: Equatable, Sendable {
    let conf: Double
    let alts: [CharAlt]
}

struct GreedyChar: Equatable, Sendable {
    let char: Unicode.Scalar
    let token: Int
    let topk: CharTopK?
}

struct TokenAlternatives: Sendable {
    static let k = 8
    private(set) var tokens: [Int32] = []
    private(set) var ids: [Int32] = []
    private(set) var logps: [Float] = []
    private(set) var blanks: [Float] = []

    var count: Int { tokens.count }

    mutating func append(token: Int, ids: ArraySlice<Int32>, logps: ArraySlice<Float>, blank: Float) {
        precondition(ids.count == Self.k && logps.count == Self.k)
        tokens.append(Int32(token))
        self.ids.append(contentsOf: ids)
        self.logps.append(contentsOf: logps)
        blanks.append(blank)
    }

    /// The row of a token, if collected.
    func row(of token: Int, index: [Int32: Int]) -> Int? { index[Int32(token)] }

    func makeIndex() -> [Int32: Int] {
        var index: [Int32: Int] = [:]
        index.reserveCapacity(tokens.count)
        for (r, t) in tokens.enumerated() { index[t] = r }
        return index
    }
}

enum CharAlternatives {
    static let minP = 1e-3

    /// The greedy characters of a run (Greedy.collapse units: runs [a, e) of one non-blank label) with their first
    /// token and, when `store` has every token of the run, the reader's view at the run's peak token t* (the first t
    /// with the largest topk_logp[t][0]): q_k = exp(logp_k) / max(1 − exp(blank), 1e-12), conf = q_0, alternatives =
    /// the candidates with q_k ≥ 1e-3 in candidate order.
    static func perCharacter(labels: [Int], blank: Int, vocabulary: [String], store: TokenAlternatives?) -> [GreedyChar] {
        let index = store?.makeIndex()
        var out: [GreedyChar] = []
        var t = 0
        let n = labels.count
        while t < n {
            let label = labels[t]
            if label == blank || label < 0 {
                t += 1
                continue
            }
            var e = t + 1
            while e < n, labels[e] == label { e += 1 }
            let char = vocabulary.indices.contains(label) ? vocabulary[label].unicodeScalars.first : nil
            if let char {
                out.append(GreedyChar(char: char, token: t,
                                      topk: store.flatMap { s in topk(run: t..<e, store: s, index: index!, vocabulary: vocabulary) }))
            }
            t = e
        }
        return out
    }

    static func topk(run: Range<Int>, store: TokenAlternatives, index: [Int32: Int], vocabulary: [String]) -> CharTopK? {
        var bestRow = -1
        var best = -Float.infinity
        for t in run {
            guard let r = index[Int32(t)] else { return nil }
            let lp = store.logps[r * TokenAlternatives.k]
            if bestRow < 0 || lp > best {
                best = lp
                bestRow = r
            }
        }
        guard bestRow >= 0 else { return nil }
        let den = max(1.0 - exp(Double(store.blanks[bestRow])), 1e-12)
        var alts: [CharAlt] = []
        var conf = 0.0
        for k in 0..<TokenAlternatives.k {
            let q = exp(Double(store.logps[bestRow * TokenAlternatives.k + k])) / den
            if k == 0 { conf = q }
            let id = Int(store.ids[bestRow * TokenAlternatives.k + k])
            guard q >= minP else { continue }
            guard vocabulary.indices.contains(id), let c = vocabulary[id].unicodeScalars.first else { return nil }
            alts.append(CharAlt(char: c, p: q))
        }
        return CharTopK(conf: conf, alts: alts)
    }

    /// Cloud correction works on single characters: every vocabulary entry one scalar in U+3400..U+9FFF (the
    /// Mandarin reader; spec 3).
    static func vocabularyIsCharacters(_ vocabulary: [String]) -> Bool {
        !vocabulary.isEmpty && vocabulary.allSatisfy { v in
            let s = Array(v.unicodeScalars)
            return s.count == 1 && (0x3400...0x9FFF).contains(s[0].value)
        }
    }
}
