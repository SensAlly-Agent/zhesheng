import Foundation

// eg2zh (Mandarin, LM): which decoding a transcriber uses (lmver SPEC 5.2 / 5.3). Foundation only (Linux-tested):
// the caller (Transcriber.load) supplies what needs Core AI or CryptoKit: the reader's output contract and the
// SHA-256 of vocab.txt.

/// greedy: the reader's top-1 labels, greedy CTC (the app as before). lm: CTC prefix beam search with the
/// character n-gram LM of the model folder.
enum DecodeMode: String, Sendable, Codable, CaseIterable {
    case greedy
    case lm
}

/// A JSON value read with JSONDecoder, whose numbers are correctly rounded doubles. (JSONSerialization returns a
/// long decimal such as -0.01005033585350145 as an NSDecimalNumber whose doubleValue can be one ulp off: measured with
/// Swift 6.1 on Linux. The decoder's settings must be the exact doubles the reference decoder used.)
enum JSONValue: Decodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let x = try? c.decode(Bool.self) {
            self = .bool(x)
        } else if let x = try? c.decode(Double.self) {
            self = .number(x)
        } else if let x = try? c.decode(String.self) {
            self = .string(x)
        } else if let x = try? c.decode([JSONValue].self) {
            self = .array(x)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    var double: Double? {
        if case .number(let x) = self { x } else { nil }
    }

    var string: String? {
        if case .string(let x) = self { x } else { nil }
    }
}

/// reader_config.json `lm_decode` (SPEC 5.2). A malformed block is kept with `problem` set: LM decoding then falls
/// back to greedy with that reason; it never fails the model folder's load.
struct LMDecodeSettings: Sendable, Equatable {
    var mode: DecodeMode
    /// The LM file's name in the model folder root.
    var lmFile: String
    /// Informational: checked by `--selftest lmcheck`, not at load.
    var lmSHA256: String
    var config: LMDecodeConfig
    var tunedOn: String?
    /// nil when the block is usable, else why not.
    var problem: String?

    /// The `lm_decode` block of reader_config.json's bytes; nil when the file has none (= greedy, silently).
    static func parse(readerConfig data: Data) -> LMDecodeSettings? {
        do {
            return parse(try JSONValue.decode(data)["lm_decode"])
        } catch {
            return invalid("reader_config.json does not decode (\(error.localizedDescription))")
        }
    }

    private static func invalid(_ problem: String) -> LMDecodeSettings {
        LMDecodeSettings(mode: .lm, lmFile: "", lmSHA256: "",
                         config: LMDecodeConfig(alpha: 0, beta: 0, beam: 1, topk: 1, candMinLogp: 0, skipBlankLogp: 0,
                                                resetBlankFrames: 0),
                         tunedOn: nil, problem: problem)
    }

    /// nil when there is no block (key missing or null).
    static func parse(_ value: JSONValue?) -> LMDecodeSettings? {
        guard let value, value != .null else { return nil }
        var settings = invalid("")
        settings.problem = nil
        guard case .object = value else { return invalid("lm_decode is not an object") }
        var problems: [String] = []
        let mode = value["mode"]?.string
        switch mode {
        case "lm"?: settings.mode = .lm
        case "greedy"?: settings.mode = .greedy
        default: problems.append("mode \(mode.map { "'\($0)'" } ?? "missing") is not lm | greedy")
        }
        if let schema = value["schema"], schema != .number(1) { problems.append("schema is not 1") }
        let file = value["lm"]?.string ?? ""
        if file.isEmpty || file.contains("/") || file == "." || file == ".." {
            problems.append("lm '\(file)' is not a file name in the model folder")
        }
        settings.lmFile = file
        settings.lmSHA256 = value["lm_sha256"]?.string ?? ""
        settings.tunedOn = value["tuned_on"]?.string
        func real(_ key: String) -> Double {
            guard let x = value[key]?.double, x.isFinite else {
                problems.append("\(key) is not a finite number")
                return 0
            }
            return x
        }
        func integer(_ key: String, _ range: ClosedRange<Int>) -> Int {
            guard let x = value[key]?.double, x == x.rounded(), x >= Double(range.lowerBound),
                  x <= Double(range.upperBound) else {
                problems.append("\(key) is not an integer in \(range.lowerBound)…\(range.upperBound)")
                return range.lowerBound
            }
            return Int(x)
        }
        settings.config = LMDecodeConfig(alpha: real("alpha"), beta: real("beta"), beam: integer("beam", 1...1024),
                                         topk: integer("topk", 1...1024), candMinLogp: real("cand_min_logp"),
                                         skipBlankLogp: real("skip_blank_logp"),
                                         resetBlankFrames: integer("reset_blank_frames", 0...1_000_000))
        if !problems.isEmpty { settings.problem = "lm_decode: " + problems.joined(separator: "; ") }
        return settings
    }
}

extension LMDecodeConfig {
    /// The `lm_decode` keys (result.json `params`).
    var record: [String: Any] {
        ["alpha": alpha, "beta": beta, "beam": beam, "topk": topk, "cand_min_logp": candMinLogp,
         "skip_blank_logp": skipBlankLogp, "reset_blank_frames": resetBlankFrames]
    }
}

/// The decoding a loaded transcriber uses: what was asked for, what is active, and why LM decoding is off when it is.
struct DecodeSetup: Sendable {
    /// The reader outputs LM decoding reads (besides the three greedy ones).
    static let outputNames = ["topk_index", "topk_logp", "blank_logp"]

    /// One reader output: shape and dtype ("int32", "float16", "float32", …).
    struct Output: Sendable, Equatable {
        let shape: [Int]
        let dtype: String
    }

    let requested: DecodeMode
    let active: DecodeMode
    /// Why LM decoding is off although it was requested (nil otherwise).
    let fallbackReason: String?
    /// The LM decoder's settings as used (`topk` capped at the bundle's K); nil when LM decoding is off.
    let config: LMDecodeConfig?
    let lm: EG2LanguageModel?
    let lmFile: String?
    /// Candidates per token the reader returns (K of topk_index); 0 when LM decoding is off.
    let k: Int
    /// Remarks for the log (e.g. topk capped at K).
    let notes: [String]

    static let greedy = DecodeSetup(requested: .greedy, active: .greedy, fallbackReason: nil, config: nil, lm: nil,
                                    lmFile: nil, k: 0, notes: [])

    /// SPEC 5.3: requested = `override` ?? `settings.mode` ?? greedy. LM decoding is active only when the settings
    /// are valid, the LM file loads and belongs to this vocabulary, and the reader returns topk_index int32 [1, T, K],
    /// topk_logp float16/float32 [1, T, K] and blank_logp float16/float32 [1, T]; otherwise greedy with the reason.
    static func resolve(override: DecodeMode?, settings: LMDecodeSettings?, root: URL, vocabularyCount: Int,
                        vocabSHA256: [UInt8], tokens: Int, outputs: [String: Output],
                        loadLM: (URL) throws -> EG2LanguageModel = { try EG2LanguageModel(url: $0) }) -> DecodeSetup {
        let requested = override ?? settings?.mode ?? .greedy
        guard requested == .lm else {
            return DecodeSetup(requested: requested, active: .greedy, fallbackReason: nil, config: nil, lm: nil,
                               lmFile: nil, k: 0, notes: [])
        }
        func off(_ reason: String) -> DecodeSetup {
            DecodeSetup(requested: .lm, active: .greedy, fallbackReason: reason, config: nil, lm: nil,
                        lmFile: settings?.lmFile, k: 0, notes: [])
        }
        // 1. the settings
        guard let settings else { return off("reader_config.json has no lm_decode") }
        if let problem = settings.problem { return off(problem) }
        // 2. the LM file
        let url = root.appending(path: settings.lmFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return off("no \(settings.lmFile) in the model folder")
        }
        let lm: EG2LanguageModel
        do {
            lm = try loadLM(url)
        } catch {
            return off("\(settings.lmFile) does not load (\(error.localizedDescription))")
        }
        guard lm.vocabSHA256 == vocabSHA256 else {
            return off("\(settings.lmFile) was written for another vocab.txt (SHA-256 differs)")
        }
        guard lm.vocabularyCount == vocabularyCount else {
            return off("\(settings.lmFile) has \(lm.vocabularyCount) characters, vocab.txt \(vocabularyCount)")
        }
        // 3. the reader's outputs
        guard let index = outputs["topk_index"], index.dtype == "int32", index.shape.count == 3,
              index.shape[0] == 1, index.shape[1] == tokens, index.shape[2] >= 1 else {
            return off("the reader returns no topk_index int32 [1, \(tokens), K] (a bundle without LM outputs)")
        }
        let k = index.shape[2]
        guard let logp = outputs["topk_logp"], ["float16", "float32"].contains(logp.dtype),
              logp.shape == [1, tokens, k] else {
            return off("the reader returns no topk_logp float16/float32 [1, \(tokens), \(k)]")
        }
        guard let blank = outputs["blank_logp"], ["float16", "float32"].contains(blank.dtype),
              blank.shape == [1, tokens] else {
            return off("the reader returns no blank_logp float16/float32 [1, \(tokens)]")
        }
        var config = settings.config
        var notes: [String] = []
        if config.topk > k {
            notes.append("lm_decode topk \(config.topk) > the reader's K \(k): using \(k)")
            config.topk = k
        }
        return DecodeSetup(requested: .lm, active: .lm, fallbackReason: nil, config: config, lm: lm,
                           lmFile: settings.lmFile, k: k, notes: notes)
    }

    /// One line for the log and the settings screen.
    var summary: String {
        switch active {
        case .lm:
            let c = config.map { String(format: "alpha %.3g, beta %.3g, beam %ld, topk %ld", $0.alpha, $0.beta, $0.beam, $0.topk) } ?? ""
            return "LM decoding: \(lmFile ?? "?") (order \(lm?.order ?? 0)), \(c)"
        case .greedy:
            if let fallbackReason { return "LM decoding off: \(fallbackReason); greedy decoding" }
            return "greedy decoding"
        }
    }

    /// result.json `model.decode`.
    var record: [String: Any] {
        ["requested": requested.rawValue, "active": active.rawValue, "fallback_reason": fallbackReason ?? NSNull(),
         "lm_file": lmFile ?? NSNull(), "lm_order": lm?.order ?? NSNull(), "lm_bytes": lm?.fileBytes ?? NSNull(),
         "k": k, "params": config?.record ?? NSNull(), "notes": notes]
    }
}
