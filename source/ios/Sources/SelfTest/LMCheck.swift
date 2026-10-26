import Foundation

/// eg2zh (Mandarin, LM): the Swift LM reader, LM decoder and window plan against the Python reference's fixtures
/// (lmver/fixtures/lm, SPEC 6.6), bit for bit. `--selftest lmcheck` runs it on the Mac / iPhone; the Linux test
/// package runs the same code. Foundation only.
///
/// Fixtures: MANIFEST.json, tiny.eg2lm, queries_tiny.json / queries_real.json (log10 p and the next state of every
/// query, as float hex), plans.json (Windowing.plan for 40 frame counts), case_NNN/ (topk_index.npy <i4 [F, K],
/// topk_logp.npy <f2, blank_logp.npy <f2, case.json: config, lm "tiny" | "real", windows null | {"frames": n} (then
/// the arrays are the windows' 750 rows each, concatenated, and the case goes through Windowing.plan +
/// LMFrames.kept like the app), expected {ids, score_hex, frames, skipped, resets, lm_queries, nodes_created}).
enum LMCheck {
    struct QueryReport: Sendable {
        var file: String
        var total = 0
        /// log10 p bitwise equal and the next state equal.
        var passed = 0
        var maxAbsDiff = 0.0
        var maxRelDiff = 0.0
        var failures: [String] = []
    }

    struct CaseReport: Sendable {
        var dir: String
        var name: String
        var lm: String
        var idsEqual = false
        var scoreBitsEqual = false
        var statsEqual = false
        var frames = 0
        var cpuSeconds = 0.0
        var ids: [Int] = []
        var expectedIDs: [Int] = []
        var score = 0.0
        var expectedScore = 0.0
        var detail = ""
        var pass: Bool { idsEqual && scoreBitsEqual && statsEqual }
    }

    struct Report: Sendable {
        var queries: [QueryReport] = []
        var cases: [CaseReport] = []
        /// Cases or query sets not run (their LM missing).
        var skipped: [String] = []
        var queriesTotal = 0
        var casesTotal = 0
        var plansPassed = 0
        var plansTotal = 0
        var failures: [String] = []

        var queriesPassed: Int { queries.reduce(0) { $0 + $1.passed } }
        var casesPassed: Int { cases.filter(\.pass).count }
        var pass: Bool {
            failures.isEmpty && queriesPassed == queriesTotal && casesPassed == casesTotal && plansPassed == plansTotal
        }
        var line: String {
            "lmcheck queries \(queriesPassed)/\(queriesTotal), decodes \(casesPassed)/\(casesTotal), plans "
                + "\(plansPassed)/\(plansTotal)" + (skipped.isEmpty ? "" : ", \(skipped.count) skipped (no real LM)")
                + ", " + (pass ? "PASS" : "FAIL")
        }
    }

    static let fixtureContract = WindowContract(frames: 3000, leftOverlap: 96, dropLast: 1)

    /// Every fixture: the query sets, the decode cases and the plans. `realLM` = the shipped LM (the cases and
    /// queries marked "real" are skipped, and counted as not passed, without it).
    static func run(fixtures: URL, realLM: EG2LanguageModel?, log: (String) -> Void = { _ in }) throws -> Report {
        let manifest = try object(fixtures.appending(path: "MANIFEST.json"))
        guard manifest["schema"] as? String == "eg2zh-lm-fixtures/1" else {
            throw TranscribeError.model("\(fixtures.path)/MANIFEST.json is not eg2zh-lm-fixtures/1")
        }
        var report = Report()
        let tiny = try EG2LanguageModel(url: fixtures.appending(path: manifest["tiny_lm"] as? String ?? "tiny.eg2lm"))
        if let vocab = manifest["vocab_sha256"] as? String, hex(tiny.vocabSHA256) != vocab {
            report.failures.append("tiny.eg2lm vocab SHA-256 \(hex(tiny.vocabSHA256)) != MANIFEST \(vocab)")
        }
        if let realLM, hex(realLM.vocabSHA256) != hex(tiny.vocabSHA256) {
            report.failures.append("the real LM was written for another vocab.txt than the fixtures")
        }
        let lms: [String: EG2LanguageModel] = realLM.map { ["tiny": tiny, "real": $0] } ?? ["tiny": tiny]
        for set in manifest["query_sets"] as? [[String: Any]] ?? [] {
            guard let file = set["file"] as? String, let kind = set["lm"] as? String else { continue }
            let total = Int(number(set["queries"]) ?? 0)
            report.queriesTotal += total
            guard let lm = lms[kind] else {
                report.skipped.append(file)
                log("\(file): skipped (no \(kind) LM)")
                continue
            }
            let q = try queries(fixtures.appending(path: file), lm: lm)
            if q.total != total { report.failures.append("\(file): \(q.total) queries, MANIFEST says \(total)") }
            report.queries.append(q)
            log(String(format: "%@: %ld/%ld queries bitwise equal (max |d| %.3g, max rel %.3g)", file, q.passed,
                       q.total, q.maxAbsDiff, q.maxRelDiff))
            for f in q.failures.prefix(5) { log("  \(f)") }
        }
        let planFile = fixtures.appending(path: manifest["plans"] as? String ?? "plans.json")
        let (contract, planResult) = try plans(planFile)
        report.plansPassed = planResult.passed
        report.plansTotal = planResult.total
        report.failures += planResult.failures.prefix(10)
        log("plans.json: \(planResult.passed)/\(planResult.total) plans equal Windowing.plan")
        for entry in manifest["cases"] as? [[String: Any]] ?? [] {
            guard let dir = entry["dir"] as? String else { continue }
            report.casesTotal += 1
            let kind = entry["lm"] as? String ?? "tiny"
            guard let lm = lms[kind] else {
                report.skipped.append(dir)
                continue
            }
            let c = try decodeCase(fixtures.appending(path: dir, directoryHint: .isDirectory), lm: lm,
                                   contract: contract)
            report.cases.append(c)
            if !c.pass { log("\(dir) \(c.name) [\(kind)]: FAIL \(c.detail)") }
        }
        let frames = report.cases.reduce(0) { $0 + $1.frames }
        let cpu = report.cases.reduce(0) { $0 + $1.cpuSeconds }
        log(String(format: "decode cases: %ld/%ld equal (ids, score bits, statistics); %ld frames in %.3f CPU s",
                   report.casesPassed, report.casesTotal, frames, cpu))
        return report
    }

    /// One query set: from beginState, every word scored; after `</s>` the next query starts from beginState.
    static func queries(_ url: URL, lm: EG2LanguageModel) throws -> QueryReport {
        let json = try object(url)
        var report = QueryReport(file: url.lastPathComponent)
        for sequence in json["sequences"] as? [[String: Any]] ?? [] {
            let words = (sequence["words"] as? [Any] ?? []).compactMap { number($0).map(Int.init) }
            let expected = sequence["log10_hex"] as? [String] ?? []
            let states = sequence["state"] as? [[Any]] ?? []
            guard words.count == expected.count, words.count == states.count else {
                report.failures.append("a sequence with \(words.count) words, \(expected.count) values")
                continue
            }
            var state = lm.beginState()
            for (i, word) in words.enumerated() {
                report.total += 1
                guard word >= 0, word < lm.idCount, word != lm.beginOfSentence, let want = Double(expected[i]),
                      let wantState = parseState(states[i]) else {
                    report.failures.append("query \(report.total): unreadable (word \(word))")
                    continue
                }
                let (got, next) = lm.score(state, word)
                let diff = abs(got - want)
                report.maxAbsDiff = max(report.maxAbsDiff, diff)
                if want != 0 { report.maxRelDiff = max(report.maxRelDiff, diff / abs(want)) }
                if got.bitPattern == want.bitPattern && next == wantState {
                    report.passed += 1
                } else if report.failures.count < 20 {
                    report.failures.append("query \(report.total) word \(word): \(got) vs \(want), state \(next) vs \(wantState)")
                }
                state = word == lm.endOfSentence ? lm.beginState() : next
            }
        }
        return report
    }

    /// [L, w0, w1, w2, w3, b0_hex, b1_hex, b2_hex, b3_hex]
    private static func parseState(_ row: [Any]) -> LMState? {
        guard row.count == 9, let length = number(row[0]) else { return nil }
        var state = LMState(length: Int(length), words: .zero, backoffs: .zero)
        for i in 0..<4 {
            guard let w = number(row[1 + i]), let hexValue = row[5 + i] as? String,
                  let b = Double(hexValue) else { return nil }
            state.words[i] = Int32(w)
            state.backoffs[i] = Float(b)
        }
        return state
    }

    /// plans.json: Windowing.plan against the hand-derived plans; returns the fixtures' contract too.
    static func plans(_ url: URL) throws -> (WindowContract, (passed: Int, total: Int, failures: [String])) {
        let json = try object(url)
        guard let c = json["contract"] as? [String: Any], let frames = number(c["frames"]),
              let left = number(c["leftOverlap"]), let drop = number(c["dropLast"]) else {
            throw TranscribeError.model("\(url.lastPathComponent): no contract")
        }
        let contract = WindowContract(frames: Int(frames), leftOverlap: Int(left), dropLast: Int(drop))
        var passed = 0, total = 0
        var failures: [String] = []
        for entry in json["plans"] as? [[String: Any]] ?? [] {
            total += 1
            guard let n = number(entry["frames"]).map(Int.init) else { continue }
            let want = (entry["windows"] as? [[Any]] ?? []).map { $0.compactMap { number($0).map(Int.init) } }
            let got = Windowing.plan(frames: n, contract: contract).map {
                [$0.index, $0.token0, $0.frame0, $0.frames, $0.validTokens, $0.keep.lowerBound, $0.keep.upperBound]
            }
            if got == want { passed += 1 } else { failures.append("plan(frames: \(n)): \(got) vs \(want)") }
        }
        return (contract, (passed, total, failures))
    }

    /// One decode case through LMFrames + CTCLMDecoder, compared with the reference's result.
    static func decodeCase(_ dir: URL, lm: EG2LanguageModel, contract: WindowContract = fixtureContract) throws
        -> CaseReport {
        let json = try object(dir.appending(path: "case.json"))
        guard json["config"] is [String: Any], let expected = json["expected"] as? [String: Any] else {
            throw TranscribeError.model("\(dir.lastPathComponent)/case.json has no config / expected")
        }
        var report = CaseReport(dir: dir.lastPathComponent, name: json["name"] as? String ?? "?",
                                lm: json["lm"] as? String ?? "?")
        let config = try decodeConfig(dir.appending(path: "case.json"))
        let index = try NPY(dir.appending(path: "topk_index.npy"))
        let ids = try index.ints().map { Int32(truncatingIfNeeded: $0) }
        let logp = try NPY(dir.appending(path: "topk_logp.npy")).floats()
        let blank = try NPY(dir.appending(path: "blank_logp.npy")).floats()
        guard index.shape.count == 2, logp.count == ids.count, blank.count == index.shape[0] else {
            throw TranscribeError.model("\(dir.lastPathComponent): array shapes do not match")
        }
        let k = index.shape[1]
        var chunks: [LMFrames] = []
        if let windows = json["windows"] as? [String: Any], let frames = number(windows["frames"]) {
            let T = contract.tokens
            let plan = Windowing.plan(frames: Int(frames), contract: contract)
            guard blank.count == plan.count * T else {
                throw TranscribeError.model("\(dir.lastPathComponent): \(blank.count) rows for \(plan.count) windows")
            }
            for window in plan {
                let r = window.index * T
                chunks.append(LMFrames.kept(window: window, topkIndex: Array(ids[(r * k)..<((r + T) * k)]),
                                            topkLogp: Array(logp[(r * k)..<((r + T) * k)]),
                                            blankLogp: Array(blank[r..<(r + T)]), k: k))
            }
        } else {
            chunks.append(LMFrames(count: blank.count, k: k, ids: ids, logp: logp, blankLogp: blank))
        }
        let t0 = ThreadCPUClock.seconds()
        let decoder = CTCLMDecoder(lm: config.alpha == 0 ? nil : lm, config: config)
        for chunk in chunks { decoder.feed(chunk) }
        let result = decoder.finish()
        report.cpuSeconds = ThreadCPUClock.seconds() - t0
        report.frames = result.frames
        report.ids = result.ids
        report.score = result.score
        report.expectedIDs = (expected["ids"] as? [Any] ?? []).compactMap { number($0).map(Int.init) }
        report.expectedScore = Double(expected["score_hex"] as? String ?? "") ?? .nan
        report.idsEqual = result.ids == report.expectedIDs
        report.scoreBitsEqual = result.score.bitPattern == report.expectedScore.bitPattern
        let want = ["frames", "skipped", "resets", "lm_queries", "nodes_created"].map {
            number(expected[$0]).map(Int.init) ?? -1
        }
        let got = [result.frames, result.skipped, result.resets, result.lmQueries, result.nodesCreated]
        report.statsEqual = got == want
        if !report.pass {
            report.detail = "ids \(report.idsEqual ? "equal" : "\(result.ids.count) vs \(report.expectedIDs.count)"), "
                + "score \(result.score) vs \(report.expectedScore), stats \(got) vs \(want)"
        }
        return report
    }

    /// The "config" object of a JSON file (case.json, devcheck MANIFEST.json) as the decoder's settings, read with
    /// JSONDecoder (exact doubles) through the same parser as reader_config.json's `lm_decode`.
    static func decodeConfig(_ url: URL) throws -> LMDecodeConfig {
        guard case .object(var block)? = try JSONValue.decode(Data(contentsOf: url))["config"] else {
            throw TranscribeError.model("\(url.lastPathComponent) has no config")
        }
        block["mode"] = .string("lm")
        block["lm"] = .string("fixture.eg2lm")
        guard let settings = LMDecodeSettings.parse(.object(block)), settings.problem == nil else {
            throw TranscribeError.model("\(url.lastPathComponent): config does not parse")
        }
        return settings.config
    }

    /// A JSON number from JSONSerialization as Double (NSNumber on Apple platforms, Int or Double on Linux); used for
    /// counts and ids only (exact integers).
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let x as Double: x
        case let x as Int: Double(x)
        case let x as NSNumber: x.doubleValue
        default: nil
        }
    }

    static func object(_ url: URL) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw TranscribeError.model("\(url.lastPathComponent) is not a JSON object")
        }
        return json
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
