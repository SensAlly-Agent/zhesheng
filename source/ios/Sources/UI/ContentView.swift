// 折声 (zhesheng): changed from eg2-transcribe at e6b7d5d (Apache-2.0). See NOTICE.
import SwiftUI
import UniformTypeIdentifiers

/// One screen: the scope with Choose audio / Record under it, the transcript, then the run's numbers and the
/// proofreading handoff (side by side on a wide window, stacked on a narrow one).
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var choreo = Choreo()
    @Namespace private var namespace
    @State private var booting = true
    @State private var wide = true
    @State private var dropTargeted = false
    @State private var importing = false
    @State private var importKind = UTType.audio
    @State private var showingSettings = false
    @State private var importError: String?
    @State private var confirmingRecording = false
    /// The transcript editor has the keyboard: the R key types an R then, it does not record.
    @FocusState private var editorFocused: Bool
    /// 贴回结果 refused (nothing usable on the clipboard), and a replacement of edited text waiting for a yes.
    @State private var pasteProblem: PasteBack.Check?
    @State private var pendingReplace: PendingReplace?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum PendingReplace: Equatable {
        case proofread(String)
        case restore
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    content(proxy)
                        .padding(16)
                        .frame(maxWidth: 1180)
                        .frame(maxWidth: .infinity)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let site = choreo.handoffCard {
                        HandoffCard(site: site, characters: model.transcript.count) { choreo.hideHandoffCard() }
                            .padding(16)
                            .transition(.asymmetric(insertion: .offset(y: 40).combined(with: .scale(scale: 0.9)).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .offset(y: 16))))
                    }
                }
            }
            .overlay {
                if let request = choreo.confirm {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                            .onTapGesture { choreo.answer(open: false) }
                            .transition(.opacity)
                        HandoffConfirmCard(request: request) { choreo.answer(open: $0) }
                            .transition(.scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: 24)))
                    }
                }
            }
            .background(Palette.well.opacity(0.35))
            .navigationTitle("折声")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSettings = true } label: { Label("设置", systemImage: "gearshape") }
                        .disabled(model.forms.isEmpty || model.isBusy || model.isRecording)
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [importKind]) { result in
                switch result {
                case .success(let url):
                    if importKind == .folder {
                        Task { await model.open(url, chosen: true) }
                    } else {
                        Task { await model.transcribe(url) }
                    }
                case .failure(let error):
                    let cocoaError = error as NSError
                    if cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError {
                        importError = error.localizedDescription
                    }
                }
            }
            .alert("无法打开文件", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .dropDestination(for: URL.self) { urls, _ in
                dropTargeted = false
                guard model.canTranscribe, let url = urls.first(where: Self.isAudio) else { return false }
                Task { await model.transcribe(url) }
                return true
            } isTargeted: { targeted in
                dropTargeted = targeted && model.canTranscribe
            }
        }
        .onChange(of: isBooting, initial: true) { _, now in
            withAnimation(reduceMotion ? nil : Motion.snap) { booting = now }
        }
        // A new text, not an edit: a recognition gets the full arrival, a pasted answer or a restore only the notice.
        .onChange(of: model.textGeneration) { _, _ in
            switch model.arrival {
            case .cleared: choreo.transcriptCleared()
            case .recognized: choreo.transcriptArrived(reduceMotion: reduceMotion)
            case .proofread, .restored: choreo.textReplaced()
            }
        }
    }

    private func content(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            statusPill
            if wide {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { capture; transcript(proxy) }
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 16) { StatsView(stats: model.stats, busy: model.isBusy); proof }
                        .frame(width: 360)
                }
            } else {
                VStack(spacing: 16) { capture; transcript(proxy); proof; StatsView(stats: model.stats, busy: model.isBusy) }
            }
            if let line = model.selfTestLine {
                Text(line).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .coordinateSpace(.named("root"))
        .overlay { GuideLine(choreo: choreo) }
        .overlay { FlightOverlay(choreo: choreo) }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 820 } action: { wide = $0 }
    }

    // MARK: - Status

    private var isBooting: Bool {
        switch model.phase {
        case .starting: true
        case .loading(let message): message != "正在请求麦克风权限…"
        default: false
        }
    }

    private var statusPill: some View {
        HStack(spacing: 9) {
            Group {
                if booting {
                    ANEGrid(lit: 0, glow: false)
                } else {
                    ANEGrid(lit: 16, color: pillColor, glow: false)
                        .matchedGeometryEffect(id: "ane", in: namespace)
                        .phaseAnimator([1.0, 0.35], trigger: model.isBusy) { grid, opacity in
                            grid.opacity(model.isBusy ? opacity : 1)
                        } animation: { _ in .easeInOut(duration: 0.45) }
                }
            }
            .frame(width: 14, height: 14)
            Text(statusText)
                .lineLimit(1).truncationMode(.middle)
                .contentTransition(.interpolate)
                .animation(Motion.snap, value: statusText)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 9).padding(.trailing, 12).frame(height: 28)
        .background(Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line))
        .accessibilityElement(children: .combine)
    }

    private var pillColor: Color {
        switch model.phase {
        case .recording: Palette.rec
        case .transcribing, .loading, .downloading: Palette.ember
        case .failed: Palette.rec
        default: Palette.ok
        }
    }

    private var statusText: String {
        switch model.phase {
        case .starting: "正在查找模型…"
        case .noModel: "尚未选择模型"
        case .downloading(let fraction): String(format: "正在下载模型 · %.0f%%", fraction * 100)
        case .loading(let message): message == "正在请求麦克风权限…" ? message : "正在加载模型，首次使用可能需要稍等…"
        case .recording: "正在录音"
        case .transcribing(let done, let total): total > 0 ? "正在转写：\(done) / \(total) 段" : "正在读取音频…"
        case .ready: "模型已就绪 · \(model.form?.title ?? "") · 并行处理\(model.overlap ? "开启" : "关闭")"
        case .failed: "操作未完成"
        }
    }

    // MARK: - Capture

    private var capture: some View {
        VStack(spacing: 0) {
            ScopeView(model: model, booting: booting, dropTargeted: dropTargeted, namespace: namespace) { choose(.folder) }
            HStack(alignment: .bottom) {
                Button { choose(.audio) } label: {
                    Label("选择音频", systemImage: "waveform").frame(minHeight: 28)
                }
                .buttonStyle(LiftButtonStyle())
                .disabled(!model.canTranscribe)
                .frame(maxWidth: .infinity, alignment: .leading)
                RecordButton(recording: model.isRecording, enabled: model.canTranscribe || model.isRecording,
                             shortcutEnabled: !editorFocused) {
                    if model.asksBeforeRecording {
                        confirmingRecording = true
                    } else {
                        Task { await model.toggleRecording() }
                    }
                }
                Text("R 录音 · 可把音频拖进窗口")
                    .font(Typeface.mono(11)).foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 6)
            .padding(.top, -38)
        }
        // A recording replaces the transcript on the screen: the user confirms, then it is cleared and recording starts.
        .alert("开始新的录音？", isPresented: $confirmingRecording) {
            Button("清除并开始录音", role: .destructive) {
                Task { await model.toggleRecording(clearing: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.transcript.isEmpty
                 ? "当前的音频和识别结果会被清除。"
                 : "当前的音频和转写结果会被清除，清除后无法恢复。如需保留，请先取消，再点“保存文本…”。")
        }
    }

    private func transcript(_ proxy: ScrollViewProxy) -> some View {
        TranscriptView(text: $model.transcript, generation: model.textGeneration, hasText: model.hasText,
                       isProofread: model.isProofread, isEdited: model.isEdited,
                       file: model.hasText ? model.stats?.file : nil, size: model.textSize, choreo: choreo,
                       editorFocus: $editorFocused,
                       goProofread: {
                           withAnimation(Motion.soft) { proxy.scrollTo("proof", anchor: .center) }
                           choreo.nudge += 1
                           choreo.example += 1
                       },
                       pasteBack: requestPasteBack,
                       restore: { pendingReplace = .restore })
        .alert(pasteProblemTitle, isPresented: Binding(
            get: { pasteProblem != nil }, set: { if !$0 { pasteProblem = nil } }
        )) {
            Button("好", role: .cancel) { pasteProblem = nil }
        } message: {
            Text(pasteProblemMessage)
        }
        .alert(pendingReplace == .restore ? "恢复原始识别稿？" : "替换你修改过的文稿？", isPresented: Binding(
            get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }
        )) {
            Button(pendingReplace == .restore ? "恢复" : "替换", role: .destructive) {
                switch pendingReplace {
                case .proofread(let text): model.applyProofread(text)
                case .restore: model.restoreRecognized()
                case nil: break
                }
                pendingReplace = nil
            }
            Button("取消", role: .cancel) { pendingReplace = nil }
        } message: {
            Text(pendingReplace == .restore
                 ? "现在的文稿会换回原始识别稿，AI 校对稿和你的修改都不会保留。需要的话，请先点“保存文本…”或“复制”。"
                 : "贴回的 AI 回答会替换现在的文稿，你手动修改的内容不会保留。需要的话，请先点“保存文本…”或“复制”。")
        }
    }

    private var proof: some View {
        WebProofreadingBar(model: model, choreo: choreo, pasteBack: requestPasteBack).id("proof")
    }

    /// 贴回结果: the AI website's answer from the clipboard replaces the text on the screen; refused with the reason
    /// when the clipboard has nothing usable, and asked first when the person has edited the text.
    private func requestPasteBack() {
        switch PasteBack.check(PasteBack.clipboardText(), current: model.transcript) {
        case .ready(let text):
            if model.isEdited { pendingReplace = .proofread(text) } else { model.applyProofread(text) }
        case let problem:
            pasteProblem = problem
        }
    }

    private var pasteProblemTitle: String {
        switch pasteProblem {
        case .stillPrompt: "还没有复制 AI 的回答"
        case .unchanged: "剪贴板里就是现在的文稿"
        default: "剪贴板里没有文字"
        }
    }

    private var pasteProblemMessage: String {
        switch pasteProblem {
        case .stillPrompt: "剪贴板里还是刚才复制给网站的内容。请在网站上复制 AI 的回答，再回来点“贴回结果”。"
        case .unchanged: "贴回的内容和现在的文稿一样，没有需要替换的。"
        default: "请先在 AI 网站上复制它的回答，再回来点“贴回结果”。"
        }
    }

    private func choose(_ kind: UTType) {
        importKind = kind
        importing = true
    }

    private static func isAudio(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .audio)) ?? false
    }
}

/// The round record key: a circle that becomes a rounded square while recording, drawn a little toward the pointer.
struct RecordButton: View {
    let recording: Bool
    let enabled: Bool
    /// The R key; off while a text field has the keyboard, so typing an R does not record.
    var shortcutEnabled = true
    let action: () -> Void
    @State private var pull = CGSize.zero
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle().fill(Palette.raised)
                    Circle().strokeBorder(recording ? Palette.rec.opacity(0.55) : Color.primary.opacity(0.85), lineWidth: 2)
                        .padding(5)
                        .scaleEffect(hovering && !recording ? 1.06 : 1)
                    RoundedRectangle(cornerRadius: recording ? 6 : 26, style: .continuous)
                        .fill(Palette.rec)
                        .frame(width: recording ? 26 : 52, height: recording ? 26 : 52)
                        .scaleEffect(hovering && !recording ? 0.9 : 1)
                }
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .keyboardShortcut(shortcutEnabled ? KeyboardShortcut("r", modifiers: []) : nil)
            .accessibilityLabel(recording ? "停止录音" : "开始录音")
            .offset(pull)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where enabled:
                    hovering = true
                    pull = CGSize(width: (point.x - 38) * 0.18, height: (point.y - 38) * 0.18)
                default:
                    hovering = false
                    pull = .zero
                }
            }
            Text(recording ? "停止录音" : "开始录音")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .contentTransition(.interpolate)
        }
        .animation(Motion.bounce, value: recording)
        .animation(Motion.bounce, value: hovering)
        .animation(Motion.snap, value: pull)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Motion.bounce, value: configuration.isPressed)
    }
}

/// A quiet bordered button that lifts on hover.
struct LiftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering && isEnabled ? Palette.ember : Palette.line, lineWidth: 1))
            .offset(y: hovering && isEnabled ? -2 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(Motion.bounce, value: hovering)
            .animation(Motion.bounce, value: configuration.isPressed)
    }
}

/// After a handoff: what to do in the browser, in the window's corner for a few seconds.
struct HandoffCard: View {
    let site: LLMWebsite
    let characters: Int
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 8, height: 8) }
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text(site.url.host() ?? site.title).font(Typeface.mono(11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 5))
                .padding(.leading, 6)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Palette.card)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    KeyCap(label: "⌘", delay: 0.7)
                    KeyCap(label: "V", delay: 0.8)
                    Text("粘贴，然后发送").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.ember, lineWidth: 1.5))
                Text("共 \(characters) 字 + 校对要求").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已复制，到 \(site.title) 按 Command V 粘贴，然后发送")
    }
}

private struct KeyCap: View {
    let label: String
    let delay: Double
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(Typeface.mono(12, weight: .semibold))
            .frame(minWidth: 24, minHeight: 24)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(pressed ? Palette.ember : Palette.line))
            .offset(y: pressed ? 2 : 0)
            .task {
                try? await Task.sleep(for: .seconds(delay))
                for _ in 0..<2 {
                    withAnimation(.easeInOut(duration: 0.2)) { pressed = true }
                    try? await Task.sleep(for: .milliseconds(220))
                    withAnimation(.easeInOut(duration: 0.2)) { pressed = false }
                    try? await Task.sleep(for: .milliseconds(260))
                }
            }
    }
}
