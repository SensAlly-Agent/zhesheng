// 折声 (zhesheng): changed from eg2-transcribe at e6b7d5d (Apache-2.0). See NOTICE.
import SwiftUI

/// How the transcriber runs: the form of pipeline.json (which bundles, on which compute unit) and whether
/// consecutive windows overlap. The window itself comes from reader_config.json.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("转写方式") {
                    Picker("计算方式", selection: formSelection) {
                        ForEach(model.forms) { form in
                            Text(form.title).tag(form.id)
                        }
                    }
                    .disabled(model.isBusy || model.isRecording)
                    Toggle("并行处理音频片段", isOn: $model.overlap)
                        .disabled(model.isBusy || model.isRecording)
                    Text("开启后会同时处理相邻片段的不同步骤，以缩短转写时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("显示") {
                    Picker("转写文字大小", selection: $model.textSize) {
                        Text("跟随系统").tag(0.0)
                        Text("大").tag(28.0)
                        Text("特大").tag(44.0)
                    }
                }
                if let form = model.form {
                    Section("模型组件") {
                        ForEach(form.stages, id: \.self) { stage in
                            LabeledContent(stage.name, value: "\(stage.bundle) · \(stage.compute)")
                        }
                    }
                }
                if let folder = model.folder {
                    Section("模型文件夹") {
                        LabeledContent("音频窗口", value: String(format: "%.0f 秒，左侧上下文 %d 个词元",
                                                               folder.reader.windowSeconds, folder.reader.leftOverlapTokens))
                        LabeledContent("中文识别模型", value: folder.reader.version)
                        LabeledContent("模型目录", value: folder.bundleFolders.map { $0.lastPathComponent + "/" }.joined(separator: ", "))
                        // eg2zh (Mandarin, LM): LM or greedy decoding (set by reader_config.json lm_decode)
                        if let decoding = model.decodeSummary {
                            LabeledContent("解码状态", value: decoding)
                        }
                        Text(folder.root.path).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    /// Picking another form reloads the pipeline with its stages.
    private var formSelection: Binding<String> {
        Binding(get: { model.formID }, set: { id in Task { await model.selectForm(id) } })
    }
}
