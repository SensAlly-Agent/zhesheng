import SwiftUI

/// The moments that span several views: the raw-transcript notice and its guide line to the proofreading card,
/// and the copied text flying into the Copy-and-open button. Views report their frames here (in the "root"
/// coordinate space of the scrolling content) so the overlays can draw between them.
@MainActor
@Observable
final class Choreo {
    enum Anchor: Hashable { case rawButton, step, transcript, cta }

    var frames: [Anchor: CGRect] = [:]
    /// The "this is the raw transcript, no punctuation yet" notice above the transcript.
    var rawNote = false
    /// The guide line from the notice to the proofreading card: drawn length 0…1, and whether it is shown.
    var guide: CGFloat = 0
    var guideVisible = false
    /// Bumped to pulse the proofreading card and to replay its before/after example.
    var nudge = 0
    var example = 0
    /// The site the transcript was last copied for (the notice then says what to do there).
    var handedOff: LLMWebsite?
    /// The flying slip: 0…1 along its arc while it flies, nil otherwise; `landed` bumps when it reaches the button.
    var flight: CGFloat?
    var flightCharacters = 0
    var flightPreview = ""
    var landed = 0
    /// The browser hint in the window's corner after a handoff.
    var handoffCard: LLMWebsite?
    /// What was just copied, shown until the person chooses to open the site (or not).
    var confirm: HandoffRequest?
    private var confirmReply: CheckedContinuation<Bool, Never>?

    struct HandoffRequest: Equatable {
        let site: LLMWebsite
        let characters: Int
    }

    /// Shows what was copied and what to do with it; returns whether to open the site now.
    func askToOpen(_ request: HandoffRequest) async -> Bool {
        confirmReply?.resume(returning: false)
        return await withCheckedContinuation { reply in
            confirmReply = reply
            withAnimation(Motion.bounce) { confirm = request }
        }
    }

    func answer(open: Bool) {
        withAnimation(open ? Motion.snap : .easeIn(duration: 0.2)) { confirm = nil }
        confirmReply?.resume(returning: open)
        confirmReply = nil
    }

    private var sequence: Task<Void, Never>?
    private var cardTask: Task<Void, Never>?

    /// A fresh transcript: say it is raw, draw the eye to the proofreading card, show what proofreading adds.
    func transcriptArrived(reduceMotion: Bool) {
        sequence?.cancel()
        handedOff = nil
        sequence = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.snap) { rawNote = true }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            guide = 0
            guideVisible = true
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.72)) { guide = 1 }
            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            nudge += 1
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            example += 1
            try? await Task.sleep(for: .milliseconds(3000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { guideVisible = false }
        }
    }

    func transcriptCleared() {
        sequence?.cancel()
        rawNote = false
        guideVisible = false
        handedOff = nil
    }

    /// The proofread answer pasted back, or the recognition restored: the notice says which text this is; no guide.
    func textReplaced() {
        sequence?.cancel()
        handedOff = nil
        withAnimation(.easeOut(duration: 0.3)) { guideVisible = false }
        withAnimation(Motion.snap) { rawNote = true }
    }

    /// The text folds into a slip and flies along an arc into the button; `landed` fires on arrival.
    func fly(preview: String, characters: Int, reduceMotion: Bool) async {
        guard !reduceMotion, frames[.transcript] != nil, frames[.cta] != nil else { landed += 1; return }
        flightPreview = String(preview.prefix(60))
        flightCharacters = characters
        flight = 0
        try? await Task.sleep(for: .milliseconds(16))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            withAnimation(.easeInOut(duration: 0.76)) { flight = 1 } completion: { done.resume() }
        }
        flight = nil
        landed += 1
    }

    func showHandoffCard(_ site: LLMWebsite) {
        cardTask?.cancel()
        withAnimation(Motion.bounce) { handoffCard = site }
        cardTask = Task {
            try? await Task.sleep(for: .seconds(4.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.24)) { handoffCard = nil }
        }
    }

    func hideHandoffCard() {
        cardTask?.cancel()
        withAnimation(.easeIn(duration: 0.24)) { handoffCard = nil }
    }
}

extension View {
    /// Reports this view's frame in the scrolling content's coordinate space.
    func choreoAnchor(_ anchor: Choreo.Anchor, in choreo: Choreo) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { choreo.frames[anchor] = $0 }
    }
}

/// The line from the raw-transcript notice to the Copy-and-open button.
struct GuideLine: View {
    let choreo: Choreo

    var body: some View {
        if choreo.guideVisible, let a = choreo.frames[.rawButton], let b = choreo.frames[.cta], b.minX > a.maxX {
            let start = CGPoint(x: a.maxX + 6, y: a.midY), end = CGPoint(x: b.minX - 8, y: b.midY)
            ZStack {
                Path { path in
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + 70, y: start.y), control2: CGPoint(x: end.x - 90, y: end.y))
                }
                .trim(from: 0, to: choreo.guide)
                .stroke(Palette.plum, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: Palette.plum.opacity(0.5), radius: 4)
                Circle().fill(Palette.plum).frame(width: 7, height: 7)
                    .scaleEffect(choreo.guide > 0.97 ? 1 : 0.01)
                    .animation(Motion.bounce, value: choreo.guide > 0.97)
                    .position(end)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// The slip that carries the transcript into the button.
struct FlightOverlay: View {
    let choreo: Choreo

    var body: some View {
        if let t = choreo.flight, let a = choreo.frames[.transcript], let b = choreo.frames[.cta] {
            let start = CGPoint(x: a.minX + min(a.width, 360) / 2, y: a.minY + 60)
            let end = CGPoint(x: b.midX, y: b.midY)
            VStack(alignment: .leading, spacing: 4) {
                Text("校对要求 + 全文 \(choreo.flightCharacters) 字").font(Typeface.mono(11, weight: .semibold)).foregroundStyle(Palette.ember)
                Text(choreo.flightPreview).font(Typeface.serif(12)).lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 220, alignment: .leading)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .modifier(ArcFlight(t: t, start: start, end: end))
            .allowsHitTesting(false)
        }
    }
}

/// Position, scale and tilt along a quadratic arc; animatable in `t`.
struct ArcFlight: ViewModifier, Animatable {
    var t: CGFloat
    let start: CGPoint
    let end: CGPoint

    nonisolated var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    func body(content: Content) -> some View {
        let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 140)
        let u = 1 - t
        let point = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        return content
            .scaleEffect(1 - 0.82 * pow(t, 1.6))
            .rotationEffect(.degrees(sin(t * .pi) * -9))
            .opacity(t > 0.9 ? Double((1 - t) * 10) : 1)
            .position(point)
    }
}

/// After the copy: what the person gets back once they paste and send, and the three steps to get it. The browser
/// opens only when they press Open, so nothing jumps in front of them before they have read it.
struct HandoffConfirmCard: View {
    let request: Choreo.HandoffRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Palette.plum, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("已复制，可以去粘贴了").font(.system(size: 17, weight: .bold))
                    Text("全部 \(request.characters) 字都在剪贴板里").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("发送后你会得到").font(Typeface.mono(10.5, weight: .semibold)).foregroundStyle(Palette.faint)
                VStack(alignment: .leading, spacing: 10) {
                    Text("一份加好标点、改正错字的完整文稿。")
                        .font(.system(size: 14, weight: .semibold))
                    MorphExample()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ok.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ok.opacity(0.25)))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("怎么拿到").font(Typeface.mono(10.5, weight: .semibold)).foregroundStyle(Palette.faint)
                step(1, "打开 \(request.site.title)")
                step(2, "在对话框按 ⌘V 粘贴")
                step(3, "选深度思考、最高档位，然后发送")
                step(4, "复制 AI 的回答，回到折声点“贴回结果”")
                Text("App 不会替你粘贴或发送。原始转写仍保留在这里。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 2)
            }

            HStack {
                Button("先不打开") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Spacer()
                Button { answer(true) } label: {
                    Label("打开 \(request.site.title)", systemImage: "arrow.up.right")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color(hex: 0x160C10))
                        .padding(.horizontal, 18).frame(height: 38)
                        .background(Palette.ctaGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(Typeface.mono(11, weight: .bold)).foregroundStyle(Palette.plum)
                .frame(width: 20, height: 20)
                .background(Circle().strokeBorder(Palette.plum.opacity(0.6)))
            Text(text).font(.system(size: 13))
        }
    }
}

/// One sentence turning from the raw recognition into the proofread text: the marks drop into their places and the
/// misheard character flips to the right one. Plays when shown; a tap plays it again.
struct MorphExample: View {
    private enum Piece { case text(String), mark(String, Int), fix(String, String) }
    private static let pieces: [Piece] = [.text("本地模型目前只输出汉字"), .mark("，", 0), .text("不带标点"), .mark("；", 1),
                                          .text("有些同音字也会认"), .fix("措", "错"), .mark("。", 2)]

    @State private var marks = 0
    @State private var fixed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fixed ? "校对后" : "原稿")
                .font(Typeface.mono(10.5, weight: .medium))
                .foregroundStyle(fixed ? Palette.ok : Palette.faint)
                .contentTransition(.interpolate)
                .frame(width: 40, alignment: .leading)
            FlowLayout {
                ForEach(Array(Self.pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .text(let text):
                        ForEach(Array(text.enumerated()), id: \.offset) { _, c in Text(String(c)) }
                    case .mark(let mark, let index):
                        // The slot keeps its width, so the line never reflows while the marks fall in.
                        Text(mark).fontWeight(.black).foregroundStyle(Palette.plum)
                            .scaleEffect(marks > index ? 1 : 0.3, anchor: .bottom)
                            .offset(y: marks > index ? 0 : -12)
                            .opacity(marks > index ? 1 : 0)
                    case .fix(let old, let new):
                        ZStack {
                            Text(old).underline(true, pattern: .dot, color: Palette.plum)
                                .opacity(fixed ? 0 : 1).offset(y: fixed ? -10 : 0)
                            Text(new).fontWeight(.bold).foregroundStyle(Palette.ok)
                                .opacity(fixed ? 1 : 0).offset(y: fixed ? 0 : 10)
                        }
                    }
                }
            }
            .font(Typeface.serif(13.5))
            .foregroundStyle(fixed ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await play() } }
        .task { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("示例：本地模型目前只输出汉字，不带标点；有些同音字也会认错。")
    }

    private func play() async {
        marks = 0; fixed = false
        if reduceMotion { marks = 3; fixed = true; return }
        try? await Task.sleep(for: .milliseconds(700))
        for n in 1...3 {
            withAnimation(Motion.bounce) { marks = n }
            try? await Task.sleep(for: .milliseconds(300))
        }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(Motion.bounce) { fixed = true }
    }
}
