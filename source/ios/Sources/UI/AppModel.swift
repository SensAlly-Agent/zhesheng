// 折声 (zhesheng): changed from eg2-transcribe at e6b7d5d (Apache-2.0). See NOTICE.
import Foundation
import Observation

/// What one transcription took, for the stats line.
struct RunStats: Sendable, Equatable {
    let file: String
    let audioSeconds: Double
    let totalSeconds: Double
    let decodeSeconds: Double
    let logMelSeconds: Double
    let windowSeconds: Double
    /// Per stage: name and the sum of its calls' seconds.
    let stageSeconds: [String]
    let stageSums: [Double]
    /// The host's share of the windows: inputs, conversions, labels, collapse.
    let hostSeconds: Double
    let windows: Int
    let form: String
    let overlap: Bool
    /// eg2zh (Mandarin, LM): the CTC decoding of the transcript ("lm" or "greedy") and the LM decoder's CPU
    /// milliseconds (0 when greedy).
    let decodeMode: String
    let decodeMilliseconds: Double

    var realtimeFactor: Double { audioSeconds / totalSeconds }
}

/// The app's state: the model folder, the loaded pipeline, the last transcript and its numbers.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case noModel(String)
        case downloading(Double)
        case loading(String)
        case ready
        case recording
        case transcribing(window: Int, of: Int)
        case failed(String)
    }

    var phase: Phase = .starting
    private(set) var folder: ModelFolder?
    var forms: [PipelineForm] = []
    var formID = ""
    var overlap = true
    /// The text on the screen: what the transcript view shows and the person edits, what Copy and Save write and the
    /// proofreading handoff sends. A recognition sets it, and so does 贴回结果 (the AI website's answer).
    var transcript = ""
    /// The last recognition's own text, kept so the screen can go back to it (恢复原始稿).
    private(set) var recognized = ""
    /// How the text on the screen last came in; the text as it came in (an edit makes `transcript` differ from it);
    /// and a count bumped on every arrival but not on edits, which the screen's arrival effects follow.
    private(set) var arrival = TextArrival.cleared
    private(set) var arrivedText = ""
    private(set) var textGeneration = 0
    var stats: RunStats?
    var selfTestLine: String?
    /// UI: the loader's messages so far (the boot log), when the recording started (the timer), and a coarse
    /// spectrogram of the last audio (drawn behind the transcription progress; read apart from the transcription).
    private(set) var loadLog: [String] = []
    private(set) var recordingStartedAt: Date?
    private(set) var spectrogram: Spectrogram?
    /// eg2zh (Mandarin, LM): the loaded pipeline's decoding (LM or greedy, and why), for the settings screen.
    private(set) var decodeSummary: String?
    /// The transcript's text size in points (0 = the platform's body size), kept in the user defaults
    /// (`-textSize 44` as a launch argument sets it for one run).
    var textSize = UserDefaults.standard.double(forKey: "textSize") {
        didSet { UserDefaults.standard.set(textSize, forKey: "textSize") }
    }

    private var transcriber: Transcriber?
    private var loadGeneration = 0
    private var activeLoad: Int?
    private var transcriptionGeneration = 0
    private let recorder = AudioRecorder()

    var canTranscribe: Bool {
        if case .ready = phase { return transcriber != nil }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .loading, .downloading, .transcribing: true
        default: false
        }
    }

    var form: PipelineForm? { forms.first { $0.id == formID } }

    // MARK: - Model folder

    /// Opens the first model folder found (a `-models <dir>` launch argument, the folder chosen with 选择模型文件夹…,
    /// the app's own model, Documents/models/eg2-transcribe-zh) and loads the default form.
    func start() async {
        await open(ModelStore.launchFolder())
    }

    /// Opens a model folder and loads its default form. `chosen`: the user picked the folder with 选择模型文件夹…, so it
    /// is remembered and opens first at the next launches; a folder the app found by itself is not remembered.
    func open(_ root: URL?, chosen: Bool = false) async {
        guard !isBusy, !isRecording else { return }
        guard let root else {
            phase = .noModel(ModelFiles.isPublished
                ? "Download the model, or copy the model folder to \(ModelStore.localFolder.path)."
                : "Copy the model folder to \(ModelStore.localFolder.path).")
            return
        }
        do {
            let folder = try ModelFolder(root: root)
            self.folder = folder
            forms = folder.availableForms
            guard let form = folder.defaultForm else {
                phase = .failed("No form of pipeline.json can run on this device with the bundles in \(root.lastPathComponent).")
                return
            }
            formID = form.id
            overlap = folder.defaultOverlap
            if chosen { ModelStore.rememberChosen(root) }
            await load()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Loads (or reloads, after a settings change) the selected form's stages.
    func load() async {
        guard let folder, let form else { return }
        loadGeneration += 1
        let generation = loadGeneration
        activeLoad = generation
        transcriber = nil
        decodeSummary = nil
        phase = .loading("正在加载 \(form.title)")
        loadLog = ["正在加载 \(form.title)"]
        do {
            // eg2zh (Mandarin, LM): `-decode greedy|lm` (launch argument, user defaults) overrides lm_decode.mode
            let decode = UserDefaults.standard.string(forKey: "decode").flatMap(DecodeMode.init(rawValue:))
            let loaded = try await Transcriber.load(folder: folder, form: form, decode: decode) { message in
                Task { @MainActor in
                    guard self.activeLoad == generation else { return }
                    self.phase = .loading(message)
                    self.loadLog.append(message)
                }
            }
            guard activeLoad == generation else { return }
            activeLoad = nil
            transcriber = loaded
            decodeSummary = loaded.decodeSetup.summary
            phase = .ready
        } catch {
            guard activeLoad == generation else { return }
            activeLoad = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func selectForm(_ id: String) async {
        guard !isBusy, !isRecording, id != formID, forms.contains(where: { $0.id == id }) else { return }
        formID = id
        await load()
    }

    func download() async {
        phase = .downloading(0)
        do {
            let root = try await ModelStore.download { fraction in
                Task { @MainActor in self.phase = .downloading(fraction) }
            }
            await open(root)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transcribing

    /// Transcribes one audio file with the loaded form; returns the result (nil after an error, shown on screen).
    @discardableResult
    func transcribe(_ url: URL) async -> Transcriber.Result? {
        guard canTranscribe, let transcriber else { return nil }
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        phase = .transcribing(window: 0, of: 0)
        showRecognized("")
        stats = nil
        spectrogram = await Task.detached(priority: .userInitiated) { Spectrogram.make(url) }.value
        do {
            let result = try await transcriber.transcribe(url, overlap: overlap, alternatives: false) { done, total in
                Task { @MainActor in
                    guard self.transcriptionGeneration == generation,
                          case .transcribing = self.phase else { return }
                    self.phase = .transcribing(window: done, of: total)
                }
            }
            showRecognized(result.text)
            let names = transcriber.stages.map(\.spec.name)
            let sums = result.run.stageMilliseconds.map { $0.filter(\.isFinite).reduce(0, +) / 1000 }
            stats = RunStats(file: url.lastPathComponent, audioSeconds: result.audioSeconds, totalSeconds: result.totalSeconds,
                             decodeSeconds: result.decodeSeconds, logMelSeconds: result.logMelSeconds,
                             windowSeconds: result.run.wallSeconds, stageSeconds: names, stageSums: sums,
                             hostSeconds: result.run.host.total, windows: result.run.windows,
                             form: transcriber.form.title, overlap: result.run.overlap,
                             decodeMode: result.run.decode.mode.rawValue, decodeMilliseconds: result.run.decode.cpuMs)
            phase = .ready
            return result
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    var isRecording: Bool { phase == .recording }

    /// The screen holds the last audio's transcript or its numbers (a silent recording leaves numbers, no text).
    var hasContent: Bool { !transcript.isEmpty || stats != nil }

    /// A new recording would replace what the screen holds, so the app asks first; stopping never asks.
    var asksBeforeRecording: Bool { !isRecording && hasContent }

    /// Clears the transcript, its numbers and the spectrogram, as a new transcription does when it starts.
    func clearContent() {
        showRecognized("")
        stats = nil
        spectrogram = nil
    }

    // MARK: - The text on the screen

    enum TextArrival: Equatable {
        /// Nothing on the screen (a transcription starting, or the content cleared).
        case cleared
        /// A new recognition.
        case recognized
        /// The proofread answer, pasted back.
        case proofread
        /// The recognition again, after 恢复原始稿.
        case restored
    }

    var isProofread: Bool { arrival == .proofread }

    /// The person changed the text since it came in.
    var isEdited: Bool { transcript != arrivedText }

    /// The screen holds a text to show and edit (also when the person deleted all of it).
    var hasText: Bool { !recognized.isEmpty || isProofread }

    /// A new recognition's text ("" when a transcription starts or the content is cleared): the screen starts over.
    func showRecognized(_ text: String) {
        recognized = text
        setText(text, arrival: text.isEmpty ? .cleared : .recognized)
    }

    /// 贴回结果: the proofread answer replaces the text on the screen; the recognition stays for 恢复原始稿.
    func applyProofread(_ text: String) {
        setText(text, arrival: .proofread)
    }

    /// 恢复原始稿: the recognition replaces the text on the screen (the answer and any edits).
    func restoreRecognized() {
        setText(recognized, arrival: .restored)
    }

    private func setText(_ text: String, arrival: TextArrival) {
        transcript = text
        arrivedText = text
        self.arrival = arrival
        textGeneration += 1
    }

    /// UI: the microphone level for the scope's waves, 0…1.
    func inputLevel() -> Float { recorder.level() }

    /// Starts a recording, or stops it and transcribes it. `clearing` (the user confirmed it, see
    /// `asksBeforeRecording`) clears the screen's content first, once the microphone is allowed: a refused
    /// microphone leaves the content as it was.
    func toggleRecording(clearing: Bool = false) async {
        if isRecording {
            phase = .ready
            recordingStartedAt = nil
            if let url = recorder.stop() { await transcribe(url) }
            return
        }
        guard canTranscribe else { return }
        phase = .loading("正在请求麦克风权限…")
        guard await recorder.permission() else {
            phase = .failed("麦克风权限未开启，请在系统设置中允许此 App 录音。")
            return
        }
        if clearing { clearContent() }
        do {
            try recorder.start()
            spectrogram = nil
            recordingStartedAt = Date()
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Back to ready after an error, when a pipeline is loaded.
    func dismissError() {
        if transcriber != nil { phase = .ready }
    }
}
