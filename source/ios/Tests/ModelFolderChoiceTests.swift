import XCTest

/// At launch the app opens its own model, unless `-models <dir>` names a folder or the user chose one with
/// 选择模型文件夹…. A folder that builds up to 13 remembered on their own (`modelFolderPathZh`, written for every
/// folder they opened, another copy's model included) is not opened.
final class ModelFolderChoiceTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "model-folder-choice-\(UUID().uuidString)", directoryHint: .isDirectory)
        suite = "local.eg2zh.tests.model-folder-choice.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// A folder `ModelStore.locate` takes: it holds a pipeline.json.
    private func modelFolder(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appending(path: "pipeline.json"))
        return url
    }

    private var documentsFolder: URL { root.appending(path: "Documents/models/eg2-transcribe-zh", directoryHint: .isDirectory) }

    private func launchPath(bundled: URL?) -> String? {
        ModelStore.launchFolder(defaults: defaults, bundled: bundled, local: documentsFolder)?.path
    }

    func testFreshMacOpensTheAppsOwnModel() throws {
        let bundled = try modelFolder("折声.app/Contents/Resources/eg2-transcribe-zh")
        XCTAssertEqual(launchPath(bundled: bundled), bundled.path)
    }

    func testFolderRememberedByAnOlderBuildIsNotOpened() throws {
        let bundled = try modelFolder("折声.app/Contents/Resources/eg2-transcribe-zh")
        let other = try modelFolder("EG2ZH-ANE-Cloud.app/Contents/Resources/eg2-transcribe-zh")
        defaults.set(other.path, forKey: "modelFolderPathZh")
        XCTAssertEqual(launchPath(bundled: bundled), bundled.path)
        XCTAssertEqual(defaults.string(forKey: "modelFolderPathZh"), other.path, "the old builds' key is left to them")
    }

    func testChosenFolderOpensFirst() throws {
        let bundled = try modelFolder("折声.app/Contents/Resources/eg2-transcribe-zh")
        let chosen = try modelFolder("models/eg2-transcribe-zh")
        ModelStore.rememberChosen(chosen, defaults: defaults, bundled: bundled)
        XCTAssertEqual(defaults.string(forKey: ModelStore.chosenFolderKey), chosen.path)
        XCTAssertEqual(launchPath(bundled: bundled), chosen.path)
    }

    func testChosenFolderThatIsGoneFallsBackToTheAppsOwnModel() throws {
        let bundled = try modelFolder("折声.app/Contents/Resources/eg2-transcribe-zh")
        let gone = root.appending(path: "unplugged/eg2-transcribe-zh", directoryHint: .isDirectory)
        ModelStore.rememberChosen(gone, defaults: defaults, bundled: bundled)
        XCTAssertEqual(launchPath(bundled: bundled), bundled.path)
        XCTAssertEqual(defaults.string(forKey: ModelStore.chosenFolderKey), gone.path, "kept for when it is back")
    }

    func testChoosingTheAppsOwnModelForgetsTheChoice() throws {
        let bundled = try modelFolder("折声.app/Contents/Resources/eg2-transcribe-zh")
        let chosen = try modelFolder("models/eg2-transcribe-zh")
        ModelStore.rememberChosen(chosen, defaults: defaults, bundled: bundled)
        ModelStore.rememberChosen(URL(fileURLWithPath: bundled.path + "/"), defaults: defaults, bundled: bundled)
        XCTAssertNil(defaults.string(forKey: ModelStore.chosenFolderKey))
        XCTAssertEqual(launchPath(bundled: bundled), bundled.path)
    }

    func testModelsLaunchArgumentComesFirst() throws {
        let bundled = try modelFolder("折声.app/Contents/Resources/eg2-transcribe-zh")
        let chosen = try modelFolder("models/eg2-transcribe-zh")
        let argument = try modelFolder("argument/eg2-transcribe-zh")
        ModelStore.rememberChosen(chosen, defaults: defaults, bundled: bundled)
        // What `-models <dir>` puts in the argument domain of the user defaults.
        defaults.set(argument.path, forKey: "models")
        XCTAssertEqual(launchPath(bundled: bundled), argument.path)
        XCTAssertEqual(defaults.string(forKey: ModelStore.chosenFolderKey), chosen.path)
    }

    /// The iPhone app has no model inside: Documents/models/eg2-transcribe-zh, else nothing.
    func testWithoutAModelInsideTheAppTheDocumentsFolderOpens() throws {
        XCTAssertNil(launchPath(bundled: nil))
        let documents = try modelFolder("Documents/models/eg2-transcribe-zh")
        XCTAssertEqual(launchPath(bundled: nil), documents.path)
    }
}
