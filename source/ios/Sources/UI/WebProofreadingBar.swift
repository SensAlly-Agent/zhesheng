import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "纠正错字，补全标点": a before/after example of what proofreading adds, the website, one button that copies the
/// prompt with the whole transcript and opens the site, and one that pastes the site's answer back. The app never
/// pastes into the site or sends anything itself.
struct WebProofreadingBar: View {
    @Bindable var model: AppModel
    let choreo: Choreo
    /// "贴回 AI 的结果": the answer the person copied on the site replaces the transcript (ContentView checks it).
    let pasteBack: () -> Void
    @AppStorage("proofreadingWebsite") private var websiteRaw = LLMWebsite.deepseek.rawValue
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sitePill
    @State private var message: String?
    @State private var requestID = UUID()
    @State private var done = false
    @State private var shine: CGFloat = -1

    private var website: LLMWebsite { .saved(websiteRaw) }
    private var hasTranscript: Bool { !model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var enabled: Bool { hasTranscript && !model.isBusy && !model.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasTranscript {
                HStack(spacing: 6) {
                    Circle().fill(Palette.plum).frame(width: 6, height: 6)
                        .phaseAnimator([1.0, 0.3]) { dot, value in dot.opacity(value) } animation: { _ in .easeInOut(duration: 0.6) }
                    Text("下一步").font(Typeface.mono(10.5, weight: .semibold)).tracking(1)
                }
                .foregroundStyle(Palette.plum)
                .choreoAnchor(.step, in: choreo)
                .padding(.bottom, 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Text("纠正错字，补全标点").font(.headline).padding(.bottom, 12)
            BeforeAfterExample(replay: choreo.example).padding(.bottom, 14)
            sites
            cta.padding(.top, 12)
            Button(action: pasteBack) {
                Label("贴回 AI 的结果", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(LiftButtonStyle())
            .disabled(!enabled)
            .padding(.top, 8)
            .help("把在 \(website.title) 复制的回答贴回来，替换转写结果")
            Text("自动复制完整转写和校对要求，打开网页后粘贴并发送即可。拿到回答后复制，回来点“贴回 AI 的结果”。")
                .font(.callout).padding(.top, 10)
            Text("建议使用支持深度思考的模型，并选择最高思考档位。")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
            if let message {
                Text(message).font(.footnote.weight(.medium)).foregroundStyle(Palette.ok).textSelection(.enabled)
                    .padding(.top, 8)
                    .transition(.push(from: .bottom).combined(with: .opacity))
            }
        }
        .card()
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.plum, lineWidth: 1.5)
                .phaseAnimator([0.0, 1.0, 0.0, 1.0, 0.0], trigger: choreo.nudge) { ring, value in
                    ring.opacity(value).shadow(color: Palette.plum.opacity(value * 0.6), radius: value * 10)
                } animation: { _ in .easeInOut(duration: 0.42) }
                .allowsHitTesting(false)
        }
        .animation(Motion.snap, value: hasTranscript)
        .animation(Motion.snap, value: message)
        .onChange(of: model.transcript) { _, _ in invalidateMessage() }
        .onChange(of: websiteRaw) { _, _ in invalidateMessage() }
        .onChange(of: enabled) { _, now in
            guard now, !reduceMotion else { return }
            shine = -1
            withAnimation(.easeInOut(duration: 0.9).delay(0.12)) { shine = 1 }
        }
    }

    private var sites: some View {
        HStack(spacing: 2) {
            ForEach(LLMWebsite.allCases) { site in
                Button {
                    withAnimation(Motion.snap) { websiteRaw = site.rawValue }
                } label: {
                    Text(site.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(site == website ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if site == website {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Palette.raised)
                                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "pill", in: sitePill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(site == website ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("选择 AI 网站")
    }

    private var cta: some View {
        Button(action: copyAndOpen) {
            ZStack {
                if done {
                    Label("已复制，正在打开 \(website.title)", systemImage: "checkmark")
                        .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .top)).combined(with: .opacity))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: enabled ? "doc.on.clipboard" : "lock")
                        Text("复制内容并打开")
                        Text(website.title).contentTransition(.interpolate)
                    }
                    .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .top)).combined(with: .opacity))
                }
            }
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(enabled ? Color(hex: 0x160C10) : Palette.faint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if enabled {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.ctaGradient)
                        .shadow(color: Palette.plum.opacity(0.4), radius: 12, y: 8)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.well)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
                }
            }
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.4)
                        .offset(x: geometry.size.width * (shine * 0.7 + 0.3))
                        .opacity(shine > -1 && shine < 1 ? 1 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressScaleStyle())
        .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: choreo.landed) { content, scale in
            content.scaleEffect(x: scale.width, y: scale.height)
        } keyframes: { _ in
            KeyframeTrack(\.width) {
                CubicKeyframe(0.94, duration: 0.12)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
            KeyframeTrack(\.height) {
                CubicKeyframe(0.86, duration: 0.12)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
        }
        .disabled(!enabled)
        .animation(Motion.snap, value: done)
        .animation(Motion.snap, value: websiteRaw)
        .choreoAnchor(.cta, in: choreo)
        .help("复制完整转写和校对要求，并打开 \(website.title) 官网")
    }

    private func invalidateMessage() {
        requestID = UUID()
        message = nil
    }

    private func copyAndOpen() {
        let transcript = model.transcript
        let destination = website
        let id = UUID()
        requestID = id
        let copied = WebHandoff.copyPrompt(transcript) { text in
            #if os(macOS)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            return true
            #endif
        }
        switch copied {
        case .empty:
            message = "请先完成一次转写。"
        case .copyFailed:
            message = "复制未成功，请重试。"
        case .copied(let characters):
            message = "已复制全文和校对要求。"
            Task {
                // The slip lands in the button, then the card says what was copied; the browser opens only on Open.
                await choreo.fly(preview: transcript, characters: characters, reduceMotion: reduceMotion)
                guard requestID == id else { return }
                let open = await choreo.askToOpen(.init(site: destination, characters: characters))
                guard requestID == id else { return }
                guard open else {
                    message = "已复制全文和校对要求。需要时打开 \(destination.title)，粘贴并发送即可。"
                    return
                }
                message = "已复制全文和校对要求，正在打开 \(destination.title)。"
                done = true
                choreo.handedOff = destination
                choreo.showHandoffCard(destination)
                openURL(destination.url, completion: WebHandoff.onMainActor { accepted in
                    guard requestID == id, model.transcript == transcript, website == destination else { return }
                    message = accepted
                        ? "已复制全文和校对要求，请到 \(destination.title) 粘贴并发送。"
                        : "已复制全文和校对要求。未能打开网页，请手动访问 \(destination.url.absoluteString) 后粘贴。"
                })
                try? await Task.sleep(for: .seconds(1.6))
                done = false
            }
        }
    }
}

/// The same sentence before and after proofreading: the marks drop in one by one and the misheard character is
/// struck and replaced. It is an example, labelled as one; the app never sees the site's answer.
struct BeforeAfterExample: View {
    let replay: Int

    private enum Piece { case text(String), mark(String, Int), fix(String, String) }
    private static let pieces: [Piece] = [.text("本地模型目前只输出汉字"), .mark("，", 0), .text("不带标点"), .mark("；", 1),
                                          .text("有些同音字也会认"), .fix("措", "错"), .mark("。", 2)]

    @State private var marks = 3
    @State private var struck = true
    @State private var fixed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("原始").font(Typeface.mono(10.5, weight: .medium)).foregroundStyle(Palette.faint).frame(width: 40, alignment: .leading)
                (Text("本地模型目前只输出汉字不带标点有些同音字也会认") + Text("措").underline(struck, pattern: .dot, color: Palette.plum))
                    .font(Typeface.serif(13.5)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("校对后").font(Typeface.mono(10.5, weight: .medium)).foregroundStyle(Palette.ok).frame(width: 40, alignment: .leading)
                FlowLayout {
                    ForEach(Array(Self.pieces.enumerated()), id: \.offset) { _, piece in
                        switch piece {
                        case .text(let text):
                            ForEach(Array(text.enumerated()), id: \.offset) { _, c in Text(String(c)) }
                        case .mark(let mark, let index):
                            Text(mark).fontWeight(.black).foregroundStyle(Palette.plum)
                                .scaleEffect(marks > index ? 1 : 0.3, anchor: .bottom)
                                .offset(y: marks > index ? 0 : -10)
                                .opacity(marks > index ? 1 : 0)
                        case .fix(let old, let new):
                            Text(old).foregroundStyle(Palette.faint)
                                .overlay {
                                    Rectangle().fill(Palette.plum).frame(height: 1.5)
                                        .scaleEffect(x: struck ? 1 : 0, anchor: .leading)
                                }
                            if fixed {
                                Text(new).fontWeight(.bold).foregroundStyle(Palette.ok)
                                    .transition(.offset(y: 8).combined(with: .scale(scale: 0.6)).combined(with: .opacity))
                            }
                        }
                    }
                }
                .font(Typeface.serif(13.5))
            }
            HStack {
                Text("效果示例 · 由 AI 网站完成")
                Spacer()
                Button("再看一遍") { Task { await play() } }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5)).foregroundStyle(Palette.faint)
            .padding(.top, 2)
        }
        .padding(12)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .onChange(of: replay) { _, _ in Task { await play() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("效果示例。原始：本地模型目前只输出汉字不带标点有些同音字也会认措。校对后：本地模型目前只输出汉字，不带标点；有些同音字也会认错。")
    }

    private func play() async {
        guard !reduceMotion else { return }
        marks = 0; struck = false; fixed = false
        try? await Task.sleep(for: .milliseconds(280))
        for n in 1...3 {
            withAnimation(Motion.bounce) { marks = n }
            try? await Task.sleep(for: .milliseconds(280))
        }
        withAnimation(.easeOut(duration: 0.3)) { struck = true }
        try? await Task.sleep(for: .milliseconds(320))
        withAnimation(Motion.bounce) { fixed = true }
    }
}
