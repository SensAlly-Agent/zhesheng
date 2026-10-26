[English](README.md) | **简体中文**

# 模型

模型不在仓库里（约 640 MB）。从 [Releases](https://github.com/SensAlly-Agent/zhesheng/releases/latest) 下载 `zhesheng-model-v4.zip`，在仓库根目录解压：

```bash
unzip zhesheng-model-v4.zip -d models
```

解压后是下面这样。构建时 Xcode 会把整个 `eg2-transcribe-zh` 文件夹装进 App（见 `source/ios/project.yml`）。

```
models/eg2-transcribe-zh/
  pipeline.json                          用哪些模型、在哪个计算单元上运行
  reader_config.json                     识别器的设置，包括语言模型解码
  vocab.txt                              识别器能写出的 7,067 个汉字
  mel_filters.bin                        梅尔滤波器组
  lm_zh_char.eg2lm                       中文字符语言模型（3-gram）
  macos/eg2_audio_fp16_T3000.aimodel     EmbeddingGemma 2 音频编码器
  macos/eg2_reader_zh_fp16_T750.aimodel  中文识别器 zh-v4
  licenses/                              音频编码器的 LICENSE 和 NOTICE
  PROVENANCE.txt                         各个文件的来源
  SHA256SUMS                             各个文件的 SHA-256
```

检查文件是否完整：

```bash
cd models/eg2-transcribe-zh && shasum -a 256 -c SHA256SUMS
```

模型包里另有 `NOTICE.md`、`DATA_LICENSES.json`、`LM_NOTICE.md` 和 `YODAS_VIDEOS.tsv`，写着识别器和语言模型的许可（CC BY-SA 4.0）以及训练数据的来源和署名，和 `source/ios/Resources/Licenses/` 里的同名文件相同。
