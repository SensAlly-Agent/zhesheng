**English** | [简体中文](README.zh-CN.md)

# 折声 (Zhesheng)

Offline Mandarin speech-to-text for the Mac. The recognition model is inside the app and transcription runs entirely on your Mac, so your recordings are never uploaded. When a transcript is ready, you can hand it to an AI website such as DeepSeek or ChatGPT to add punctuation and fix wrong characters, then paste the result back.

- Open an audio file (m4a, wav, mp3, flac, caf), or record directly
- Measured on a MacBook Air (M4): a 65-minute recording is transcribed in under 15 seconds
- One click copies the transcript with a proofreading prompt and opens DeepSeek, ChatGPT, Claude, Gemini or Kimi; the app never pastes or sends anything for you
- Paste the AI's answer back; the original recognition can be restored at any time
- Edit the transcript directly, then save it as text

The app's interface is in Simplified Chinese.

## Download and install

Download `zhesheng-1.0-build17.dmg` (about 220 MB) from [Releases](https://github.com/SensAlly-Agent/zhesheng/releases/latest), open it and drag 折声 into Applications. You don't need Xcode, and the model needs no separate download.

Requirements:

- A Mac with Apple silicon (M1 or later)
- macOS 27 or later
- About 2 GB of free space

**First open**: 折声 is not notarized by Apple, so macOS blocks it once. Click Done (not Move to Trash), then open System Settings > Privacy & Security, click Open Anyway under Security, and confirm with your password or Touch ID. You won't be asked again.

On its first run, 折声 prepares the model for your Mac's chip. This takes about a minute; please don't force quit. After that it opens in a few seconds.

The disk image includes step-by-step instructions in Chinese, 安装与使用.txt ([tools/dmg/安装与使用.txt](tools/dmg/安装与使用.txt)).

## Accuracy

Measured with build 17 on a MacBook Air (M4), using 6 public test recordings (AISHELL-1 test, 6 speakers, 27 minutes, 5,025 characters): a character error rate of 3.46%, that is 174 errors in 5,025 characters (wrong, missing and extra characters all count).

## Build from source

You need Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. The model is not in the repository (about 640 MB). Download `zhesheng-model-v4.zip` from Releases and unzip it into `models/` at the repository root:

   ```bash
   unzip zhesheng-model-v4.zip -d models
   ```

   You should then have `models/eg2-transcribe-zh/pipeline.json`; see [models/README.md](models/README.md).

2. Generate the Xcode project and build:

   ```bash
   cd source/ios
   xcodegen generate
   xcodebuild -project EG2Transcribe.xcodeproj -scheme EG2TranscribeMac -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath ../../build build
   ```

   The app is `build/Build/Products/Release/折声.app`, with the model inside.

3. Run the tests (still in `source/ios`). One test needs a long local recording and skips itself when there is none:

   ```bash
   xcodebuild -project EG2Transcribe.xcodeproj -scheme EG2ZHWebTests -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath ../../build test
   ```

4. Back at the repository root, make the disk image:

   ```bash
   tools/make_dmg.sh
   ```

   This writes `dist/折声-1.0-build17.dmg` with an ad-hoc signature. If you have an Apple Developer ID, the top of the script explains how to sign and notarize instead.

The source still contains the upstream iPhone target (`EG2Transcribe`), which this project has not tested.

## Layout

| Path | Contents |
|---|---|
| `source/ios/Sources/` | App source (SwiftUI; the models run with Core AI on macOS 27) |
| `source/ios/Tests/` | Unit tests |
| `source/ios/Resources/` | Icon, `MacInfo.plist`, and the models' licences and attributions (`Licenses/`) |
| `source/ios/project.yml` | XcodeGen project description |
| `tools/make_dmg.sh`, `tools/dmg/` | Packaging script and the install guide |
| `models/` | Where the model goes (not in the repository) |

## Credits and licences

- **Code**: [Apache License 2.0](LICENSE). 折声 is adapted from [john-rocky/eg2-transcribe](https://github.com/john-rocky/eg2-transcribe) (commit `e6b7d5d`); [NOTICE](NOTICE) lists the files changed and added.
- **Mandarin recognition model zh-v4 and the language model**: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). You may share them and use them commercially, with attribution; adaptations you share must also use CC BY-SA 4.0. The sources and attributions of the training data are in [source/ios/Resources/Licenses/](source/ios/Resources/Licenses/) (`NOTICE.md`, `DATA_LICENSES.json`, `LM_NOTICE.md`, `YODAS_VIDEOS.tsv`), and the app and the model pack carry the same files.
- **EmbeddingGemma 2 audio encoder** (the Core AI version from [mlboydaisuke/EmbeddingGemma-2-Transcribe-CoreAI](https://huggingface.co/mlboydaisuke/EmbeddingGemma-2-Transcribe-CoreAI)): Apache-2.0; its use must follow the [Gemma Prohibited Use Policy](https://ai.google.dev/gemma/prohibited_use_policy).
