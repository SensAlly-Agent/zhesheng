// 折声 (zhesheng): changed from eg2-transcribe at e6b7d5d (Apache-2.0). See NOTICE.
import CoreAI
import CryptoKit
import Foundation

/// The whole transcriber: audio file → 16 kHz mono → log-mel (whole file, once) → 30 s windows → the pipeline's
/// stages per window → labels of each window's kept tokens → greedy CTC → words.
///
/// eg2zh (Mandarin, LM): with reader_config.json `lm_decode` (mode "lm") and its LM file in the model folder, the
/// transcript is the LM decoder's instead: CTC prefix beam search over the reader's top-K candidates with a
/// character n-gram LM (Pipeline/LM), fed each window's kept tokens as the window finishes, on its own task. The
/// greedy read-out is still computed (and kept in `Run.decode`); without the LM file or the reader's LM outputs the
/// app decodes greedily and logs why.
///
/// Stages run in order on a window. With `overlap`, consecutive windows are staggered: stage k + 1 of window n runs
/// at the same time as stage k of window n + 1 (two windows in flight for an encoder + reader pipeline), each stage
/// still one call at a time. The labels are the same either way; only the wall clock changes.
final class Transcriber: Sendable {
    let form: PipelineForm
    let stages: [Stage]
    let contract: WindowContract
    let vocabulary: [String]
    /// eg2zh (Mandarin): what joins the units of the transcript (reader_config.json `join`: "" for characters, " " for
    /// words).
    let join: String
    let extractor: LogMelExtractor
    /// Load (open or specialize) seconds per stage, then the warm-up call's milliseconds per stage.
    let loadSeconds: [Double]
    let warmUpMilliseconds: [Double]
    /// The model folder's fingerprint check before the load (and whether Core AI's cache was cleared).
    let cacheCheck: ModelCache.Check
    /// eg2zh (Mandarin, LM): greedy or LM decoding, with the LM and its settings (DecodeSetup.resolve).
    let decodeSetup: DecodeSetup

    private init(form: PipelineForm, stages: [Stage], contract: WindowContract, vocabulary: [String], join: String,
                 extractor: LogMelExtractor, loadSeconds: [Double], warmUpMilliseconds: [Double],
                 cacheCheck: ModelCache.Check, decodeSetup: DecodeSetup) {
        self.form = form
        self.stages = stages
        self.contract = contract
        self.vocabulary = vocabulary
        self.join = join
        self.extractor = extractor
        self.loadSeconds = loadSeconds
        self.warmUpMilliseconds = warmUpMilliseconds
        self.cacheCheck = cacheCheck
        self.decodeSetup = decodeSetup
    }

    var blankID: Int { vocabulary.count }

    /// Loads every stage of `form` from the model folder, checks the contracts end to end, and warms each stage up.
    /// Before anything is loaded, Core AI's cache is cleared if the folder is not the one loaded last (ModelCache).
    /// eg2zh (Mandarin, LM): `decode` overrides reader_config.json `lm_decode.mode` (nil: the config's, else greedy).
    static func load(folder: ModelFolder, form: PipelineForm, cache: ModelCache.Mode = .check,
                     decode: DecodeMode? = nil,
                     status: @Sendable (String) -> Void = { _ in }) async throws -> Transcriber {
        let cacheCheck = try ModelCache.prepare(folder, mode: cache)
        status(cacheCheck.summary)
        let vocabulary = try Vocabulary.load(folder.root.appending(path: folder.reader.vocabFile))
        if let expected = folder.reader.vocabSize, expected != vocabulary.count {
            throw TranscribeError.model("vocab.txt has \(vocabulary.count) words, reader_config.json says \(expected)")
        }
        let extractor = try LogMelExtractor(filtersURL: folder.root.appending(path: LogMelExtractor.filtersFile))
        var stages: [Stage] = []
        for spec in form.stages {
            guard let url = folder.bundleURL(spec.bundle) else {
                throw TranscribeError.model("no \(spec.bundle).aimodelc or .aimodel in \(folder.bundleFolders.map(\.lastPathComponent))")
            }
            status("Loading \(spec.name) (\(url.lastPathComponent), \(spec.compute))")
            stages.append(try await Stage.load(spec, url: url))
        }
        guard let features = stages.first?.inputs["features"], features.shape.count == 3,
              features.shape[2] == LogMelExtractor.mels else {
            throw TranscribeError.contract("the first stage takes no features [1, frames, \(LogMelExtractor.mels)]")
        }
        let contract = try folder.reader.contract(encoderFrames: features.shape[1])
        guard let last = stages.last else { throw TranscribeError.model("form \(form.id) has no stages") }
        for name in ["top1_index", "top1_logit", "blank_logit"] {
            guard last.outputs[name]?.shape == [1, contract.tokens] else {
                throw TranscribeError.contract("the last stage returns no \(name) [1, \(contract.tokens)]")
            }
        }
        // eg2zh (Mandarin, LM): LM decoding when asked for and the folder has what it needs, else greedy (the reason
        // goes to the log); never a load failure
        var lmOutputs: [String: DecodeSetup.Output] = [:]
        for name in DecodeSetup.outputNames {
            if let spec = last.outputs[name] { lmOutputs[name] = .init(shape: spec.shape, dtype: dtypeName(spec.scalarType)) }
        }
        let wantsLM = (decode ?? folder.reader.lmDecode?.mode ?? .greedy) == .lm
        let vocabSHA256 = wantsLM
            ? Array(SHA256.hash(data: try Data(contentsOf: folder.root.appending(path: folder.reader.vocabFile)))) : []
        let decodeSetup = DecodeSetup.resolve(override: decode, settings: folder.reader.lmDecode, root: folder.root,
                                              vocabularyCount: vocabulary.count, vocabSHA256: vocabSHA256,
                                              tokens: contract.tokens, outputs: lmOutputs)
        status(decodeSetup.summary)
        for note in decodeSetup.notes { status(note) }
        var warm: [Double] = []
        for stage in stages {
            status("Warming up \(stage.spec.name)")
            warm.append(try await stage.warmUp())
        }
        return Transcriber(form: form, stages: stages, contract: contract, vocabulary: vocabulary,
                           join: folder.reader.join, extractor: extractor, loadSeconds: stages.map(\.loadSeconds),
                           warmUpMilliseconds: warm, cacheCheck: cacheCheck, decodeSetup: decodeSetup)
    }

    /// eg2zh (Mandarin, LM): a Core AI scalar type's name for DecodeSetup.
    private static func dtypeName(_ type: NDArray.ScalarType) -> String {
        switch type {
        case .int32: "int32"
        case .float16: "float16"
        case .float32: "float32"
        default: "\(type)"
        }
    }

    // MARK: - One recording

    struct Result: Sendable {
        let audioSeconds: Double
        let leadingSilenceSeconds: Double
        let decodeSeconds: Double
        let logMelSeconds: Double
        let logMel: LogMelExtractor.Breakdown
        let frames: Int
        let run: Run

        /// Decode + log-mel + windows.
        var totalSeconds: Double { decodeSeconds + logMelSeconds + run.wallSeconds }
        /// Audio seconds per wall second, end to end.
        var realtimeFactor: Double { audioSeconds / totalSeconds }
        var text: String { run.text }
    }

    /// eg2zh (Mandarin, cloud): `alternatives` also keeps the reader's candidates of every character for the optional
    /// cloud correction (only when it is enabled; false = the offline path, unchanged).
    func transcribe(_ url: URL, overlap: Bool, decode: DecodeMode? = nil, alternatives: Bool = false,
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let audio = try AudioDecoder.decode(url)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let leadingSilenceSamples = RecognitionPrelude.prefixSampleCount(for: audio.samples.count)
        let (features, breakdown) = extractor.featuresTimed(audio.samples, leadingSilenceSamples: leadingSilenceSamples)
        let t2 = DispatchTime.now().uptimeNanoseconds
        let frames = features.count / LogMelExtractor.mels
        let run = try await self.run(features: features, frames: frames, overlap: overlap, decode: decode,
                                     leadingSilenceFrames: leadingSilenceSamples / LogMelExtractor.hopLength,
                                     alternatives: alternatives, progress: progress)
        return Result(audioSeconds: audio.seconds,
                      leadingSilenceSeconds: Double(leadingSilenceSamples) / AudioDecoder.sampleRate,
                      decodeSeconds: Double(t1 - t0) / 1e9,
                      logMelSeconds: Double(t2 - t1) / 1e9, logMel: breakdown, frames: frames, run: run)
    }

    // MARK: - The windows

    /// The host's share of the windows, seconds: building each window's inputs (log-mel rows, masks), handing values
    /// to the stages (dtype conversion and copies), reading the labels, and the final collapse into words.
    /// eg2zh (Mandarin, LM): `lm`, reading each window's candidates for the LM decoder (0 when greedy).
    struct HostTiming: Sendable {
        var inputs = 0.0
        var feed = 0.0
        var labels = 0.0
        var collapse = 0.0
        var lm = 0.0

        var total: Double { inputs + feed + labels + collapse + lm }
    }

    /// eg2zh (Mandarin, LM): how a run was decoded. The greedy read-out is always computed and kept here; `Run.words`
    /// and `Run.text` are the LM decoder's in LM mode and the greedy ones otherwise.
    struct DecodeRun: Sendable {
        let mode: DecodeMode
        let requested: DecodeMode
        /// Why the run decoded greedily although LM decoding was requested.
        let fallbackReason: String?
        let greedyWords: [Int]
        let greedyText: String
        let lm: LMDecodeResult?
        /// The LM decoder's CPU milliseconds on its own thread (feeding every window, then finishing).
        let cpuMs: Double
        /// Wall milliseconds from the end of the windows to the LM result (the decoder's share of the wall clock).
        let tailMs: Double
        let params: LMDecodeConfig?
    }

    struct Run: Sendable {
        let windows: Int
        let tokens: Int
        let overlap: Bool
        /// One label per token of the recording (blank = the vocabulary size).
        let labels: [Int]
        /// Per token: the reader's top-1 word logit and blank logit (what each label was decided from).
        let topLogits: [Float]
        let blankLogits: [Float]
        let words: [Int]
        let text: String
        let wallSeconds: Double
        /// Per stage, per window: the call's wall milliseconds.
        let stageMilliseconds: [[Double]]
        let host: HostTiming
        /// Outputs kept for inspection (`capture`), per window.
        let captured: [[String: NDArray]]
        /// eg2zh (Mandarin, LM): greedy or LM, and the LM decoder's result and cost.
        let decode: DecodeRun
        /// eg2zh (Mandarin, cloud): the reader's candidates per kept non-blank token (`run(alternatives: true)` with
        /// the LM-version outputs), else nil; `alternativesNote` says why they are missing when they were asked for.
        var alternatives: TokenAlternatives? = nil
        var alternativesNote: String? = nil
    }

    /// Runs the windows of `frames` log-mel rows ([frames × 128] row-major) through the stages.
    /// eg2zh (Mandarin, LM): `decode` nil = the loaded setup's mode; `.lm` when LM decoding is not set up decodes
    /// greedily (the reason is in `Run.decode`).
    func run(features: [Float], frames: Int, overlap: Bool, capture: Set<String> = [], decode: DecodeMode? = nil,
             leadingSilenceFrames: Int = 0,
             alternatives: Bool = false,
             progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Run {
        let plan = Windowing.planWithPrelude(frames: frames, leadingSilenceFrames: leadingSilenceFrames,
                                            contract: contract)
        let total = Windowing.totalTokens(plan)
        var labels = [Int](repeating: -1, count: total)
        var tops = [Float](repeating: .nan, count: total)
        var blanks = [Float](repeating: .nan, count: total)
        var milliseconds = [[Double]](repeating: [Double](repeating: .nan, count: plan.count), count: stages.count)
        var captured = [[String: NDArray]](repeating: [:], count: capture.isEmpty ? 0 : plan.count)
        var host = HostTiming()
        let last = stages.count - 1
        let start = DispatchTime.now().uptimeNanoseconds
        func seconds(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9 }
        // eg2zh (Mandarin, LM): the LM decoder on its own task, fed each window's kept tokens in plan order. If a
        // window's LM outputs cannot be read, the decoder is dropped and the run decodes greedily (the reason goes
        // into Run.decode); on an error of the run the decoder is cancelled.
        let requested = decode ?? decodeSetup.requested
        let lmConfig = (decode ?? decodeSetup.active) == .lm && decodeSetup.active == .lm ? decodeSetup.config : nil
        var lmDecoding = lmConfig.map { LMDecodingTask(lm: decodeSetup.lm, config: $0) }
        var lmStopped: String?
        defer { lmDecoding?.cancel() }
        var lmNextWindow = 0
        // eg2zh (Mandarin, cloud): the reader's candidates, only when asked for (cloud correction enabled); a window
        // whose candidates cannot be read drops them for the run (never an error of the run)
        var alts: TokenAlternatives? = alternatives ? TokenAlternatives() : nil
        var altsNote: String? = alternatives ? nil : "not requested"

        func finish(_ values: [String: StageValue], _ window: Window) throws {
            let t = DispatchTime.now().uptimeNanoseconds
            try readLabels(values, window, labels: &labels, tops: &tops, blanks: &blanks)
            host.labels += seconds(since: t)
            if alts != nil {
                do {
                    try collectAlternatives(values, window, labels: labels, into: &alts!)
                } catch {
                    alts = nil
                    altsNote = "reader alternatives dropped at window \(window.index): \(error.localizedDescription)"
                }
            }
            if let decoding = lmDecoding {
                let t = DispatchTime.now().uptimeNanoseconds
                do {
                    guard window.index == lmNextWindow else {
                        throw TranscribeError.contract("window \(window.index) finished before window \(lmNextWindow)")
                    }
                    lmNextWindow += 1
                    decoding.yield(try lmFrames(values, window))
                } catch {
                    decoding.cancel()
                    lmDecoding = nil
                    lmStopped = "LM decoding stopped at window \(window.index): \(error.localizedDescription)"
                }
                host.lm += seconds(since: t)
            }
            if !capture.isEmpty {
                for name in capture { if case .tensor(let a) = values[name] { captured[window.index][name] = a } }
            }
            progress(window.index + 1, plan.count)
        }

        if !overlap || stages.count == 1 {
            for window in plan {
                var t = DispatchTime.now().uptimeNanoseconds
                var values = hostValues(window, features: features)
                host.inputs += seconds(since: t)
                for (k, stage) in stages.enumerated() {
                    t = DispatchTime.now().uptimeNanoseconds
                    let feed = try stage.feed(values)
                    host.feed += seconds(since: t)
                    let (outputs, ms) = try await stage.run(feed)
                    milliseconds[k][window.index] = ms
                    for (name, array) in outputs { values[name] = .tensor(array) }
                }
                try finish(values, window)
            }
        } else {
            // Wavefront: at step t, stage k works on window t − k; every stage of a step runs at once.
            var pending: [Int: [String: StageValue]] = [:]
            for step in 0..<(plan.count + last) {
                var t = DispatchTime.now().uptimeNanoseconds
                if step < plan.count { pending[step] = hostValues(plan[step], features: features) }
                host.inputs += seconds(since: t)
                t = DispatchTime.now().uptimeNanoseconds
                var jobs: [(stage: Int, window: Int, feed: [String: NDArray])] = []
                for k in 0...last {
                    let n = step - k
                    if n >= 0, n < plan.count, let values = pending[n] {
                        jobs.append((k, n, try stages[k].feed(values)))
                    }
                }
                host.feed += seconds(since: t)
                let stages = self.stages
                let results = try await withThrowingTaskGroup(
                    of: (stage: Int, window: Int, outputs: [String: NDArray], ms: Double).self
                ) { group in
                    for job in jobs {
                        let stage = stages[job.stage]
                        group.addTask {
                            let (outputs, ms) = try await stage.run(job.feed)
                            return (job.stage, job.window, outputs, ms)
                        }
                    }
                    var done: [(stage: Int, window: Int, outputs: [String: NDArray], ms: Double)] = []
                    for try await result in group { done.append(result) }
                    return done
                }
                for result in results.sorted(by: { $0.stage > $1.stage }) {
                    milliseconds[result.stage][result.window] = result.ms
                    guard var values = pending[result.window] else { continue }
                    for (name, array) in result.outputs { values[name] = .tensor(array) }
                    if result.stage == last {
                        try finish(values, plan[result.window])
                        pending[result.window] = nil
                    } else {
                        pending[result.window] = values
                    }
                }
            }
        }
        guard !labels.contains(-1) else {
            throw TranscribeError.contract("the windows left \(labels.filter { $0 < 0 }.count) tokens without a label")
        }
        let t = DispatchTime.now().uptimeNanoseconds
        let words = Greedy.collapse(labels, blank: blankID)
        let text = words.map { vocabulary[$0] }.joined(separator: join)
        host.collapse = seconds(since: t)
        // eg2zh (Mandarin, LM): the decoder's remaining frames, then its result
        var lm: (result: LMDecodeResult, cpuMs: Double)?
        var tailMs = 0.0
        if let decoding = lmDecoding {
            let t = DispatchTime.now().uptimeNanoseconds
            lm = await decoding.finish()
            tailMs = seconds(since: t) * 1000
        }
        let lmWords = lm?.result.ids
        let lmText = lmWords.map { $0.map { vocabulary[$0] }.joined(separator: join) }
        let fallback = requested == .lm && lm == nil
            ? (lmStopped ?? decodeSetup.fallbackReason ?? "LM decoding was not set up when the model was loaded") : nil
        let decodeRun = DecodeRun(mode: lm == nil ? .greedy : .lm, requested: requested, fallbackReason: fallback,
                                  greedyWords: words, greedyText: text, lm: lm?.result, cpuMs: lm?.cpuMs ?? 0,
                                  tailMs: tailMs, params: lm == nil ? nil : decodeSetup.config)
        let wall = seconds(since: start)
        return Run(windows: plan.count, tokens: total, overlap: overlap && stages.count > 1, labels: labels,
                   topLogits: tops, blankLogits: blanks, words: lmWords ?? words, text: lmText ?? text, wallSeconds: wall,
                   stageMilliseconds: milliseconds, host: host, captured: captured, decode: decodeRun,
                   alternatives: alts, alternativesNote: altsNote)
    }

    /// eg2zh (Mandarin, cloud): one window's reader candidates (topk_index [1, T, K] int32, topk_logp [1, T, K],
    /// blank_logp [1, T], K ≥ 8) for its kept non-blank tokens: the first 8 candidates, ids in the vocabulary, values
    /// not NaN or +inf (CLOUD_FIX_SPEC_v2 3.1).
    private func collectAlternatives(_ values: [String: StageValue], _ window: Window, labels: [Int],
                                     into store: inout TokenAlternatives) throws {
        guard case .tensor(let index) = values["topk_index"], case .tensor(let logp) = values["topk_logp"],
              case .tensor(let blank) = values["blank_logp"] else {
            throw TranscribeError.contract("this model folder has no recognizer alternatives (topk outputs)")
        }
        let ids = try Tensor.int32s(index)
        let logps = try Tensor.floats(logp)
        let blanks = try Tensor.floats(blank)
        let tokens = contract.tokens
        guard tokens > 0, blanks.count == tokens, ids.count == logps.count, ids.count % tokens == 0,
              ids.count / tokens >= TokenAlternatives.k else {
            throw TranscribeError.contract("alternatives of \(ids.count) / \(logps.count) / \(blanks.count) values")
        }
        let k = ids.count / tokens
        let n = TokenAlternatives.k
        for p in window.keep where labels[window.token0 + p] != blankID {
            let row = p * k
            guard !blanks[p].isNaN, blanks[p] != .infinity,
                  ids[row..<(row + n)].allSatisfy({ $0 >= 0 && Int($0) < blankID }),
                  logps[row..<(row + n)].allSatisfy({ !$0.isNaN && $0 != .infinity }) else {
                throw TranscribeError.contract("invalid alternatives at token \(window.token0 + p)")
            }
            store.append(token: window.token0 + p, ids: ids[row..<(row + n)], logps: logps[row..<(row + n)],
                         blank: blanks[p])
        }
    }

    /// eg2zh (Mandarin, cloud): the greedy characters of a run with their tokens and, when collected, the reader's
    /// alternatives (after the run, not in the timed path).
    func greedyCharacters(labels: [Int], alternatives: TokenAlternatives?) -> [GreedyChar] {
        CharAlternatives.perCharacter(labels: labels, blank: blankID, vocabulary: vocabulary, store: alternatives)
    }

    /// eg2zh (Mandarin, cloud): cloud correction works on the Mandarin reader's single characters.
    var cloudCapable: Bool { CharAlternatives.vocabularyIsCharacters(vocabulary) }

    /// eg2zh (Mandarin, LM): one window's frames for the LM decoder: its kept tokens' top-K candidates and blank
    /// log-posterior (topk_index [1, T, K] int32, topk_logp [1, T, K], blank_logp [1, T]); ids must be characters and
    /// values must not be NaN or +inf.
    private func lmFrames(_ values: [String: StageValue], _ window: Window) throws -> LMFrames {
        guard case .tensor(let index) = values["topk_index"], case .tensor(let logp) = values["topk_logp"],
              case .tensor(let blank) = values["blank_logp"] else {
            throw TranscribeError.contract("the last stage gave no topk_index / topk_logp / blank_logp")
        }
        let k = decodeSetup.k
        let ids = try Tensor.int32s(index)
        let logps = try Tensor.floats(logp)
        let blanks = try Tensor.floats(blank)
        guard k > 0, ids.count == contract.tokens * k, logps.count == ids.count, blanks.count == contract.tokens else {
            throw TranscribeError.contract("LM outputs of \(ids.count) / \(logps.count) / \(blanks.count) values, K \(k)")
        }
        for p in window.keep {
            guard !blanks[p].isNaN, blanks[p] != .infinity else {
                throw TranscribeError.contract("blank_logp \(blanks[p]) at token \(window.token0 + p)")
            }
            for j in (p * k)..<(p * k + k) {
                guard ids[j] >= 0, Int(ids[j]) < blankID else {
                    throw TranscribeError.contract("topk_index \(ids[j]) outside the \(blankID)-character vocabulary")
                }
                guard !logps[j].isNaN, logps[j] != .infinity else {
                    throw TranscribeError.contract("topk_logp \(logps[j]) at token \(window.token0 + p)")
                }
            }
        }
        return LMFrames.kept(window: window, topkIndex: ids, topkLogp: logps, blankLogp: blanks, k: k)
    }

    /// The host's inputs of one window: its log-mel rows (zero-padded to the window), half_mask (1 on the
    /// ceil(frames / 2) rows the first convolution keeps), token_mask (1 on the valid tokens).
    private func hostValues(_ window: Window, features: [Float]) -> [String: StageValue] {
        let mels = LogMelExtractor.mels
        var x = [Float](repeating: 0, count: contract.frames * mels)
        let from = window.frame0 * mels
        let count = window.frames * mels
        x.withUnsafeMutableBufferPointer { dst in
            features.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + from, count: count)
            }
        }
        let halfRows = (contract.frames + 1) / 2
        var half = [Float](repeating: 0, count: halfRows)
        for i in 0..<((window.frames + 1) / 2) { half[i] = 1 }
        var tokens = [Float](repeating: 0, count: contract.tokens)
        for i in 0..<window.validTokens { tokens[i] = 1 }
        return ["features": .host(x, shape: [1, contract.frames, mels]),
                "half_mask": .host(half, shape: [1, halfRows]),
                "token_mask": .host(tokens, shape: [1, contract.tokens])]
    }

    private func readLabels(_ values: [String: StageValue], _ window: Window, labels: inout [Int], tops: inout [Float],
                            blanks: inout [Float]) throws {
        guard case .tensor(let index) = values["top1_index"], case .tensor(let top) = values["top1_logit"],
              case .tensor(let blank) = values["blank_logit"] else {
            throw TranscribeError.contract("the last stage gave no top1_index / top1_logit / blank_logit")
        }
        let indices = try Tensor.int32s(index)
        let topValues = try Tensor.floats(top)
        let blankValues = try Tensor.floats(blank)
        for p in window.keep {
            guard indices[p] >= 0, Int(indices[p]) < blankID else {
                throw TranscribeError.contract("top1_index \(indices[p]) outside the \(blankID)-word vocabulary")
            }
            let token = window.token0 + p
            labels[token] = Greedy.label(index: indices[p], top: topValues[p], blank: blankValues[p], blankID: blankID)
            tops[token] = topValues[p]
            blanks[token] = blankValues[p]
        }
    }
}
