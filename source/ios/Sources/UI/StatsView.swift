// 折声 (zhesheng): changed from eg2-transcribe at e6b7d5d (Apache-2.0). See NOTICE.
import SwiftUI

/// The numbers of the last transcription: times real time as the headline, the audio length and wall clock under
/// it, then where the time went as one bar split by step (in the order the steps run).
struct StatsView: View {
    let stats: RunStats?
    let busy: Bool

    @State private var shown: Double = 0
    @State private var grown = false
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Part: Identifiable {
        let id: Int
        let name: String
        let seconds: Double
        let color: Color
    }

    private static let colors: [UInt32] = [0x3B0F70, 0x8C2981, 0xDE4968, 0xFE9F6D, 0xFCD9A0, 0x6B6585, 0x51127C]

    private var parts: [Part] {
        guard let stats else {
            return ["读取音频", "音频特征", "音频编码器", "中文读取器", "语言模型解码", "其他处理"].enumerated()
                .map { Part(id: $0.offset, name: $0.element, seconds: 1, color: Palette.faint) }
        }
        var named: [(String, Double)] = [("读取音频", stats.decodeSeconds), ("音频特征", stats.logMelSeconds)]
        named += zip(stats.stageSeconds, stats.stageSums).map { (Self.stageName($0), $1) }
        if stats.decodeMode == "lm" { named.append(("语言模型解码", stats.decodeMilliseconds / 1000)) }
        named.append(("其他处理", stats.hostSeconds))
        return named.enumerated().map {
            Part(id: $0.offset, name: $0.element.0, seconds: max(0, $0.element.1), color: Color(hex: Self.colors[$0.offset % Self.colors.count]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("本次转写").font(Typeface.mono(10.5, weight: .medium)).foregroundStyle(Palette.faint)
                Spacer()
                Text(stats?.file ?? "尚无记录").font(Typeface.mono(11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("×").font(Typeface.mono(26, weight: .medium)).foregroundStyle(stats == nil ? Palette.faint : Palette.ember)
                CountingText(value: shown, placeholder: stats == nil)
                    .font(.system(size: 58, weight: .semibold, design: .monospaced))
                    .foregroundStyle(stats == nil ? Palette.faint : .primary)
                Text("倍实时速度").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
            Text(headline).font(Typeface.mono(12)).foregroundStyle(.secondary).textSelection(.enabled)
            bar.padding(.top, 16).padding(.bottom, 12)
            legend
            if let stats {
                Text("\(stats.form)，并行处理\(stats.overlap ? "开启" : "关闭")")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint).padding(.top, 10)
            }
        }
        .card()
        .onChange(of: stats, initial: true) { _, new in play(new) }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        guard let stats else { return busy ? "正在转写…" : "完成一次转写后，这里显示速度和各步骤耗时。" }
        return "音频 \(Self.clock(stats.audioSeconds)) · 耗时 \(Self.duration(stats.totalSeconds)) · \(stats.windows) 个片段"
    }

    private var bar: some View {
        let parts = parts, total = max(parts.reduce(0) { $0 + $1.seconds }, 1e-9)
        return GeometryReader { geometry in
            let available = geometry.size.width - CGFloat(parts.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(parts) { part in
                    Group {
                        if stats == nil {
                            RoundedRectangle(cornerRadius: 3).fill(Palette.line)
                        } else {
                            RoundedRectangle(cornerRadius: 3).fill(part.color)
                        }
                    }
                    .frame(width: max(2, available * part.seconds / total))
                    .scaleEffect(x: grown ? 1 : 0.001, y: hovered == part.id ? 1.7 : 1, anchor: .leading)
                    .animation(Motion.snap.delay(grown ? 0.2 + Double(part.id) * 0.09 : 0), value: grown)
                    .animation(Motion.snap, value: hovered)
                    .onHover { hovered = $0 ? part.id : (hovered == part.id ? nil : hovered) }
                    .help(stats == nil ? part.name : "\(part.name) · \(Self.duration(part.seconds)) · \(Int((part.seconds / total * 100).rounded()))%")
                }
            }
        }
        .frame(height: 12)
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 5) {
            ForEach(parts) { part in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 7, height: 7)
                    Text(part.name).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(stats == nil ? "—" : Self.duration(part.seconds)).font(Typeface.mono(11, weight: .medium))
                        .foregroundStyle(stats == nil ? Palette.faint : .primary)
                }
                .font(.system(size: 11.5))
                .opacity(grown || stats == nil ? 1 : 0)
                .offset(y: grown || stats == nil ? 0 : 6)
                .animation(Motion.snap.delay(0.26 + Double(part.id) * 0.09), value: grown)
            }
        }
    }

    private func play(_ stats: RunStats?) {
        guard let stats else { shown = 0; grown = true; return }
        grown = false
        shown = 0
        let target = stats.realtimeFactor.rounded()
        if reduceMotion { shown = target; grown = true; return }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.3)) { shown = target }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            grown = true
        }
    }

    static func stageName(_ name: String) -> String {
        switch name {
        case "encoder": "音频编码器"
        case "reader": "中文读取器"
        default: name
        }
    }

    /// Milliseconds below a second, seconds above.
    static func duration(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f 毫秒", seconds * 1000) : String(format: "%.2f 秒", seconds)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A whole number that counts up as `value` animates.
private struct CountingText: View, Animatable {
    var value: Double
    var placeholder: Bool

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(placeholder ? "—" : "\(Int(value.rounded()))").monospacedDigit()
    }
}
