// 折声 (zhesheng): changed from eg2-transcribe at e6b7d5d (Apache-2.0). See NOTICE.
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The transcript: editable in place, with the file it is of, Copy and Save. A fresh text fades in, and a notice above
/// it says which text this is: the raw recognition (no punctuation yet, and where to fix that), the same after the
/// handoff (paste the answer back here), or the AI's proofread answer (and how to go back to the recognition).
struct TranscriptView: View {
    @Binding var text: String
    /// Bumped when a new text comes in, not on edits: the fade-in and the editor's identity follow it.
    let generation: Int
    /// There is a text to show and edit (also when the person deleted all of it); otherwise the placeholder.
    let hasText: Bool
    let isProofread: Bool
    let isEdited: Bool
    /// The audio file's name (nil until there is a transcript).
    let file: String?
    /// Points; 0 = the platform's body size.
    let size: Double
    let choreo: Choreo
    var editorFocus: FocusState<Bool>.Binding
    /// "去补标点": scroll to the proofreading card.
    let goProofread: () -> Void
    /// "贴回结果": put the AI website's answer from the clipboard here.
    let pasteBack: () -> Void
    /// "恢复原始稿": the recognition again.
    let restore: () -> Void

    @State private var reveal: Double = 1
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @State private var exporting = false
    @State private var exportError: String?
    @State private var savedFilename: String?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if choreo.rawNote, hasText {
                note
                    .transition(.asymmetric(insertion: .push(from: .top).combined(with: .opacity), removal: .opacity))
            }
            Group {
                if hasText {
                    TextEditor(text: $text)
                        .font(size > 0 ? Typeface.serif(size) : Typeface.serif(16))
                        .tracking(0.6)
                        .lineSpacing(size > 0 ? size * 0.35 : 9)
                        .scrollContentBackground(.hidden)
                        .focused(editorFocus)
                        .accessibilityLabel("转写结果")
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .opacity(reveal)
                        .offset(y: (1 - reveal) * 10)
                } else {
                    Text("选择一段普通话音频，或开始录音。转写结果会显示在这里。")
                        .font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 18).padding(.vertical, 16)
                }
            }
            // A new text gets a new editor, so it opens at its first line without scrolling the window; edits keep it.
            .id(generation)
            .frame(minHeight: 150, maxHeight: 320)
            .choreoAnchor(.transcript, in: choreo)
            footer
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
        .animation(Motion.snap, value: choreo.rawNote)
        .animation(Motion.snap, value: isProofread)
        .onChange(of: generation) { _, _ in
            guard !text.isEmpty, !reduceMotion else { reveal = 1; return }
            reveal = 0
            withAnimation(.easeOut(duration: 0.6)) { reveal = 1 }
        }
        .onChange(of: text) { _, _ in savedFilename(nil) }
        #if os(macOS)
        .fileExporter(isPresented: $exporting, document: TranscriptDocument(text: text),
                      contentType: .plainText, defaultFilename: exportFilename) { result in
            switch result {
            case .success(let url):
                savedFilename = url.lastPathComponent
            case .failure(let error):
                let cocoaError = error as NSError
                if cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError {
                    exportError = error.localizedDescription
                }
            }
        }
        .alert("无法保存文本", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        #endif
    }

    private func savedFilename(_ name: String?) {
        #if os(macOS)
        savedFilename = name
        #endif
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("转写结果").font(.headline)
            if let file {
                Text(file).font(Typeface.mono(11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                copy(text)
                withAnimation(Motion.snap) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.7))
                    withAnimation(Motion.snap) { copied = false }
                }
            } label: {
                Label {
                    Text(copied ? "已复制" : "复制").contentTransition(.interpolate)
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Palette.ok : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(minHeight: 30)
            }
            .buttonStyle(.borderless)
            .disabled(text.isEmpty)
            #if os(macOS)
            Button {
                savedFilename = nil
                exporting = true
            } label: {
                Label("保存文本…", systemImage: "square.and.arrow.down").frame(minHeight: 30)
            }
            .buttonStyle(.borderless)
            .disabled(text.isEmpty)
            #endif
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    /// Which text this is, said at once: the raw recognition (no punctuation yet; go proofread), the same after the
    /// handoff (paste the answer back here), or the proofread answer (edit it, or go back to the recognition).
    private var note: some View {
        let tint = isProofread ? Palette.ok : Palette.plum
        return HStack(spacing: 12) {
            Group {
                if isProofread {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(tint, lineWidth: 1.5))
                } else {
                    Text("，")
                        .font(Typeface.serif(30, weight: .black))
                        .foregroundStyle(tint)
                        .offset(x: 7, y: -7)
                        .frame(width: 38, height: 38, alignment: .center)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(noteTitle)
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.interpolate)
                Text(noteDetail)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if isProofread {
                    Button("恢复原始稿", action: restore)
                        .buttonStyle(LiftButtonStyle())
                } else if choreo.handedOff != nil {
                    noteButton("贴回结果", action: pasteBack)
                } else {
                    noteButton("去补标点 →", action: goProofread)
                }
            }
            .choreoAnchor(.rawButton, in: choreo)
        }
        .padding(.vertical, 10).padding(.leading, 12).padding(.trailing, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3)))
        .padding([.horizontal, .top], 12)
        .animation(Motion.snap, value: choreo.handedOff)
    }

    private var noteTitle: String {
        if isProofread { return isEdited ? "这是 AI 校对后的文稿，你已修改过" : "这是 AI 校对后的文稿" }
        if let site = choreo.handedOff { return "已复制。到 \(site.title) 粘贴发送，再把回答复制回来" }
        return "这是原始识别稿，还没有标点"
    }

    private var noteDetail: String {
        if isProofread { return "可以直接在下面修改。想对照原文，可以恢复原始识别稿。" }
        if choreo.handedOff != nil { return "复制好 AI 的回答后点“贴回结果”，它会替换下面的识别稿，原稿随时能恢复。" }
        return "本地模型只负责把声音变成汉字。断句、标点和错字，交给 AI 网站一次补全。"
    }

    private func noteButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Palette.plum, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressScaleStyle())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(text.count) 字")
            if !hasText {
                Text("本地转写只输出汉字，不含标点")
            } else {
                Text("\(Self.punctuationCount(text)) 个标点").foregroundStyle(Palette.plum).fontWeight(.medium)
                if isProofread {
                    Text("AI 校对稿").foregroundStyle(Palette.ok).fontWeight(.medium)
                } else {
                    Text("待校对")
                }
                Text(isEdited ? "已修改" : "可直接修改")
            }
            Spacer()
            #if os(macOS)
            if let savedFilename {
                Label("已保存：\(savedFilename)", systemImage: "checkmark.circle").foregroundStyle(Palette.ok)
                    .transition(.push(from: .bottom).combined(with: .opacity))
            }
            #endif
        }
        .font(Typeface.mono(11))
        .foregroundStyle(Palette.faint)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .animation(Motion.snap, value: text.isEmpty)
    }

    static func punctuationCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
    }

    #if os(macOS)
    private var exportFilename: String {
        guard let file, !file.isEmpty else { return "转写结果.txt" }
        return URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent + ".txt"
    }
    #endif

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#if os(macOS)
/// Plain text exports always use UTF-8; the original audio remains untouched.
private struct TranscriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data((text + "\n").utf8))
    }
}
#endif
