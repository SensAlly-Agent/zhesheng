import SwiftUI

/// The instrument screen at the top: three breathing waves while idle (they ripple under the pointer and rise with
/// the voice while recording), then the spectrogram of the audio cut into the reader's 30-second windows while it is
/// transcribed. During model loading it shows the Neural Engine grid and the loader's log.
struct ScopeView: View {
    let model: AppModel
    let booting: Bool
    let dropTargeted: Bool
    let namespace: Namespace.ID
    var chooseFolder: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waves = WaveState()
    @State private var picture: CGImage?
    @State private var pictureStart: Date?
    @State private var revealStart = Date()

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 / 4 : nil)) { timeline in
                Canvas { context, size in
                    draw(&context, size: size, now: timeline.date)
                }
            }
            hud
            if booting { BootPanel(log: model.loadLog, namespace: namespace).transition(.opacity) }
            statusPanel
            if dropTargeted { DropTarget().transition(.scale(scale: 0.97).combined(with: .opacity)) }
        }
        .frame(height: 268)
        .background(Palette.scope)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .scaleEffect(dropTargeted ? 1.012 : 1)
        .animation(Motion.bounce, value: dropTargeted)
        .onContinuousHover { phase in
            if case .active(let point) = phase { waves.hover(point) } else { waves.hover(nil) }
        }
        .onChange(of: model.spectrogram) { _, new in
            picture = new?.image()
            pictureStart = new == nil ? nil : Date()
        }
        .onChange(of: booting) { _, now in if !now { revealStart = Date() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("音频示波器")
    }

    // MARK: - Canvas

    private var windows: (done: Int, total: Int)? {
        switch model.phase {
        case .transcribing(let done, let total) where total > 0: (done, total)
        case .ready where !model.transcript.isEmpty: model.stats.map { ($0.windows, $0.windows) }
        default: nil
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Date) {
        let level = model.isRecording ? Double(model.inputLevel()) : 0
        waves.step(now: now, level: level)
        grid(&context, size: size)

        let showPicture = picture != nil && (model.isBusy || !model.transcript.isEmpty) && !model.isRecording
        let wipe = showPicture ? progress(since: pictureStart, now: now, duration: 0.9) : 0
        let revealed = booting ? 0 : progress(since: revealStart, now: now, duration: 1.1)

        if !booting, wipe < 1 {
            var clipped = context
            clipped.clip(to: Path(CGRect(x: size.width * wipe, y: 0, width: size.width * (1 - wipe), height: size.height)))
            waves.draw(&clipped, size: size, reveal: revealed, reduceMotion: reduceMotion)
        }
        if showPicture, let picture {
            let x = size.width * wipe
            var shown = context
            shown.clip(to: Path(CGRect(x: 0, y: 0, width: x, height: size.height)))
            shown.draw(Image(decorative: picture, scale: 1).interpolation(.high).resizable(),
                       in: CGRect(origin: .zero, size: size))
            if wipe < 1 {
                var edge = context
                edge.addFilter(.shadow(color: Color(hex: 0xFF9A5A), radius: 9))
                edge.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Color(hex: 0xFFC48E)))
            }
            if let windows { drawWindows(&context, size: size, windows: windows, now: now) }
            if case .ready = model.phase {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.scope.opacity(0.32)))
            }
        }
    }

    private func progress(since start: Date?, now: Date, duration: Double) -> Double {
        guard let start, !reduceMotion else { return 1 }
        let p = max(0, min(1, now.timeIntervalSince(start) / duration))
        return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    private func grid(_ context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        for i in 1..<10 {
            let x = (size.width * CGFloat(i) / 10).rounded() + 0.5
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
        }
        path.move(to: CGPoint(x: 0, y: size.height / 2)); path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(path, with: .color(Palette.scopeText.opacity(0.06)), lineWidth: 1)
    }

    /// The reader's 30-second windows: dark until read, a beam across the one being read, an ember bar when done.
    private func drawWindows(_ context: inout GraphicsContext, size: CGSize, windows: (done: Int, total: Int), now: Date) {
        let width = size.width / CGFloat(windows.total)
        waves.noteDone(windows.done, now: now)
        for i in 0..<windows.total {
            let rect = CGRect(x: CGFloat(i) * width, y: 0, width: width, height: size.height)
            if i > windows.done {
                context.fill(Path(rect), with: .color(Color.black.opacity(0.5)))
            } else if i == windows.done, windows.done < windows.total {
                let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.7) / 0.7
                var beam = context
                beam.addFilter(.shadow(color: Color(hex: 0xFF965A), radius: 8))
                beam.fill(Path(CGRect(x: rect.minX + rect.width * t, y: 0, width: 2, height: size.height)),
                          with: .color(Color(hex: 0xFFC48E)))
            } else {
                let grow = reduceMotion ? 1 : min(1, now.timeIntervalSince(waves.doneAt[i] ?? .distantPast) / 0.35)
                context.fill(Path(CGRect(x: rect.minX, y: size.height - 3, width: rect.width * grow, height: 3)),
                             with: .linearGradient(Gradient(colors: [Color(hex: 0xE5506A), Color(hex: 0xFFA45F)]),
                                                   startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
            }
            if i > 0 {
                context.fill(Path(CGRect(x: rect.minX, y: 0, width: 1, height: size.height)), with: .color(Palette.scopeText.opacity(0.16)))
            }
            if width > 22 {
                context.draw(Text(String(format: "%02d", i + 1)).font(Typeface.mono(9.5, weight: .medium))
                                .foregroundStyle(i < windows.done ? Color(hex: 0xFFBE8C) : Palette.scopeText.opacity(0.42)),
                             at: CGPoint(x: rect.minX + 6, y: size.height - 14), anchor: .leading)
            }
        }
    }

    // MARK: - Overlays

    private var hud: some View {
        VStack {
            HStack(alignment: .firstTextBaseline) {
                Text(hudLabel)
                    .contentTransition(.interpolate)
                    .animation(Motion.snap, value: hudLabel)
                Spacer()
                if let start = model.recordingStartedAt {
                    TimelineView(.periodic(from: start, by: 0.5)) { timeline in
                        HStack(spacing: 7) {
                            Circle().fill(Palette.rec).frame(width: 7, height: 7).shadow(color: Palette.rec, radius: 5)
                            Text(StatsView.clock(timeline.date.timeIntervalSince(start)))
                                .contentTransition(.numericText())
                        }
                    }
                    .font(Typeface.mono(12, weight: .medium)).foregroundStyle(Palette.scopeText)
                } else if let seconds = model.spectrogram?.seconds, model.isBusy || !model.transcript.isEmpty {
                    Text(StatsView.clock(seconds)).font(Typeface.mono(12, weight: .medium)).foregroundStyle(Palette.scopeText)
                }
            }
            Spacer()
        }
        .font(Typeface.mono(10.5, weight: .medium))
        .foregroundStyle(Palette.scopeText.opacity(0.5))
        .padding(.horizontal, 14).padding(.top, 12)
        .allowsHitTesting(false)
    }

    private var hudLabel: String {
        switch model.phase {
        case .recording: "录音中 · 16 kHz 单声道"
        case .transcribing(_, let total) where total > 0: "转写中 · \(total) 个窗口 · 每窗 30 秒"
        case .transcribing: "正在读取音频"
        case .ready where !model.transcript.isEmpty: "完成 · \(model.stats?.windows ?? 0) 个窗口"
        case .ready: "待命 · 16 kHz 单声道"
        case .starting, .loading: "神经网络引擎"
        case .downloading: "正在下载模型"
        case .noModel, .failed: ""
        }
    }

    @ViewBuilder private var statusPanel: some View {
        switch model.phase {
        case .noModel:
            ScopeNotice(title: "尚未选择模型", message: "选择已下载的中文模型文件夹后即可开始转写。", systemImage: "folder.badge.questionmark") {
                if ModelFiles.isPublished {
                    Button("下载模型") { Task { await model.download() } }.buttonStyle(.borderedProminent)
                }
                #if os(macOS)
                Button("选择模型文件夹…", action: chooseFolder)
                #endif
            }
        case .downloading(let fraction):
            ScopeNotice(title: "正在下载模型…", message: String(format: "%.0f%%", fraction * 100), systemImage: "arrow.down.circle") {
                ProgressView(value: fraction).frame(width: 220)
            }
        case .failed(let message):
            ScopeNotice(title: "操作未完成", message: message, systemImage: "exclamationmark.triangle", tint: Palette.rec) {
                Button("好") { model.dismissError() }
                #if os(macOS)
                Button("选择模型文件夹…", action: chooseFolder)
                #endif
            }
        default:
            EmptyView()
        }
    }
}

/// The waves' state between frames: each line follows the voice at its own speed, the pointer leaves a ripple.
@MainActor
final class WaveState {
    private var levels: [Double] = [0, 0, 0]
    private var energy = 0.0
    private var pointer: CGPoint?
    private var last = Date()
    private var t = 0.0
    private(set) var doneAt: [Int: Date] = [:]
    private var doneCount = -1

    func hover(_ point: CGPoint?) {
        if let point, let old = pointer { energy = min(1, energy + hypot(point.x - old.x, point.y - old.y) / 120) }
        pointer = point
    }

    func step(now: Date, level: Double) {
        let dt = min(0.05, max(0, now.timeIntervalSince(last))); last = now; t += dt
        energy *= pow(0.2, dt)
        for (k, rate) in [18.0, 11.0, 6.0].enumerated() {
            levels[k] += (level - levels[k]) * min(1, dt * rate)
        }
    }

    func noteDone(_ done: Int, now: Date) {
        if done < doneCount { doneAt = [:] }
        if done > doneCount { for i in max(0, doneCount)..<done where doneAt[i] == nil { doneAt[i] = now } }
        doneCount = done
    }

    func draw(_ context: inout GraphicsContext, size: CGSize, reveal: Double, reduceMotion: Bool) {
        guard reveal > 0 else { return }
        let mid = size.height * 0.46, half = size.width / 2, span = half * reveal
        let layers: [(Double, Double, Double, Double, Double)] = [
            (0.82, 26, 0.010, 1.1, 0), (0.62, 18, 0.016, -1.6, 1.7), (0.42, 12, 0.024, 2.2, 3.1),
        ]
        let time = reduceMotion ? 0 : t
        let breath = 0.75 + 0.25 * sin(time * 1.4)
        let mx = pointer?.x ?? -1e9
        context.blendMode = .plusLighter
        for (k, layer) in layers.enumerated() {
            let (shade, a, frequency, speed, phase) = layer
            let b = levels[k]
            let amp1 = a * (breath * (1 - 0.45 * min(1, b)) + b * 3.4), amp2 = a * b * 1.5
            var path = Path()
            var x = half - span
            var first = true
            while x <= half + span {
                let u = x / size.width, taper = pow(sin(.pi * u), 1.5)
                let g = exp(-pow(x - mx, 2) / (2 * 70 * 70))
                let y = mid + taper * (amp1 * sin(x * frequency + time * speed + phase)
                                       + amp2 * sin(x * frequency * 3.3 - time * speed * 3.2 + phase * 2)
                                       + g * energy * 30 * sin(x * 0.07 - time * 10 + phase))
                if first { path.move(to: CGPoint(x: x, y: y)); first = false } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 3
            }
            var layerContext = context
            let color = Magma.color(shade)
            layerContext.addFilter(.shadow(color: color, radius: 7 + b * 11))
            layerContext.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6 + b * 0.9, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The 4 × 4 grid that stands for the Neural Engine: big in the boot panel, tiny in the status pill.
struct ANEGrid: View {
    var lit: Int = 16
    var color: Color = Color(hex: 0xFFA45F)
    var glow = true

    var body: some View {
        Canvas { context, size in
            let gap = size.width * 0.12, cell = (size.width - gap * 3) / 4
            for i in 0..<16 {
                let r = i / 4, c = i % 4
                let rect = CGRect(x: CGFloat(c) * (cell + gap), y: CGFloat(r) * (cell + gap), width: cell, height: cell)
                let on = Self.order[i] < lit
                var cellContext = context
                if on, glow { cellContext.addFilter(.shadow(color: color.opacity(0.6), radius: cell * 0.4)) }
                cellContext.fill(Path(roundedRect: rect, cornerRadius: cell * 0.24), with: .color(on ? color : Palette.faint.opacity(0.45)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Diagonal order: the cells light from the top-left corner.
    static let order: [Int] = {
        let sorted = (0..<16).sorted { ($0 / 4 + $0 % 4, $0) < ($1 / 4 + $1 % 4, $1) }
        var rank = [Int](repeating: 0, count: 16)
        for (n, i) in sorted.enumerated() { rank[i] = n }
        return rank
    }()
}

/// Model loading: the grid lights cell by cell as the loader reports each step.
private struct BootPanel: View {
    let log: [String]
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 30) {
            VStack(spacing: 12) {
                ANEGrid(lit: min(16, log.count * 3 + 1))
                    .frame(width: 112, height: 112)
                    .padding(12)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                    .matchedGeometryEffect(id: "ane", in: namespace)
                    .animation(Motion.snap, value: log.count)
                Text("神经网络引擎").font(Typeface.mono(10, weight: .medium)).foregroundStyle(Palette.scopeText.opacity(0.5))
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(log.suffix(6).enumerated()), id: \.offset) { index, line in
                    let last = index == min(log.count, 6) - 1
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Group {
                            if last { ProgressView().controlSize(.mini).tint(Color(hex: 0xFFA45F)) }
                            else { Image(systemName: "checkmark").foregroundStyle(Color(hex: 0x5AD6A5)) }
                        }
                        .frame(width: 14)
                        Text(Self.readable(line)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(last ? Palette.scopeText : Palette.scopeText.opacity(0.6))
                    }
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                }
            }
            .font(Typeface.mono(12))
            .animation(Motion.snap, value: log.count)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.scope.opacity(0.6))
    }

    /// The loader speaks English; the common lines get a Chinese label.
    static func readable(_ line: String) -> String {
        if line.hasPrefix("Loading "), let open = line.firstIndex(of: "(") {
            let name = line.dropFirst(8).prefix(upTo: open).trimmingCharacters(in: .whitespaces)
            let detail = line[line.index(after: open)...].dropLast()
            return "加载 \(stageName(name)) · \(detail.replacingOccurrences(of: ", ", with: " · "))"
        }
        if line.hasPrefix("Warming up ") { return "预热 \(stageName(String(line.dropFirst(11))))" }
        return line
    }

    static func stageName(_ name: String) -> String {
        switch name {
        case "encoder": "音频编码器"
        case "reader": "中文读取器"
        default: name
        }
    }
}

private struct ScopeNotice<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    var tint: Color = Color(hex: 0xFFA45F)
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 26, weight: .medium)).foregroundStyle(tint)
            Text(title).font(.headline).foregroundStyle(Palette.scopeText)
            Text(message).font(.callout).foregroundStyle(Palette.scopeText.opacity(0.6)).multilineTextAlignment(.center)
                .textSelection(.enabled).lineLimit(4)
            HStack { actions }.controlSize(.large).padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.scope.opacity(0.75))
        .environment(\.colorScheme, .dark)
    }
}

/// Marching ants while a file is dragged over the window.
private struct DropTarget: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(hex: 0xFFA45F), style: StrokeStyle(lineWidth: 1.5, dash: [7, 7], dashPhase: phase))
            .background(Color(hex: 0x0A0812).opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                VStack(spacing: 4) {
                    Text("松开即可转写").font(Typeface.serif(20, weight: .bold)).foregroundStyle(Palette.scopeText)
                    Text("支持 m4a · wav · mp3 · flac · caf").font(Typeface.mono(11)).foregroundStyle(Palette.scopeText.opacity(0.5))
                }
            }
            .padding(10)
            .onAppear { withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) { phase = -14 } }
    }
}
