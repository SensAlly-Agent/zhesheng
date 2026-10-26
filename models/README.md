**English** | [简体中文](README.zh-CN.md)

# Model

The model is not in the repository (about 640 MB). Download `zhesheng-model-v4.zip` from [Releases](https://github.com/SensAlly-Agent/zhesheng/releases/latest) and unzip it at the repository root:

```bash
unzip zhesheng-model-v4.zip -d models
```

You then have the folder below. When you build, Xcode puts the whole `eg2-transcribe-zh` folder into the app (see `source/ios/project.yml`).

```
models/eg2-transcribe-zh/
  pipeline.json                          which models run, and on which compute unit
  reader_config.json                     the recognizer's settings, including language-model decoding
  vocab.txt                              the 7,067 Chinese characters the recognizer can write
  mel_filters.bin                        mel filter bank
  lm_zh_char.eg2lm                       Chinese character language model (3-gram)
  macos/eg2_audio_fp16_T3000.aimodel     EmbeddingGemma 2 audio encoder
  macos/eg2_reader_zh_fp16_T750.aimodel  Mandarin recognizer zh-v4
  licenses/                              the audio encoder's LICENSE and NOTICE
  PROVENANCE.txt                         where each file comes from
  SHA256SUMS                             SHA-256 of each file
```

To check that the files are complete:

```bash
cd models/eg2-transcribe-zh && shasum -a 256 -c SHA256SUMS
```

The model pack also has `NOTICE.md`, `DATA_LICENSES.json`, `LM_NOTICE.md` and `YODAS_VIDEOS.tsv`: the licence of the recognizer and the language model (CC BY-SA 4.0) and the sources and attributions of the training data. They are the same files as in `source/ios/Resources/Licenses/`.
