// 折声 (zhesheng): changed from eg2-transcribe at e6b7d5d (Apache-2.0). See NOTICE.
import Foundation

/// This Mandarin build only reads local models. Audio never leaves the device.
enum ModelStore {
    static var localFolder: URL {
        URL.documentsDirectory.appending(path: "models/eg2-transcribe-zh", directoryHint: .isDirectory)
    }

    /// The model inside the app (the Mac app ships with it).
    static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appending(path: "eg2-transcribe-zh", directoryHint: .isDirectory)
    }

    /// The folder the user chose with “选择模型文件夹…”, the only folder the app remembers. Builds up to 13 kept every
    /// folder they opened under `modelFolderPathZh`, their own model too, so a copy of the app went on opening another
    /// copy's model (an old one once the model changes); that key is no longer read. A key of its own also keeps out a
    /// folder remembered by the English build (same bundle identifier, same user defaults).
    static let chosenFolderKey = "modelFolderChosenZh"

    /// The folder to open at launch: a `-models <dir>` launch argument, else the folder the user chose, else the app's
    /// own model, else `localFolder`; the first that holds a pipeline.json.
    static func launchFolder(defaults: UserDefaults = .standard, bundled: URL? = bundledFolder,
                             local: URL = localFolder) -> URL? {
        let preferred = (defaults.string(forKey: "models") ?? defaults.string(forKey: chosenFolderKey))
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return locate(preferred: preferred, bundled: bundled, local: local)
    }

    /// Remembers the folder the user chose: it opens first from the next launch on. Choosing the app's own model
    /// forgets the choice instead: that model opens anyway, and its path would lead a copy of the app elsewhere here.
    static func rememberChosen(_ folder: URL, defaults: UserDefaults = .standard, bundled: URL? = bundledFolder) {
        if let bundled, folder.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path {
            defaults.removeObject(forKey: chosenFolderKey)
        } else {
            defaults.set(folder.path, forKey: chosenFolderKey)
        }
    }

    static func locate(preferred: URL? = nil, bundled: URL? = bundledFolder, local: URL = localFolder) -> URL? {
        let candidates = [preferred, bundled, local].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "pipeline.json").path) }
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw TranscribeError.download("此版本使用本地中文模型。请选择包含 pipeline.json 的模型文件夹。")
    }
}
