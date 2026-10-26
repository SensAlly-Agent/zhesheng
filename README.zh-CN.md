[English](README.md) | **简体中文**

# 折声

在 Mac 上把普通话录音离线转成文字。识别模型装在 App 里，转写全程在本机完成，录音不会上传。转完以后，可以把文稿交给 DeepSeek、ChatGPT 等 AI 网站补标点、改错字，再把结果贴回来。

- 选择音频文件（m4a、wav、mp3、flac、caf），或者直接录音
- 实测：在 MacBook Air（M4）上，65 分钟的录音不到 15 秒就转完
- 一键复制文稿和校对提示词，并打开 DeepSeek、ChatGPT、Claude、Gemini 或 Kimi；App 不会替你粘贴或发送
- 把 AI 的回答贴回来；原始识别稿随时可以恢复
- 转写结果可以直接修改，改好后保存为文本

## 下载安装

从 [Releases](https://github.com/SensAlly-Agent/zhesheng/releases/latest) 下载 `zhesheng-1.0-build17.dmg`（约 220 MB），打开后把“折声”拖进“应用程序”。不需要 Xcode，也不用另外下载模型。

需要：

- Apple 芯片的 Mac（M1 或更新）
- macOS 27 或更新
- 约 2 GB 可用空间

**第一次打开**：折声没有经过苹果公证，macOS 会先拦一次。点“完成”（不要点“移到废纸篓”），然后打开“系统设置 > 隐私与安全”，在“安全性”里点“仍要打开”，再用密码或触控 ID 确认。以后不用再管。

第一次运行时，折声要为这台 Mac 的芯片准备模型，大约 1 分钟，请不要强制退出。以后打开只要几秒。

完整步骤见磁盘映像里的《安装与使用.txt》（即 [tools/dmg/安装与使用.txt](tools/dmg/安装与使用.txt)）。

## 准确率

在 MacBook Air（M4）上，用 6 段公开测试录音（AISHELL-1 test，6 位说话人，共 27 分钟、5,025 字）实测 build 17：字错误率 3.46%，即 5,025 个字里错了 174 个（错字、漏字、多字都算）。

## 从源码构建

需要 Xcode 27 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

1. 模型不在仓库里（约 640 MB）。从 Releases 下载 `zhesheng-model-v4.zip`，在仓库根目录解压到 `models/`：

   ```bash
   unzip zhesheng-model-v4.zip -d models
   ```

   解压后应有 `models/eg2-transcribe-zh/pipeline.json`，详见 [models/README.zh-CN.md](models/README.zh-CN.md)。

2. 生成 Xcode 工程并编译：

   ```bash
   cd source/ios
   xcodegen generate
   xcodebuild -project EG2Transcribe.xcodeproj -scheme EG2TranscribeMac -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath ../../build build
   ```

   App 在 `build/Build/Products/Release/折声.app`，模型已经装在里面。

3. 运行测试（仍在 `source/ios` 里）。有一个测试要用本地的长录音，找不到就自动跳过：

   ```bash
   xcodebuild -project EG2Transcribe.xcodeproj -scheme EG2ZHWebTests -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath ../../build test
   ```

4. 回到仓库根目录，打包成磁盘映像：

   ```bash
   tools/make_dmg.sh
   ```

   生成 `dist/折声-1.0-build17.dmg`。默认用 ad-hoc 签名；如果有 Apple Developer ID，脚本开头写了签名和公证的用法。

源码里还保留着上游的 iPhone 目标（`EG2Transcribe`），本项目没有测试过。

## 目录

| 路径 | 内容 |
|---|---|
| `source/ios/Sources/` | App 源码（SwiftUI，用 macOS 27 的 Core AI 运行模型） |
| `source/ios/Tests/` | 单元测试 |
| `source/ios/Resources/` | 图标、`MacInfo.plist`，以及模型的许可和署名（`Licenses/`） |
| `source/ios/project.yml` | XcodeGen 工程描述 |
| `tools/make_dmg.sh`、`tools/dmg/` | 打包脚本和安装说明 |
| `models/` | 放模型的地方（不在仓库里） |

## 来源与许可

- **代码**：[Apache License 2.0](LICENSE)。折声改自 [john-rocky/eg2-transcribe](https://github.com/john-rocky/eg2-transcribe)（commit `e6b7d5d`），改了哪些文件、新加了哪些文件，见 [NOTICE](NOTICE)。
- **中文识别模型 zh-v4 和语言模型**：[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.zh-hans)。可以转给别人，也可以商用，但要署名；改编后再发布也要用 CC BY-SA 4.0。训练数据的来源和署名在 [source/ios/Resources/Licenses/](source/ios/Resources/Licenses/)（`NOTICE.md`、`DATA_LICENSES.json`、`LM_NOTICE.md`、`YODAS_VIDEOS.tsv`），App 和模型包里也都带着这几个文件。
- **音频编码器 EmbeddingGemma 2**（Core AI 版，来自 [mlboydaisuke/EmbeddingGemma-2-Transcribe-CoreAI](https://huggingface.co/mlboydaisuke/EmbeddingGemma-2-Transcribe-CoreAI)）：Apache-2.0，使用时须遵守 [Gemma 禁止用途政策](https://ai.google.dev/gemma/prohibited_use_policy)。
